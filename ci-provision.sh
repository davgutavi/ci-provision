#!/bin/bash
set -euo pipefail

########################################
# Datos de la red virtual (se rellenan en load_network_info)
########################################
PUBKEY=""          # la clave pública del usuario, ya validada (una sola línea)
NET_GATEWAY=""
NET_NETMASK=""
NET_PREFIX=""
NET_DHCP_STARTS=()
NET_DHCP_ENDS=()
NET_RESERVED=()

# IPs de los nodos del clúster (se calculan a partir de la red)
CLUSTER_IPS=()

########################################
# Utilidades: herramientas y aritmética de IPs
########################################

# Comprueba que están disponibles las herramientas que necesita el script
require_commands() {
    local faltan=()
    local c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            faltan+=("$c")
        fi
    done
    if (( ${#faltan[@]} > 0 )); then
        error 38 "No se encuentran estas herramientas necesarias: ${faltan[*]}
Avisa al administrador del servidor."
    fi
}

# Comprueba que una cadena es una IPv4 con octetos entre 0 y 255
valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS=.
    for o in $ip; do
        if (( 10#$o > 255 )); then
            return 1
        fi
    done
    return 0
}

# Convierte una IPv4 en su valor entero
ip_to_int() {
    local IFS=. o1 o2 o3 o4
    read -r o1 o2 o3 o4 <<< "$1"
    printf '%s' $(( (10#$o1 << 24) + (10#$o2 << 16) + (10#$o3 << 8) + 10#$o4 ))
}

# Convierte un entero en su IPv4
int_to_ip() {
    local n="$1"
    printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) \
                         $(( (n >> 8) & 255 ))  $(( n & 255 ))
}

# Convierte una máscara (255.255.255.0) en su prefijo (24)
mask_to_prefix() {
    local o bits=0
    local IFS=.
    for o in $1; do
        case "$o" in
            255) bits=$(( bits + 8 )) ;;
            254) bits=$(( bits + 7 )) ;;
            252) bits=$(( bits + 6 )) ;;
            248) bits=$(( bits + 5 )) ;;
            240) bits=$(( bits + 4 )) ;;
            224) bits=$(( bits + 3 )) ;;
            192) bits=$(( bits + 2 )) ;;
            128) bits=$(( bits + 1 )) ;;
            0)   ;;
            *)   return 1 ;;
        esac
    done
    printf '%s' "$bits"
}

# Tamaño como 40G, 512M o 1T → bytes
tam_a_bytes() {   # TAMAÑO
    local n="${1%[MGT]}"
    n=$(( 10#$n ))
    case "${1: -1}" in
        M) printf '%s' $(( n * 1024 * 1024 )) ;;
        G) printf '%s' $(( n * 1024 * 1024 * 1024 )) ;;
        T) printf '%s' $(( n * 1024 * 1024 * 1024 * 1024 )) ;;
    esac
}

# Bytes → GiB, redondeando hacia arriba
bytes_a_gib() {   # BYTES
    printf '%s' $(( ($1 + 1073741823) / 1073741824 ))
}

# Tamaño virtual de una imagen en bytes, o nada si no se puede leer
tam_virtual() {   # FICHERO
    qemu-img info -U --output=json "$1" 2>/dev/null | jq -r '."virtual-size" // empty' 2>/dev/null || true
}

# Extrae el valor de un atributo XML de una línea.
# libvirt emite siempre comillas simples, pero se aceptan también las dobles
# para no depender de ese detalle.
xml_attr() {
    local valor
    valor="$(sed -n "s/.*[[:space:]]$2='\([^']*\)'.*/\1/p" <<< "$1")"

    if [[ -z "$valor" ]]; then
        valor="$(sed -n "s/.*[[:space:]]$2=\"\([^\"]*\)\".*/\1/p" <<< "$1")"
    fi

    printf '%s' "$valor"
}

# Dirección de red y de difusión (enteros) de la red cargada
red_neti()   { local gwi maski; gwi="$(ip_to_int "$NET_GATEWAY")"; maski=$(( 0xFFFFFFFF ^ ((1 << (32 - NET_PREFIX)) - 1) )); printf '%s' $(( gwi & maski )); }
red_bcasti() { local neti maski; neti="$(red_neti)"; maski=$(( 0xFFFFFFFF ^ ((1 << (32 - NET_PREFIX)) - 1) )); printf '%s' $(( neti | (~maski & 0xFFFFFFFF) )); }

########################################
# Elección de la red virtual
#
# El manual pide llamarla USUARIO-red, pero en los servidores hay redes con
# otros sufijos (-net, -network, _red, sin sufijo) y usuarios con más de una.
# Se busca entre las que empiezan por el usuario; si hay dudas, se pide --red.
########################################
detectar_red() {
    if [[ -n "$RED_OPT" ]]; then
        if ! virsh net-info "$RED_OPT" >/dev/null 2>&1; then
            error 40 "La red '$RED_OPT' (--red) no existe.
Consulta las redes disponibles con: virsh net-list --all"
        fi
        NET_NAME="$RED_OPT"
    else
        local todas r usuario_min candidatas=() elegida=""
        usuario_min="${USUARIO,,}"
        todas="$(virsh net-list --all --name 2>/dev/null || true)"

        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            local r_min="${r,,}"
            if [[ "$r_min" == "$usuario_min" || "$r_min" == "${usuario_min}-"* || "$r_min" == "${usuario_min}_"* ]]; then
                candidatas+=( "$r" )
            fi
        done <<< "$todas"

        for r in ${candidatas[@]+"${candidatas[@]}"}; do
            if [[ "$r" == "${USUARIO}-red" ]]; then
                elegida="$r"
            fi
        done

        if [[ -z "$elegida" ]]; then
            if (( ${#candidatas[@]} == 1 )); then
                elegida="${candidatas[0]}"
            elif (( ${#candidatas[@]} == 0 )); then
                error 40 "No encuentro ninguna red virtual con tu nombre de usuario ('$USUARIO').
Crea tu red virtual con el nombre '${USUARIO}-red', o indica cuál usar con: --red NOMBRE
Redes existentes: virsh net-list --all"
            else
                error 44 "Hay varias redes virtuales con tu nombre de usuario: ${candidatas[*]}
Indica cuál usar con: --red NOMBRE"
            fi
        fi

        NET_NAME="$elegida"
    fi

    # La red tiene que estar activa para que virt-install pueda conectar la máquina
    local activa
    activa="$(virsh net-info "$NET_NAME" 2>/dev/null | awk '/^Active:/ { print $2 }')"
    if [[ "$activa" != "yes" ]]; then
        error 45 "La red '$NET_NAME' existe pero está inactiva.
Actívala con:            virsh net-start $NET_NAME
Para que arranque sola:  virsh net-autostart $NET_NAME"
    fi
}

########################################
# Introspección de la red virtual
#
# En lugar de dar por supuesta la configuración recomendada en el manual
# (192.168.X.0/24, pasarela en .1 y DHCP en .128-.254), se leen los datos
# reales de la red con 'virsh net-dumpxml'. Así el script funciona igual
# con redes que sigan otra topología.
########################################
load_network_info() {
    local xml pista
    pista=$'\n'"Revisa su definición con: virsh net-dumpxml $NET_NAME"$'\n'"Si no ves el problema, avisa a tu profesor con esa salida."
    if ! xml="$(virsh net-dumpxml "$NET_NAME" 2>/dev/null)"; then
        error 40 "La red '$NET_NAME' no existe.
Consulta las redes disponibles con: virsh net-list --all"
    fi

    # Primer bloque <ip> de IPv4, con sus rangos DHCP y sus reservas. Los de un
    # bloque IPv6 (DHCPv6) se descartan: no son direcciones IPv4.
    local bloque ipline
    bloque="$(awk '
        !hecho && /<ip[[:space:]]/ && !/family=.ipv6./ { dentro = 1; hecho = 1 }
        dentro { print }
        dentro && (/<\/ip>/ || /<ip[^>]*\/>/) { dentro = 0 }
    ' <<< "$xml")"
    ipline="${bloque%%$'\n'*}"
    if [[ -z "$ipline" ]]; then
        error 43 "No se ha podido determinar la configuración IPv4 de la red '$NET_NAME'.$pista"
    fi

    NET_GATEWAY="$(xml_attr "$ipline" address)"
    NET_NETMASK="$(xml_attr "$ipline" netmask)"
    local pfx
    pfx="$(xml_attr "$ipline" prefix)"

    if [[ -n "$NET_NETMASK" ]]; then
        if ! NET_PREFIX="$(mask_to_prefix "$NET_NETMASK")"; then
            error 43 "La máscara '$NET_NETMASK' de la red '$NET_NAME' no es válida.$pista"
        fi
    elif [[ -n "$pfx" ]]; then
        NET_PREFIX="$pfx"
    elif valid_ipv4 "$NET_GATEWAY"; then
        # Sin máscara ni prefijo, libvirt aplica la máscara por clase
        case "${NET_GATEWAY%%.*}" in
            [0-9]|[1-9][0-9]|1[01][0-9]|12[0-7]) NET_PREFIX=8 ;;
            1[2-8][0-9]|19[01])                  NET_PREFIX=16 ;;
            *)                                    NET_PREFIX=24 ;;
        esac
    fi

    if ! valid_ipv4 "$NET_GATEWAY"; then
        error 43 "La pasarela '$NET_GATEWAY' de la red '$NET_NAME' no es una IPv4 válida.$pista"
    fi

    # Rangos DHCP (puede haber varios)
    local line ini fin res
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ini="$(xml_attr "$line" start)"
        fin="$(xml_attr "$line" end)"
        if valid_ipv4 "$ini" && valid_ipv4 "$fin"; then
            NET_DHCP_STARTS+=( "$ini" )
            NET_DHCP_ENDS+=( "$fin" )
        fi
    done < <(grep -E '<range[[:space:]]' <<< "$bloque" || true)

    # Reservas estáticas por MAC. Pueden estar fuera del rango DHCP,
    # así que hay que tenerlas en cuenta aparte.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        res="$(xml_attr "$line" ip)"
        if valid_ipv4 "$res"; then NET_RESERVED+=( "$res" ); fi
    done < <(grep -E '<host[[:space:]].*[[:space:]]ip=' <<< "$bloque" || true)
}

# Imprime hasta 3 bloques de IPs libres para asignación fija
free_ip_blocks() {
    local neti bcasti
    neti="$(red_neti)"
    bcasti="$(red_bcasti)"
    local -a ini fin
    local i orden cur s e mostrados

    ini=( "$(ip_to_int "$NET_GATEWAY")" )
    fin=( "$(ip_to_int "$NET_GATEWAY")" )

    for (( i = 0; i < ${#NET_DHCP_STARTS[@]}; i++ )); do
        ini+=( "$(ip_to_int "${NET_DHCP_STARTS[$i]}")" )
        fin+=( "$(ip_to_int "${NET_DHCP_ENDS[$i]}")" )
    done

    for (( i = 0; i < ${#NET_RESERVED[@]}; i++ )); do
        ini+=( "$(ip_to_int "${NET_RESERVED[$i]}")" )
        fin+=( "$(ip_to_int "${NET_RESERVED[$i]}")" )
    done

    orden="$(for (( i = 0; i < ${#ini[@]}; i++ )); do
                 echo "${ini[$i]} ${fin[$i]}"
             done | sort -n)"

    cur=$(( neti + 1 ))
    mostrados=0

    while read -r s e; do
        if (( mostrados >= 3 )); then
            return 0
        fi
        if (( s > cur )); then
            echo "  $(int_to_ip "$cur") - $(int_to_ip $(( s - 1 )))"
            mostrados=$(( mostrados + 1 ))
        fi
        if (( e >= cur )); then
            cur=$(( e + 1 ))
        fi
    done <<< "$orden"

    if (( mostrados < 3 && cur <= bcasti - 1 )); then
        echo "  $(int_to_ip "$cur") - $(int_to_ip $(( bcasti - 1 )))"
        mostrados=$(( mostrados + 1 ))
    fi

    if (( mostrados == 0 )); then
        echo "  (ninguna)"
    fi
}

# ¿Se puede asignar esta IP (entero) de forma fija? Dentro de la red, sin ser
# la de red, la de difusión ni la pasarela, y fuera del DHCP y de las reservas.
ip_asignable() {   # IP_ENTERA
    local ipi="$1" i maski
    maski=$(( 0xFFFFFFFF ^ ((1 << (32 - NET_PREFIX)) - 1) ))
    (( (ipi & maski) == $(red_neti) )) || return 1
    (( ipi != $(red_neti) && ipi != $(red_bcasti) && ipi != $(ip_to_int "$NET_GATEWAY") )) || return 1
    for (( i = 0; i < ${#NET_DHCP_STARTS[@]}; i++ )); do
        if (( ipi >= $(ip_to_int "${NET_DHCP_STARTS[$i]}") && ipi <= $(ip_to_int "${NET_DHCP_ENDS[$i]}") )); then
            return 1
        fi
    done
    for (( i = 0; i < ${#NET_RESERVED[@]}; i++ )); do
        if (( ipi == $(ip_to_int "${NET_RESERVED[$i]}") )); then return 1; fi
    done
    return 0
}

# Primer número N de la red con N, N+1, ... libres para todos los nodos, o nada
sugerir_ip_inicial() {
    local n k neti ok
    neti="$(red_neti)"
    for (( n = 2; n <= 250; n++ )); do
        ok=true
        for (( k = 0; k < ${#CLUSTER_NODOS[@]}; k++ )); do
            if ! ip_asignable $(( neti + n + k )); then ok=false; break; fi
        done
        if $ok; then echo "$n"; return 0; fi
    done
}

# Final de los mensajes de IP: qué puede hacer el alumno
remedio_ip() {
    local n
    if $CLUSTER; then
        n="$(sugerir_ip_inicial)"
        if [[ -n "$n" ]]; then
            printf '%s' "Para el clúster hacen falta ${#CLUSTER_NODOS[@]} IPs fijas seguidas. Hay hueco a partir de la .$n:
  $0 --gluster-cluster --ip-inicial $n"
        else
            printf '%s' "Para el clúster hacen falta ${#CLUSTER_NODOS[@]} IPs fijas seguidas y tu red no tiene ningún hueco así.
Reduce el rango DHCP de tu red (virsh net-edit $NET_NAME; p.ej. que empiece en la .128)."
        fi
    else
        printf '%s' "También puedes omitir el parámetro IP para que la máquina use DHCP."
    fi
}

# Valida una IP fija contra la configuración real de la red
validar_ip_fija() {
    local ip="$1"

    if ! valid_ipv4 "$ip"; then
        error 41 "La IP '$ip' no es una dirección IPv4 válida (cuatro números de 0 a 255 separados por puntos).
Pasarela : ${NET_GATEWAY}
IPs libres para asignación fija:
$(free_ip_blocks)

$(remedio_ip)"
    fi

    local ipi gwi neti bcasti maski
    ipi="$(ip_to_int "$ip")"
    gwi="$(ip_to_int "$NET_GATEWAY")"
    maski=$(( 0xFFFFFFFF ^ ((1 << (32 - NET_PREFIX)) - 1) ))
    neti="$(red_neti)"
    bcasti="$(red_bcasti)"

    if (( (ipi & maski) != neti )); then
        error 41 "La IP '$ip' no pertenece a la red '$NET_NAME'.
Red      : $(int_to_ip "$neti")/${NET_PREFIX}
Pasarela : ${NET_GATEWAY}
IPs libres para asignación fija:
$(free_ip_blocks)"
    fi

    if (( ipi == neti || ipi == bcasti )); then
        error 41 "La IP '$ip' es la dirección de red o la de difusión de '$NET_NAME'. No se puede asignar a una máquina."
    fi

    if (( ipi == gwi )); then
        error 41 "La IP '$ip' es la pasarela de la red '$NET_NAME'. Elige otra."
    fi

    # Dentro de algún rango DHCP
    local i si ei
    for (( i = 0; i < ${#NET_DHCP_STARTS[@]}; i++ )); do
        si="$(ip_to_int "${NET_DHCP_STARTS[$i]}")"
        ei="$(ip_to_int "${NET_DHCP_ENDS[$i]}")"
        if (( ipi >= si && ipi <= ei )); then
            error 42 "La IP '$ip' está dentro del rango DHCP de la red '$NET_NAME' (${NET_DHCP_STARTS[$i]} - ${NET_DHCP_ENDS[$i]}).
Si se la asignas de forma fija, el servidor DHCP puede entregársela a otra máquina.
Pasarela : ${NET_GATEWAY}
IPs libres para asignación fija:
$(free_ip_blocks)

$(remedio_ip)"
        fi
    done

    # Coincide con una reserva estática
    for (( i = 0; i < ${#NET_RESERVED[@]}; i++ )); do
        if (( ipi == $(ip_to_int "${NET_RESERVED[$i]}") )); then
            error 42 "La IP '$ip' ya está reservada por MAC en la red '$NET_NAME'.
IPs libres para asignación fija:
$(free_ip_blocks)

$(remedio_ip)"
        fi
    done
}

# IP en forma normal: sin ceros a la izquierda (192.168.7.020 → 192.168.7.20)
normalizar_ip() {   # IP
    int_to_ip "$(ip_to_int "$1")"
}

# ¿Usa ya otra máquina esta IP? Se mira en los ficheros cloud-init del silo
# (las máquinas creadas con el script, aunque estén apagadas) y, si hay ping,
# si algo responde en ella. No cuenta la máquina que se va a rehacer con
# --limpiar, que es la que tiene esa IP.
comprobar_ip_en_uso() {   # IP DOMINIO_QUE_LA_RECIBIRÁ
    local ip="$1" vm="$2" f dir dom orden propia=false
    for f in "$SILO_DIR"/cloudinit-*/cip-net.yaml; do
        [[ -f "$f" ]] || continue
        dir="$(dirname "$f")"
        [[ "$dir" == *.dry-run ]] && continue
        dom="$(basename "$dir")"
        dom="${dom#cloudinit-}"
        grep -qE -- "- ${ip//./\.}/[0-9]+$" "$f" || continue
        if en_lista "$dom" ${OBJ_DOMINIOS[@]+"${OBJ_DOMINIOS[@]}"}; then
            propia=true
        elif virsh dominfo "$dom" >/dev/null 2>&1; then
            if [[ "$dom" == "${USUARIO}-"* ]]; then
                orden="$0 --eliminar ${dom#"${USUARIO}-"}"
            else
                orden="$0 --prefijo ${dom%%-*} --eliminar ${dom#*-}"
            fi
            error 42 "La IP '$ip' ya la tiene asignada tu máquina '$dom'. Dos máquinas con la misma IP no se pueden comunicar.
Elige otra IP, o elimina antes esa máquina: $orden
IPs libres para asignación fija:
$(free_ip_blocks)"
        fi
    done
    if ! $propia && command -v ping >/dev/null 2>&1 && ping -c1 -W1 "$ip" >/dev/null 2>&1; then
        error 42 "Algo responde ya en la IP '$ip' (otra máquina de tu red virtual, o creada a mano).
Si se la asignas también a '$vm', ninguna de las dos funcionará bien. Elige otra IP.
IPs libres para asignación fija:
$(free_ip_blocks)

$(remedio_ip)"
    fi
}

# Calcula las IPs de los nodos del clúster (.10, .11, ...) dentro de la red
calcular_ips_cluster() {
    local neti i
    neti="$(red_neti)"
    CLUSTER_IPS=()
    for (( i = 0; i < ${#CLUSTER_NODOS[@]}; i++ )); do
        CLUSTER_IPS+=( "$(int_to_ip $(( neti + CLUSTER_IP_INICIAL + i )))" )
    done
}

########################################
# Imagen de partida (--imagen, o la que se deduce de --base)
########################################

# Variante de SO que se declara a virt-install para cada imagen
variante_de_imagen() {   # IMAGEN
    case "$1" in
        debian12) echo "debian12" ;;
        *)        echo "ubuntu24.04" ;;
    esac
}

# Nombre legible de cada imagen, para los mensajes
descripcion_imagen() {   # IMAGEN
    case "$1" in
        noble)       echo "Ubuntu 24.04 (imagen cloud)" ;;
        debian12)    echo "Debian 12 (imagen cloud)" ;;
        ubuntu-base) echo "Ubuntu 24.04 (ubuntu-base.qcow2 del boletín 1)" ;;
    esac
}

# ¿Es una de las imágenes cloud que descarga el script? Nunca se borran.
imagen_protegida() {   # FICHERO
    [[ "$1" == "$SILO_DIR/$IMAGEN_NOBLE" || "$1" == "$SILO_DIR/$IMAGEN_DEBIAN" ]]
}

# Fija IMAGEN, BASE_IMG, BASE_IMG_URL y OS_VARIANT a partir de --imagen. Con
# --base, el fichero es ese; su tipo lo da --imagen si se indica y, si no, se
# deduce más tarde del propio fichero (deducir_imagen_de_base).
elegir_imagen() {
    local gluster=false
    if $GLUSTERFS || $CLUSTER; then gluster=true; fi

    if [[ -n "$BASE_OPT" ]]; then
        BASE_IMG="${SILO_DIR}/${BASE_OPT}"
        BASE_IMG_URL=""
        BASE_IMG_SUMAS=""
        if [[ -n "$IMAGEN_OPT" ]]; then
            case "$IMAGEN_OPT" in
                noble|debian12|ubuntu-base) IMAGEN="$IMAGEN_OPT" ;;
                *) error 10 "La imagen '$IMAGEN_OPT' (--imagen) no existe. Con --base, indica de cuál sale
el fichero: noble (Ubuntu 24.04), debian12 o ubuntu-base." ;;
            esac
            OS_VARIANT="$(variante_de_imagen "$IMAGEN")"
        fi
        return 0
    fi

    IMAGEN="$IMAGEN_OPT"
    if [[ -z "$IMAGEN" ]]; then
        if $gluster; then IMAGEN="$IMAGEN_DEFECTO_GLUSTER"; else IMAGEN="$IMAGEN_DEFECTO"; fi
    fi

    case "$IMAGEN" in
        noble)
            BASE_IMG="$SILO_DIR/$IMAGEN_NOBLE"
            BASE_IMG_URL="$URL_NOBLE"
            BASE_IMG_SUMAS="$SUMAS_NOBLE"
            ;;
        debian12)
            BASE_IMG="$SILO_DIR/$IMAGEN_DEBIAN"
            BASE_IMG_URL="$URL_DEBIAN"
            BASE_IMG_SUMAS="$SUMAS_DEBIAN"
            ;;
        ubuntu-base)
            if ! $gluster; then
                error 10 "--imagen ubuntu-base solo sirve para la imagen base GlusterFS (--glusterfs o
--gluster-cluster). Para una máquina suelta usa noble (Ubuntu 24.04) o debian12."
            fi
            BASE_IMG="$UBUNTU_BASE_COMPARTIDA"
            BASE_IMG_URL=""
            BASE_IMG_SUMAS=""
            ;;
        *)
            error 10 "La imagen '$IMAGEN' (--imagen) no existe. Elige una de estas:
  noble        Ubuntu 24.04 (por defecto)
  debian12     Debian 12
  ubuntu-base  la del boletín 1, solo para la base GlusterFS"
            ;;
    esac
    OS_VARIANT="$(variante_de_imagen "$IMAGEN")"
}

# Con --base: comprueba que la cadena de respaldo está completa y, si no se
# ha dicho con --imagen, deduce de qué imagen sale el fichero por el nombre de
# la última de la cadena:
#   *debian*                     Debian 12
#   noble*, *cloudimg*           Ubuntu 24.04 (imagen cloud)
#   *ubuntu-base*, *gluster*     ubuntu-base (la base GlusterFS del boletín es
#                                una copia completa suya)
# Si no se reconoce, se trata como imagen cloud de Ubuntu y se avisa: así
# 'administrador' siempre tiene sudo.
deducir_imagen_de_base() {
    local cadena raiz
    if ! cadena="$(qemu-img info -U --backing-chain --output=json "$BASE_IMG" 2>/dev/null)"; then
        error 39 "No se puede leer la imagen $BASE_IMG ni la cadena de imágenes de la que es copia.
Lo más probable es que falte (o se haya movido) la imagen de la que se hizo la copia; compruébalo con:
  qemu-img info --backing-chain $BASE_IMG"
    fi
    if [[ -n "$IMAGEN_OPT" ]]; then
        return 0
    fi
    raiz="$(jq -r 'if type == "array" then .[-1].filename else .filename end // empty' <<< "$cadena" 2>/dev/null || true)"
    raiz="$(basename "${raiz:-$BASE_IMG}")"
    case "${raiz,,}" in
        *debian*)                 IMAGEN="debian12" ;;
        noble*|*cloudimg*)        IMAGEN="noble" ;;
        *ubuntu-base*|*gluster*)  IMAGEN="ubuntu-base" ;;
        *)
            IMAGEN="noble"
            echo "AVISO: no sé de qué imagen sale $(basename "$BASE_IMG") (no es copia de ninguna imagen conocida)." >&2
            echo "       Se trata como imagen cloud de Ubuntu 24.04 ('administrador' con sudo sin contraseña)." >&2
            echo "       Si sale de ubuntu-base o de Debian, indícalo: --imagen ubuntu-base, o --imagen debian12." >&2
            ;;
    esac
    OS_VARIANT="$(variante_de_imagen "$IMAGEN")"
}

########################################
# Imagen base: si no está, se descarga; si está, se comprueba
########################################
# Copia de la imagen cloud en el directorio compartido de los profesores, si
# la han dejado allí (evita que cada alumno descargue cientos de MB)
imagen_compartida() {
    local f="$DIR_COMPARTIDO/$(basename "$BASE_IMG")"
    if [[ -r "$f" ]]; then printf '%s' "$f"; fi
}

# Descarga URL en FICHERO con wget o, si no hay, con curl. Devuelve el código.
descargar() {   # URL FICHERO [silencioso]
    local rc=0
    if command -v wget >/dev/null 2>&1; then
        if [[ -n "${3:-}" ]]; then wget -q -O "$2" "$1" || rc=$?; else wget -q --show-progress -O "$2" "$1" || rc=$?; fi
    elif command -v curl >/dev/null 2>&1; then
        if [[ -n "${3:-}" ]]; then curl -fsSL -o "$2" "$1" || rc=$?; else curl -fL --progress-bar -o "$2" "$1" || rc=$?; fi
    else
        error 38 "No hay ni wget ni curl para descargar la imagen base.
Descárgala tú en el silo con el nombre $(basename "$BASE_IMG")."
    fi
    return "$rc"
}

# Compara lo descargado con la suma que se publica junto a la imagen. Si no se
# puede obtener la suma (o no hay con qué calcularla) se avisa y se sigue: la
# imagen se comprueba igualmente con qemu-img.
verificar_suma() {   # FICHERO
    local f="$1" sumas="$1.sumas" bits esperada calculada nombre
    [[ -n "$BASE_IMG_SUMAS" ]] || return 0
    nombre="$(basename "$BASE_IMG_URL")"
    case "$BASE_IMG_SUMAS" in
        *SHA512SUMS) bits=512 ;;
        *)           bits=256 ;;
    esac
    if ! descargar "$BASE_IMG_SUMAS" "$sumas" silencioso; then
        rm -f "$sumas"
        echo "AVISO: no se ha podido descargar $BASE_IMG_SUMAS para comprobar la imagen." >&2
        return 0
    fi
    esperada="$(awk -v n="$nombre" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1 }' "$sumas")"
    rm -f "$sumas"
    if command -v "sha${bits}sum" >/dev/null 2>&1; then
        calculada="$("sha${bits}sum" < "$f")"
    elif command -v shasum >/dev/null 2>&1; then
        calculada="$(shasum -a "$bits" < "$f")"
    fi
    calculada="${calculada%% *}"
    if [[ -z "$esperada" || -z "$calculada" ]]; then
        echo "AVISO: no se ha podido comprobar la suma SHA-$bits de la imagen." >&2
        return 0
    fi
    if [[ "$esperada" != "$calculada" ]]; then
        rm -f "$f"
        quitar_disco_creado "$f"
        error 37 "Lo descargado no coincide con la suma publicada ($BASE_IMG_SUMAS): la descarga está
incompleta o alterada, y se ha eliminado. Vuelve a ejecutar el script para repetirla."
    fi
    echo "✔ Suma SHA-$bits comprobada."
}

descargar_imagen_base() {
    # Nombre temporal propio de esta ejecución: dos ejecuciones a la vez no se
    # pisan, y una descarga a medias nunca se confunde con la imagen (solo se
    # renombra, de golpe, si termina bien).
    local tmp="${BASE_IMG}.descargando.$$" tam="unos 600 MB" compartida rc=0
    if [[ "$IMAGEN" == debian12 ]]; then tam="unos 430 MB"; fi
    rm -f "$tmp"
    DISCOS_CREADOS+=( "$tmp" )

    compartida="$(imagen_compartida)"
    if [[ -n "$compartida" ]]; then
        echo "→ No está $(basename "$BASE_IMG") en el silo. Se copia de $compartida…"
        cp "$compartida" "$tmp" || rc=$?
        if (( rc != 0 )); then
            rm -f "$tmp"
            quitar_disco_creado "$tmp"
            error 37 "No se ha podido copiar $compartida (código $rc)."
        fi
    else
        echo "→ No está $(basename "$BASE_IMG") en el silo. Se descarga de:"
        echo "  $BASE_IMG_URL  ($tam; puede tardar un rato)"
        descargar "$BASE_IMG_URL" "$tmp" || rc=$?
        if (( rc != 0 )); then
            rm -f "$tmp"
            quitar_disco_creado "$tmp"
            error 37 "No se ha podido descargar la imagen base (código $rc).
Comprueba la conexión, o descárgala tú:
  wget $BASE_IMG_URL -O $BASE_IMG"
        fi
        verificar_suma "$tmp"
    fi

    mv "$tmp" "$BASE_IMG"
    quitar_disco_creado "$tmp"
    echo "✔ Imagen base lista: $BASE_IMG"
}

# La imagen indicada con --base no puede ser uno de los discos que se van a
# crear (con --limpiar se borraría antes de usarla)
comprobar_base_no_objetivo() {
    local f
    for f in ${OBJ_FICHEROS[@]+"${OBJ_FICHEROS[@]}"}; do
        if [[ "$f" == "$BASE_IMG" ]]; then
            if [[ -n "$BASE_OPT" ]]; then
                error 10 "La imagen indicada con --base ($(basename "$BASE_IMG")) es uno de los discos que se crearían.
Elige otra imagen o cambia el nombre de la máquina."
            fi
            error 10 "El disco que se crearía se llama $(basename "$BASE_IMG"), que es la imagen de la que
salen todas las máquinas. Ponle otro nombre a la máquina (p.ej. server1)."
        fi
        if imagen_protegida "$f"; then
            error 10 "El disco que se crearía se llama $(basename "$f"), que es una de las imágenes cloud de
las que salen las máquinas. Ponle otro nombre a la máquina (p.ej. server1)."
        fi
    done
}

# --tam no puede ser menor que la imagen de la que se hace la copia: qemu-img
# lo admite, pero la máquina arrancaría con el sistema de ficheros truncado
comprobar_tam_disco() {
    local vs
    [[ -f "$BASE_IMG" ]] || return 0
    vs="$(tam_virtual "$BASE_IMG")"
    [[ "$vs" =~ ^[0-9]+$ ]] || return 0
    if (( $(tam_a_bytes "$TAM_DISCO") < vs )); then
        # Sin --tam, el disco toma el tamaño de la imagen (ubuntu-base tiene 64G)
        if ! $TAM_EXPLICITO; then
            TAM_DISCO="$(bytes_a_gib "$vs")G"
            return 0
        fi
        error 15 "El tamaño --tam $TAM_DISCO es menor que el de la imagen $(basename "$BASE_IMG") ($(bytes_a_gib "$vs") GiB):
la copia quedaría truncada y la máquina no arrancaría bien. Indica un tamaño igual o mayor."
    fi
}

comprobar_imagen_base() {
    # Imagen indicada con --base: tiene que existir ya; no se descarga nada
    if [[ -n "$BASE_OPT" ]]; then
        if [[ ! -f "$BASE_IMG" ]]; then
            error 39 "La imagen indicada con --base no está en el silo: $BASE_IMG
Mira qué imágenes tienes con: ls $SILO_DIR/*.qcow2"
        fi
        local info_b fmt_b
        info_b="$(qemu-img info -U --output=json "$BASE_IMG" 2>/dev/null || true)"
        fmt_b="$(printf '%s' "$info_b" | jq -r '.format // empty' 2>/dev/null || true)"
        if [[ "$fmt_b" != "qcow2" ]]; then
            error 39 "La imagen indicada con --base no es un qcow2 válido: $BASE_IMG (formato: ${fmt_b:-desconocido}).
Mira qué imágenes tienes con: ls $SILO_DIR/*.qcow2"
        fi
        # Una imagen base no puede ser el disco de ninguna máquina, ni siquiera
        # apagada: en cuanto arrancara, escribiría en ella y las copias que
        # dependen de ella quedarían corruptas
        local otro salida
        cargar_dominios_vecinos
        if otro="$(dominio_que_usa_disco "$BASE_IMG")"; then
            error 39 "La imagen $BASE_IMG es el disco de la máquina '$otro' (aunque esté apagada).
Si la usas como imagen base, al arrancar '$otro' las copias se corromperían.
Elimina antes esa máquina, o haz una copia completa del disco y usa la copia:
  cp $BASE_IMG $SILO_DIR/mi-base.qcow2"
        fi
        # Sin -U, qemu-img se niega si otro proceso (p.ej. una máquina de otro
        # usuario) tiene la imagen abierta para escribir
        if ! qemu-img info --output=json "$BASE_IMG" >/dev/null 2>&1; then
            salida="$(qemu-img info "$BASE_IMG" 2>&1 || true)"
            if grep -qi 'lock' <<< "$salida"; then
                error 39 "La imagen $BASE_IMG la tiene abierta para escribir una máquina en ejecución.
Apágala (o elimina su dominio) antes de usarla como imagen base: las copias de un disco
que se está escribiendo quedarían corruptas."
            fi
        fi
        deducir_imagen_de_base
        return 0
    fi

    # ubuntu-base: la dejan los profesores en el servidor; no se descarga
    if [[ "$IMAGEN" == ubuntu-base ]]; then
        local fmt_u
        fmt_u="$(qemu-img info -U --output=json "$BASE_IMG" 2>/dev/null | jq -r '.format // empty' 2>/dev/null || true)"
        if [[ ! -r "$BASE_IMG" || "$fmt_u" != "qcow2" ]]; then
            error 39 "No encuentro la imagen ubuntu-base del boletín 1 en $BASE_IMG
(o no se puede leer, o no es un qcow2). En los servidores de la asignatura está ahí.
Si no la tienes, construye la base a partir de una imagen cloud: --imagen noble"
        fi
        return 0
    fi

    local recien_descargada=false

    if [[ ! -f "$BASE_IMG" ]]; then
        if $DRY_RUN; then
            # Se avisa dentro del plan, no aquí, para que salga en orden
            BASE_IMG_FALTA=true
            return 0
        fi
        descargar_imagen_base
        recien_descargada=true
    fi

    # Se usa la salida JSON: campos tipados, sin interpretar texto ni unidades.
    # -U (force-share) por si alguna máquina en ejecución tiene abierta la
    # imagen; sin él, qemu-img se niega por el bloqueo de escritura.
    local info fmt
    info="$(qemu-img info -U --output=json "$BASE_IMG" 2>/dev/null || true)"
    fmt="$(printf '%s' "$info" | jq -r '.format // empty' 2>/dev/null || true)"

    if [[ "$fmt" != "qcow2" ]]; then
        if $recien_descargada; then
            rm -f "$BASE_IMG"
            error 37 "Lo descargado no es un qcow2 válido (formato: ${fmt:-desconocido}); se ha eliminado.
Puede que la red del servidor esté redirigiendo la descarga. Descárgala tú:
  wget $BASE_IMG_URL -O $BASE_IMG"
        fi
        error 37 "La imagen base '$BASE_IMG' no es un qcow2 válido (formato: ${fmt:-desconocido}).
Probablemente la descarga falló. Bórrala y vuelve a ejecutar el script, que la descargará:
  rm $BASE_IMG"
    fi
}

########################################
# Validaciones generales
########################################
validar_entorno() {

    # Herramientas necesarias
    require_commands qemu-img virsh virt-install jq base64

    # Conexión con libvirt
    if ! virsh list --name >/dev/null 2>&1; then
        error 38 "No se puede conectar con libvirt (virsh).
¿Estás en el servidor de la asignatura? Prueba: virsh list --all"
    fi

    # Silo existente
    if [[ ! -d "$SILO_DIR" ]]; then
        error 30 "No existe el silo en: $SILO_DIR
Créalo con: mkdir -p $SILO_DIR
y mapéalo como silo en el hipervisor, como se explica en el capítulo de infraestructura virtual."
    fi

    # Los modos de gestión no crean nada: no necesitan clave, red ni imagen
    if $LISTAR || $ELIMINAR || $ELIMINAR_TODO || $MENU; then
        return 0
    fi

    # Clave pública existente y con una sola clave: va tal cual dentro del
    # user-data, y una segunda línea (o un fichero vacío) lo dejaría inválido
    if [[ ! -f "$PUBKEY_PATH" ]]; then
        error 31 "No existe la clave pública en $PUBKEY_PATH. Genera una con: ssh-keygen"
    fi
    local claves re
    claves="$(grep -c '[^[:space:]]' "$PUBKEY_PATH" || true)"
    PUBKEY="$(grep -m1 '[^[:space:]]' "$PUBKEY_PATH" || true)"
    PUBKEY="${PUBKEY%"${PUBKEY##*[![:space:]]}"}"
    re='^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256))(@openssh\.com)? '
    if (( claves == 0 )); then
        error 31 "El fichero $PUBKEY_PATH está vacío. Genera una pareja de claves nueva con: ssh-keygen"
    elif (( claves > 1 )); then
        error 31 "El fichero $PUBKEY_PATH tiene $claves líneas y debe contener una sola clave pública.
Deja solo la tuya (una línea que empiece por ssh-rsa, ssh-ed25519 o ecdsa-sha2-…)."
    elif ! [[ "$PUBKEY" =~ $re ]]; then
        error 31 "El fichero $PUBKEY_PATH no contiene una clave pública: debe ser una línea que empiece
por ssh-rsa, ssh-ed25519 o ecdsa-sha2-… (¿has copiado ahí la clave privada u otro fichero?).
Si no la tienes, genera una pareja de claves nueva con: ssh-keygen"
    fi

    # Red: elegirla y leer sus datos reales
    detectar_red
    load_network_info

    # IPs fijas, contra la red real
    if $CLUSTER; then
        calcular_ips_cluster
        local ip
        for ip in "${CLUSTER_IPS[@]}"; do
            validar_ip_fija "$ip"
        done
    elif [[ -n "$IP" ]]; then
        validar_ip_fija "$IP"
        IP="$(normalizar_ip "$IP")"
    fi

    # Antes de la descarga, que cuesta tiempo: qué se va a crear y si choca
    # con algo existente. Con --limpiar, la eliminación se hace después, en su sitio.
    calcular_objetivos
    comprobar_base_no_objetivo
    comprobar_conflictos solo-detectar

    # Que la IP fija no la tenga ya otra máquina
    if $CLUSTER; then
        local i
        for i in "${!CLUSTER_IPS[@]}"; do
            comprobar_ip_en_uso "${CLUSTER_IPS[$i]}" "${PREFIJO_DOMINIO}-${CLUSTER_NODOS[$i]}"
        done
    elif [[ -n "$IP" ]]; then
        comprobar_ip_en_uso "$IP" "$VM_NAME"
    fi

    # La imagen base, en último lugar: si falta hay que descargarla, y no
    # tiene sentido hacerlo para fallar después por un dato mal escrito
    comprobar_imagen_base
    comprobar_tam_disco
}

########################################
# Conflictos con lo que ya existe, y --limpiar
#
# El script siempre crea dominios y discos nuevos. Si alguno de los que va a
# crear ya existe, se detiene y lo dice; con --limpiar los elimina antes, pero
# solo exactamente esos: nunca otro dominio ni otro fichero del silo.
#
# Aquí están también las comprobaciones que comparten --limpiar, --eliminar y
# --eliminar-todo para no borrar nunca lo que no se debe:
#   - un disco que use cualquier máquina del servidor que no se vaya a eliminar;
#   - una imagen de la que dependa (directa o indirectamente) una copia que se
#     conserva;
#   - las imágenes cloud de partida;
#   - un dominio cuyos discos no están en el silo (no lo ha creado el alumno
#     con este script, aunque su nombre lo parezca: p.ej. con --prefijo).
########################################

# Los rellena quien llama: qué dominios y qué ficheros va a crear (o eliminar)
OBJ_DOMINIOS=()
OBJ_FICHEROS=()

# ¿Está VALOR entre los demás argumentos?
en_lista() {   # VALOR [ELEMENTO...]
    local x="$1" e
    shift
    for e in "$@"; do
        if [[ "$e" == "$x" ]]; then return 0; fi
    done
    return 1
}

# Pregunta sí/no por teclado. Con --si se da por contestada que sí. Sin
# terminal y sin --si no se puede preguntar, y eliminar sin confirmación sería
# peligroso (p.ej. desde un ssh sin sesión): se detiene con el error 23.
confirmar() {   # PREGUNTA
    if $SI; then
        echo "$1 [s/N] s   (--si)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        error 23 "Hace falta confirmar («$1») y no hay terminal para preguntarte.
No se ha eliminado nada. Si de verdad quieres hacerlo sin preguntas (p.ej. desde
otro script), repite el comando añadiendo --si."
    fi
    local respuesta
    read -r -p "$1 [s/N] " respuesta || { respuesta=""; echo; }
    case "$respuesta" in
        s|S|si|sí|Si|Sí|SI|SÍ) return 0 ;;
        *) return 1 ;;
    esac
}

########################################
# Quién usa cada disco
########################################

# Dominios "vecinos": TODOS los del servidor que no son objetivo de esta
# ejecución. Cualquiera de ellos podría estar usando un fichero de este silo
# (una máquina hecha a mano con otro nombre, otro prefijo, otro usuario...).
# De cada uno se anotan sus discos, para saber quién usa cada fichero.
declare -A DISCO_USADO_POR=()   # fichero → dominio vecino que lo usa
cargar_dominios_vecinos() {
    local lista d f salida
    DISCO_USADO_POR=()
    lista="$(virsh list --all --name 2>/dev/null || true)"
    while IFS= read -r d; do
        if [[ -z "$d" ]]; then continue; fi
        if en_lista "$d" ${OBJ_DOMINIOS[@]+"${OBJ_DOMINIOS[@]}"}; then continue; fi
        salida="$(virsh domblklist "$d" --inactive 2>/dev/null || true)"
        while IFS= read -r f; do
            if [[ -n "$f" && -z "${DISCO_USADO_POR[$f]:-}" ]]; then
                DISCO_USADO_POR[$f]="$d"
            fi
        done < <(awk 'NR > 2 && $2 ~ /^\// { print $2 }' <<< "$salida")
    done <<< "$lista"
}

# ¿Usa este fichero como disco alguna máquina vecina? Devuelve su nombre.
dominio_que_usa_disco() {   # FICHERO
    local d="${DISCO_USADO_POR[$1]:-}"
    if [[ -z "$d" ]]; then return 1; fi
    echo "$d"
}

# ¿Es el dominio de este silo? Todos sus discos tienen que estar en el silo
# (salvo el CD-ROM de cloud-init que deja virt-install), y al menos uno. Un
# dominio con discos en otro sitio no lo ha creado el script para este alumno,
# aunque se llame como si lo fuera.
dominio_en_silo() {   # DOMINIO
    local salida f n=0
    salida="$(virsh domblklist "$1" --inactive 2>/dev/null || true)"
    while IFS= read -r f; do
        case "$f" in
            "$SILO_DIR"/*)  n=$(( n + 1 )) ;;
            *cloudinit.iso) ;;
            *)              return 1 ;;
        esac
    done < <(awk 'NR > 2 && NF >= 2 && $2 != "-" { print $2 }' <<< "$salida")
    (( n > 0 ))
}

########################################
# Quién depende de cada imagen
#
# Se lee una sola vez la imagen base de cada qcow2 del silo (con un qemu-img
# por fichero), y todo lo demás se calcula sobre ese mapa.
########################################
declare -A RESPALDO=()     # fichero del silo → ruta de su imagen base
RESPALDOS_CARGADOS=false

cargar_respaldos() {
    if $RESPALDOS_CARGADOS; then return 0; fi
    local f
    for f in "$SILO_DIR"/*.qcow2 "$SILO_DIR"/*.img; do
        [[ -f "$f" ]] || continue
        RESPALDO[$f]="$(leer_respaldo "$f")"
    done
    RESPALDOS_CARGADOS=true
}

# Imagen base de un fichero (ruta completa), o nada. Las rutas relativas son
# relativas al directorio del propio fichero, como las interpreta qemu.
leer_respaldo() {   # FICHERO
    local b
    b="$(qemu-img info -U --output=json "$1" 2>/dev/null | jq -r '."backing-filename" // empty' 2>/dev/null || true)"
    if [[ -z "$b" ]]; then return 0; fi
    if [[ "$b" != /* ]]; then
        b="$(dirname "$1")/$b"
    fi
    printf '%s' "$b"
}

# Copias del silo cuya imagen base es este fichero, una por línea
copias_directas() {   # FICHERO
    local c
    cargar_respaldos
    for c in "${!RESPALDO[@]}"; do
        if [[ "${RESPALDO[$c]}" == "$1" ]]; then echo "$c"; fi
    done
}

# Decide cuáles de estos ficheros se pueden eliminar. Se conservan:
#   - las imágenes cloud de partida;
#   - los que use una máquina que no se va a eliminar;
#   - aquellos de los que dependa una copia que se conserva, aunque sea a
#     través de otra (si una copia se queda, se queda toda su cadena).
# Deja el resultado en BORRABLES y en CONSERVADOS ("nombre: motivo").
# Antes hay que llamar a cargar_dominios_vecinos.
BORRABLES=()
CONSERVADOS=()
filtrar_borrables() {   # FICHERO...
    local -A cand=()
    local f c otro cambio=true
    BORRABLES=()
    CONSERVADOS=()
    cargar_respaldos

    for f in "$@"; do
        if imagen_protegida "$f"; then
            CONSERVADOS+=( "$(basename "$f"): es una imagen cloud de partida (nunca se borra)" )
        elif otro="$(dominio_que_usa_disco "$f")"; then
            CONSERVADOS+=( "$(basename "$f"): lo usa la máquina '$otro'" )
        else
            cand[$f]=1
        fi
    done

    # Lo que se conserva por depender de ello una copia que se queda. Se repite
    # hasta que no cambia nada, para recorrer cadenas de cualquier longitud.
    while $cambio; do
        cambio=false
        for f in "${!cand[@]}"; do
            for c in "${!RESPALDO[@]}"; do
                if [[ "${RESPALDO[$c]}" == "$f" && -z "${cand[$c]:-}" ]]; then
                    unset 'cand[$f]'
                    CONSERVADOS+=( "$(basename "$f"): es la imagen base de $(basename "$c"), que se conserva" )
                    cambio=true
                    break
                fi
            done
        done
    done

    for f in "$@"; do
        if [[ -n "${cand[$f]:-}" ]]; then BORRABLES+=( "$f" ); fi
    done
}

########################################
# Conflictos con lo que el script va a crear
########################################
comprobar_conflictos() {   # [solo-detectar]
    local modo="${1:-}"
    local -a dominios=() ficheros=()
    local d f

    for d in ${OBJ_DOMINIOS[@]+"${OBJ_DOMINIOS[@]}"}; do
        if virsh dominfo "$d" >/dev/null 2>&1; then
            # Un dominio que se llama como los que crea el script pero tiene
            # sus discos fuera del silo es de otra persona (o hecho a mano):
            # ni se elimina ni se aconseja eliminarlo
            if ! dominio_en_silo "$d"; then
                error 21 "Ya existe una máquina llamada '$d', pero sus discos no están en tu silo:
no la ha creado este script para ti (puede ser de otro usuario del servidor), así que no se toca.
Elige otro nombre de máquina, u otro --prefijo."
            fi
            dominios+=( "$d" )
        fi
    done

    for f in ${OBJ_FICHEROS[@]+"${OBJ_FICHEROS[@]}"}; do
        if [[ -e "$f" ]]; then
            ficheros+=( "$f" )
        fi
    done

    if (( ${#dominios[@]} == 0 && ${#ficheros[@]} == 0 )); then
        return 0
    fi

    # Un fichero que ya existe puede ser el disco de otra máquina (hecha a mano
    # con otro nombre, o de otro prefijo) o el respaldo de otras copias.
    # Entonces ni se elimina ni se aconseja eliminarlo.
    if (( ${#ficheros[@]} > 0 )); then
        local msg x
        cargar_dominios_vecinos
        filtrar_borrables "${ficheros[@]}"
        if (( ${#CONSERVADOS[@]} > 0 )); then
            msg="Algunos de los discos que este script tendría que crear ya existen y no se pueden eliminar:"
            for x in "${CONSERVADOS[@]}"; do msg+=$'\n'"  $x"; done
            msg+=$'\n'"Elige otro nombre de máquina (o de disco, con --disco), u otro --prefijo."
            error 21 "$msg"
        fi
    fi

    # En la pasada previa a la descarga solo se avisa; con --limpiar, la
    # eliminación se hace en la pasada definitiva
    if [[ "$modo" == solo-detectar ]] && $LIMPIAR; then
        return 0
    fi

    if ! $LIMPIAR; then
        local msg="Ya existen elementos que este script tendría que crear:"
        for d in ${dominios[@]+"${dominios[@]}"}; do msg+=$'\n'"  dominio  $d"; done
        for f in ${ficheros[@]+"${ficheros[@]}"}; do msg+=$'\n'"  disco    $f"; done
        msg+=$'\n\n'"El script siempre crea máquinas y discos nuevos. Tienes estas opciones:"
        msg+=$'\n'"  a) Eliminarlos tú:"
        for d in ${dominios[@]+"${dominios[@]}"}; do
            msg+=$'\n'"       virsh destroy $d; virsh undefine $d --snapshots-metadata"
        done
        if (( ${#dominios[@]} > 0 )); then
            msg+=$'\n'"       (si la máquina ya está apagada, 'virsh destroy' dará un error; es normal)"
        fi
        for f in ${ficheros[@]+"${ficheros[@]}"}; do
            msg+=$'\n'"       rm $f"
        done
        msg+=$'\n'"  b) Repetir el comando añadiendo --limpiar, que elimina exactamente eso y nada más."
        if $CLUSTER && [[ -z "$BASE_OPT" ]] && en_lista "$(disco_base_cluster)" ${ficheros[@]+"${ficheros[@]}"}; then
            msg+=$'\n'"  c) Reutilizar la imagen base que ya tienes, sin volver a construirla:"
            msg+=$'\n'"       $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--gluster-cluster --base $(basename "$(disco_base_cluster)")"
            msg+=$'\n'"     (añade --limpiar si además existen los nodos)"
        fi
        error 21 "$msg"
    fi

    echo "--limpiar: se van a eliminar estos elementos (y solo estos):"
    for d in ${dominios[@]+"${dominios[@]}"}; do echo "  dominio  $d"; done
    for f in ${ficheros[@]+"${ficheros[@]}"}; do echo "  disco    $f"; done

    if $DRY_RUN; then
        echo "  (--dry-run: no se elimina nada)"
        echo
        return 0
    fi

    if ! confirmar "¿Eliminar estos elementos?"; then
        echo "Cancelado: no se ha eliminado nada."
        echo "No se ha creado nada. Usa otro nombre de máquina (o --prefijo) para no pisar lo que ya tienes."
        SALIDA_CONTROLADA=true
        exit 0
    fi

    for d in ${dominios[@]+"${dominios[@]}"}; do
        virsh destroy "$d" >/dev/null 2>&1 || true
        if ! virsh undefine "$d" --snapshots-metadata >/dev/null 2>&1; then
            error 21 "No se ha podido eliminar el dominio '$d'. Inténtalo a mano:
  virsh destroy $d; virsh undefine $d --snapshots-metadata"
        fi
        echo "  ✔ dominio $d eliminado"
    done

    for f in ${ficheros[@]+"${ficheros[@]}"}; do
        rm -f "$f"
        echo "  ✔ disco $f eliminado"
    done
    echo
}

########################################
# Expulsión del medio de cloud-init
#
# virt-install genera una ISO efímera en /var/lib/libvirt/boot/ con la
# configuración de cloud-init y la deja enganchada como CD-ROM. libvirt borra
# ese fichero más adelante, pero la referencia permanece en la definición de
# la máquina. Si se toma una instantánea mientras la referencia sigue ahí, al
# revertirla falla con "Cannot access storage file" (apartado B.6 del manual).
#
# Expulsando el medio en cuanto la máquina está configurada, las instantáneas
# que tome después el alumno ya no pueden heredar el problema.
########################################

# Devuelve la unidad que tiene enganchada la ISO de cloud-init, mirando tanto
# la definición activa como la persistente. Cadena vacía si no hay ninguna.
cloudinit_unidad() {
    local vm="$1" salida
    # Se recoge primero la salida y luego se filtra con un here-string. Si se
    # encadenara con una tubería, el 'exit' de awk cerraría el conducto antes
    # de que terminase el segundo virsh, que moriría con SIGPIPE y, por
    # 'pipefail', abortaría el script entero.
    salida="$(
        virsh domblklist "$vm" 2>/dev/null || true
        virsh domblklist "$vm" --inactive 2>/dev/null || true
    )"
    awk '$2 ~ /cloudinit\.iso$/ { print $1; exit }' <<< "$salida"
}

eject_cloudinit_media() {
    local vm="$1"
    local unidad

    unidad="$(cloudinit_unidad "$vm")"

    if [[ -z "$unidad" ]]; then
        return 0
    fi

    # Se intenta por separado sobre cada definición. Según el momento, libvirt
    # ya puede haber limpiado una de las dos por su cuenta, y entonces esa
    # llamada falla ('The disk device doesn't have media') aunque la otra sea
    # necesaria y perfectamente posible. Hacerlo en una sola llamada con
    # --live --config aborta las dos.
    virsh change-media "$vm" "$unidad" --eject --live   >/dev/null 2>&1 || true
    virsh change-media "$vm" "$unidad" --eject --config >/dev/null 2>&1 || true

    # Lo que decide es el estado final, no el código de salida de los intentos.
    if [[ -z "$(cloudinit_unidad "$vm")" ]]; then
        echo "✔ Medio de cloud-init expulsado de $vm: ya puedes tomar instantáneas."
    else
        echo "AVISO: no se ha podido expulsar el medio de cloud-init de $vm (unidad ${unidad})." >&2
        echo "       Apaga la máquina antes de tomar instantáneas." >&2
    fi
}

# Escalar YAML entre comillas simples (dentro, la comilla simple se duplica):
# así una contraseña con ':', '#' o espacios no rompe el user-data
yaml_comillas() {
    local q="'"
    printf "'%s'" "${1//$q/$q$q}"
}

########################################
# Generación de ficheros cloud-init
#
#   generar_cloudinit DOMINIO HOSTNAME IP MODO
#
#   MODO:
#     normal   máquina corriente
#     gluster  nodo GlusterFS suelto, o base del clúster: instala
#              glusterfs-server y xfsprogs, habilita glusterd y resetea el
#              machine-id para que las copias sean máquinas distintas
#     nodo     nodo del clúster, creado a partir de la base: ya tiene todo
#              instalado; solo se personaliza (IP, /etc/hosts, discos xfs)
#
# Deja las rutas en WORKDIR, USER_DATA, META_DATA y NETWORK_DATA (vacío si DHCP).
#
# Solo se usan claves vigentes en el cloud-init de Ubuntu 24.04: con una
# obsoleta (p.ej. 'chpasswd: list:' o 'ssh-authorized-keys') termina en
# 'degraded done', que el script trata como error.
########################################
generar_cloudinit() {
    local vm="$1" host="$2" ip="$3" modo="$4"

    preparar_workdir "$vm"
    escribir_meta_data "$vm" "$host"
    {
        echo "#cloud-config"
        yaml_usuarios
        yaml_paquetes_y_ficheros "$modo" "$host"
        yaml_runcmd "$modo"
    } > "$USER_DATA"
    chmod 600 "$USER_DATA"
    escribir_network_config "$ip"
}

# Directorio de los ficheros. En --dry-run es otro, para no sobrescribir los
# de una máquina que ya exista.
preparar_workdir() {   # DOMINIO
    if $DRY_RUN; then
        WORKDIR="${SILO_DIR}/cloudinit-$1.dry-run"
    else
        WORKDIR="${SILO_DIR}/cloudinit-$1"
        # Si algo falla después, el rollback lo quita junto a los discos
        DIRS_CREADOS+=( "$WORKDIR" )
    fi

    # Estos ficheros contienen contraseñas en texto plano y el servidor de la
    # asignatura es multiusuario: solo su propietario debe poder leerlos, ni
    # siquiera un instante (por eso el umask, y no un chmod después).
    rm -rf "$WORKDIR"
    ( umask 077 && mkdir -p "$WORKDIR" )
    chmod 700 "$WORKDIR"

    USER_DATA="$WORKDIR/cip-user.yaml"
    META_DATA="$WORKDIR/cip-meta.yaml"
    NETWORK_DATA=""
}

# El instance-id importa: cloud-init vuelve a configurar una máquina cuando ve
# uno distinto del que tenía. Así se personalizan los nodos del clúster, que
# parten de un disco ya configurado. Lleva la fecha para que sea nuevo aunque
# el disco de partida ya hubiera sido una máquina con el mismo nombre.
escribir_meta_data() {   # DOMINIO HOSTNAME
    ( umask 077 && cat > "$META_DATA" <<EOF
instance-id: $1-$(date +%Y%m%d%H%M%S)
local-hostname: $2
EOF
    )
}

# Usuarios, contraseñas y acceso por SSH
yaml_usuarios() {
    echo "users:"
    echo "  - name: administrador"
    if [[ "$IMAGEN" == ubuntu-base ]]; then
        # En ubuntu-base 'administrador' ya existe, con la contraseña del
        # boletín 1, y sudo se la pide: se deja como está (lock_passwd: false
        # para que cloud-init no la bloquee) y solo se añade la clave
        echo "    lock_passwd: false"
    else
        echo "    groups: [sudo]"
        echo "    shell: /bin/bash"
        echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']"
    fi
    echo "    ssh_authorized_keys:"
    # Entre comillas: el comentario de la clave puede llevar ': ' o '#'
    echo "      - $(yaml_comillas "$PUBKEY")"

    # root tiene contraseña para poder entrar por consola (por SSH no
    # entra: el sshd de Debian y el de Ubuntu traen PermitRootLogin
    # prohibit-password). Hace falta, p.ej., en el modo de rescate del
    # epígrafe 2.3 del boletín 2. 'administrador' solo la tiene si se pide
    # --ssh-pass; si no, entra únicamente por SSH con su clave, igual que
    # en las máquinas que se crean a mano siguiendo el boletín.
    if [[ -n "$SSH_PASS" ]] || ! $NO_ROOT; then
        echo "chpasswd:"
        echo "  expire: false"
        echo "  users:"
        if [[ -n "$SSH_PASS" ]]; then
            echo "    - name: administrador"
            echo "      password: $(yaml_comillas "$SSH_PASS")"
            echo "      type: text"
        fi
        if ! $NO_ROOT; then
            echo "    - name: root"
            echo "      password: ${PASS_CONSOLA}"
            echo "      type: text"
        fi
    fi

    # SSH por contraseña solo si el alumno lo pide explícitamente. Se fija
    # también el 'false' para no depender del valor por defecto de la
    # imagen, salvo en ubuntu-base, que lo trae activado y se respeta.
    if [[ -n "$SSH_PASS" ]]; then
        echo "ssh_pwauth: true"
    elif [[ "$IMAGEN" != ubuntu-base ]]; then
        echo "ssh_pwauth: false"
    fi
}

# Paquetes y, en los nodos, /etc/hosts y discos xfs
yaml_paquetes_y_ficheros() {   # MODO HOSTNAME
    local modo="$1" host="$2" i
    case "$modo" in
        normal|gluster)
            echo "package_update: true"
            echo "packages:"
            echo "  - qemu-guest-agent"
            if [[ "$modo" == "gluster" ]]; then
                echo "  - glusterfs-server"
                # Necesario para que los nodos del clúster puedan formatear
                # sus discos en xfs en el primer arranque
                echo "  - xfsprogs"
            fi
            ;;
        nodo)
            # La base ya tiene todo instalado: no hace falta tocar apt
            echo "package_update: false"

            # Resolución por nombre entre los nodos (epígrafe 2.4 c).
            # Se fija manage_etc_hosts a false para que cloud-init no
            # regenere /etc/hosts en cada arranque y pise lo escrito aquí.
            echo "manage_etc_hosts: false"
            echo "write_files:"
            echo "  - path: /etc/hosts"
            echo "    content: |"
            echo "      127.0.0.1 localhost"
            echo "      127.0.1.1 ${host}"
            for i in "${!CLUSTER_NODOS[@]}"; do
                echo "      ${CLUSTER_IPS[$i]} ${CLUSTER_NODOS[$i]}"
            done
            echo "      ::1 localhost ip6-localhost ip6-loopback"
            echo "      ff02::1 ip6-allnodes"
            echo "      ff02::2 ip6-allrouters"

            # Discos vdb, vdc y vdd formateados en xfs. Deben estar
            # conectados desde el primer arranque: por eso se pasan a
            # virt-install en vez de añadirlos después. El montaje va en
            # runcmd (ver yaml_runcmd) para que las líneas de /etc/fstab sean
            # las mismas que escribe crea-entorno.sh; el módulo 'mounts' de
            # cloud-init las escribiría a su manera.
            echo "fs_setup:"
            for i in "${!CLUSTER_MONTAJES[@]}"; do
                echo "  - device: /dev/${UNIDADES_CLUSTER[$i]}"
                echo "    filesystem: xfs"
                echo "    partition: none"
                echo "    overwrite: false"
            done
            ;;
    esac
}

yaml_runcmd() {   # MODO
    local modo="$1" i
    echo "runcmd:"
    if [[ "$modo" == "nodo" ]]; then
        echo "  - mkdir -p ${CLUSTER_MONTAJES[*]}"
        for i in "${!CLUSTER_MONTAJES[@]}"; do
            echo "  - echo '/dev/${UNIDADES_CLUSTER[$i]} ${CLUSTER_MONTAJES[$i]} xfs ${OPCIONES_FSTAB_CLUSTER} 0 0' >> /etc/fstab"
        done
        echo "  - mount -a"
    fi
    if [[ "$IMAGEN" == ubuntu-base ]] && $NO_ROOT; then
        # ubuntu-base trae root con contraseña: --no-root la bloquea
        echo "  - passwd -l root"
    fi
    echo "  - timedatectl set-timezone Europe/Madrid"
    if [[ "$modo" == "gluster" ]]; then
        # Solo se habilita glusterd, no se arranca: así no genera su UUID en
        # la base, y cada copia tendrá el suyo cuando arranque
        echo "  - systemctl enable glusterd"
    fi
    echo "  - systemctl start qemu-guest-agent"
    if [[ "$modo" == "gluster" ]]; then
        # machine-id vacío: cada copia de este disco generará el suyo
        echo "  - truncate -s 0 /etc/machine-id"
    fi
}

# network-config, solo si la IP es fija. La pasarela y el prefijo se toman de
# la configuración real de la red (ver load_network_info). Se usa la forma
# 'routes:' en lugar de la obsoleta 'gateway4:', como el capítulo 6 del manual.
escribir_network_config() {   # IP
    [[ -n "$1" ]] || return 0
    NETWORK_DATA="$WORKDIR/cip-net.yaml"
    ( umask 077 && cat > "$NETWORK_DATA" <<EOF
version: 2
ethernets:
  enp1s0:
    addresses:
      - $1/${NET_PREFIX}
    routes:
      - to: default
        via: ${NET_GATEWAY}
    nameservers:
      addresses:
        - 150.214.186.69
        - 150.214.130.15
EOF
    )
}

########################################
# Creación de discos
#
# Todos los discos los crea el script; los registra en DISCOS_CREADOS antes
# de crearlos, para que se eliminen si la ejecución falla a medias.
########################################

# Copia COW de una imagen que está en el mismo directorio del silo.
# El respaldo se referencia con ruta relativa, como hace el manual, para que
# el silo se pueda mover sin romper la cadena.
#   crear_disco_cow RUTA IMAGEN_BASE TAMAÑO
crear_disco_cow() {
    local ruta="$1" base="$2" tam="$3"
    local dir
    dir="$(dirname "$ruta")"

    DISCOS_CREADOS+=( "$ruta" )
    (
        cd "$dir" && \
        qemu-img create -f qcow2 -b "$(basename "$base")" -F qcow2 "$(basename "$ruta")" "$tam" >/dev/null
    )
}

# Copia completa de una imagen de fuera del silo (ubuntu-base, que está en un
# directorio compartido): una copia COW dependería de un fichero que no es del
# alumno y que puede cambiar. Si se pide un tamaño mayor, se amplía.
#   crear_disco_copia RUTA IMAGEN TAMAÑO
crear_disco_copia() {
    local ruta="$1" origen="$2" tam="$3" vs

    DISCOS_CREADOS+=( "$ruta" )
    cp "$origen" "$ruta"
    chmod u+w "$ruta"

    vs="$(tam_virtual "$ruta")"
    if [[ "$vs" =~ ^[0-9]+$ ]] && (( $(tam_a_bytes "$tam") > vs )); then
        qemu-img resize -q "$ruta" "$tam"
    fi
}

# El disco principal de una máquina: copia COW de una imagen del silo, o copia
# completa si la imagen está fuera de él (ubuntu-base)
#   crear_disco_principal RUTA IMAGEN TAMAÑO
crear_disco_principal() {
    if [[ "$(dirname "$2")" == "$SILO_DIR" ]]; then
        crear_disco_cow "$@"
    else
        crear_disco_copia "$@"
    fi
}

# Cómo se hace el disco principal a partir de una imagen, para los mensajes
origen_disco_principal() {   # IMAGEN
    if [[ "$(dirname "$1")" == "$SILO_DIR" ]]; then
        echo "copia COW de $(basename "$1")"
    else
        echo "copia completa de $1"
    fi
}

# Disco vacío (sin respaldo)
#   crear_disco_vacio RUTA TAMAÑO
crear_disco_vacio() {
    local ruta="$1" tam="$2"

    DISCOS_CREADOS+=( "$ruta" )
    qemu-img create -f qcow2 "$ruta" "$tam" >/dev/null
}

# Quita un fichero del registro de creados (cuando pasa a ser definitivo)
quitar_disco_creado() {
    quitar_de_lista DISCOS_CREADOS "$1"
}

# Quita VALOR del array cuyo nombre se indica (por referencia)
quitar_de_lista() {   # NOMBRE_ARRAY VALOR
    local -n lista_ref="$1"
    local quitar="$2" x
    local -a nuevos=()
    for x in ${lista_ref[@]+"${lista_ref[@]}"}; do
        if [[ "$x" != "$quitar" ]]; then
            nuevos+=( "$x" )
        fi
    done
    lista_ref=( ${nuevos[@]+"${nuevos[@]}"} )
}

# Rutas de los discos extra de una máquina, una por línea
#   discos_extra MAQUINA UNIDAD...
discos_extra() {
    local host="$1" u
    shift
    for u in "$@"; do
        echo "${SILO_DIR}/${PREFIJO_FICHERO}${host}-${u}.qcow2"
    done
}

########################################
# Espera activa a que cloud-init termine
#
# Una espera de duración fija no sirve: las medidas en los tres servidores
# mostraron que cloud-init tarda entre 60 y 140 segundos según lo que instale
# y la carga del servidor. En su lugar se consulta al guest agent:
#
#   1. Que el agente responda con la IP de la máquina ya dice que ha
#      arrancado y, en una máquina recién creada, que apt ha terminado
#      (el agente se instala con cloud-init).
#   2. Además, a través del propio agente se ejecuta 'cloud-init status'
#      dentro de la máquina, que dice exactamente si ha terminado. Esto es
#      imprescindible en los nodos del clúster, donde el agente ya está
#      instalado de antes y responde mucho antes de que cloud-init acabe.
#
# Si el agente no permite ejecutar comandos, se recurre solo al punto 1 con
# un pequeño margen, y se avisa.
########################################

declare -A IPS_DETECTADAS=()   # dominio → IP que reporta el agente
declare -A ESTADO_CI=()        # dominio → done | error | asumido
declare -A IP_ESPERADA=()      # dominio → IP fija que debe tener (si la hay)
declare -A FALLOS_CONSULTA=()  # dominio → veces seguidas sin poder consultar cloud-init
declare -A ASUMIDO_DESDE=()    # dominio → instante en que se empezó a asumir que está lista
EXIGIR_ESTADO_CI=false         # true: no vale asumir; hace falta leer el estado de cloud-init (la base GlusterFS)
declare -A IP_VISTA=()         # dominio → última IP que ha reportado el agente, esté lista o no

limpiar_linea() {
    if [[ -t 1 ]]; then
        printf '\r\033[K'
    fi
}

# Devuelve por stdout la primera IPv4 no local que reporte el guest agent.
# Cadena vacía si el agente no responde todavía.
obtener_ip_agente() {
    local vm="$1" salida
    # Nada de tuberías hacia un awk que hace 'exit': con 'pipefail' un SIGPIPE
    # aguas arriba abortaría el script.
    salida="$(virsh domifaddr "$vm" --source agent 2>/dev/null || true)"
    awk '$3 == "ipv4" && $4 !~ /^127\./ { split($4, a, "/"); print a[1]; exit }' <<< "$salida"
}

# Ejecuta 'cloud-init status' dentro de la máquina a través del guest agent y
# devuelve por stdout su estado (done, running, error, ...).
# Devuelve 1 si no se ha podido consultar.
#
# Desde cloud-init 23.4 (Ubuntu 24.04), 'cloud-init status' escribe "done"
# aunque haya terminado con avisos; lo que lo distingue es el código de salida:
# 0 bien, 1 error, 2 terminado con avisos ("degraded"). Por eso se mira también.
cloudinit_status() {
    local vm="$1" r pid s exited datos i estado codigo

    r="$(virsh qemu-agent-command "$vm" --timeout 5 \
          '{"execute":"guest-exec","arguments":{"path":"/usr/bin/cloud-init","arg":["status"],"capture-output":true}}' \
          2>/dev/null || true)"
    pid="$(jq -r '.return.pid // empty' <<< "$r" 2>/dev/null || true)"

    if [[ -z "$pid" ]]; then
        return 1
    fi

    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        s="$(virsh qemu-agent-command "$vm" --timeout 5 \
              "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}" \
              2>/dev/null || true)"
        exited="$(jq -r '.return.exited // empty' <<< "$s" 2>/dev/null || true)"
        if [[ "$exited" == "true" ]]; then
            datos="$( { jq -r '.return."out-data" // empty' <<< "$s" | base64 -d; } 2>/dev/null || true)"
            codigo="$(jq -r '.return.exitcode // empty' <<< "$s" 2>/dev/null || true)"
            estado="$(awk '/^status:/ { sub(/^status: */, ""); print; exit }' <<< "$datos")"
            if [[ "$estado" == "done" && "$codigo" == "2" ]]; then
                estado="degraded done"
            fi
            printf '%s\n' "$estado"
            return 0
        fi
    done

    return 1
}

# ¿Está la máquina lista? Deja la IP en IPS_DETECTADAS y el estado en ESTADO_CI.
maquina_lista() {
    local vm="$1" ip estado n

    ip="$(obtener_ip_agente "$vm")"
    if [[ -z "$ip" ]]; then
        return 1
    fi
    IP_VISTA[$vm]="$ip"

    # Si se pidió IP fija, se exige esa IP concreta
    if [[ -n "${IP_ESPERADA[$vm]:-}" && "$ip" != "${IP_ESPERADA[$vm]}" ]]; then
        return 1
    fi

    if estado="$(cloudinit_status "$vm")"; then
        FALLOS_CONSULTA[$vm]=0
        unset 'ASUMIDO_DESDE[$vm]'
        case "$estado" in
            done)
                IPS_DETECTADAS[$vm]="$ip"
                ESTADO_CI[$vm]="done"
                return 0
                ;;
            error|"degraded done")
                IPS_DETECTADAS[$vm]="$ip"
                ESTADO_CI[$vm]="error"
                return 0
                ;;
            *)
                # running, not run, disabled...
                return 1
                ;;
        esac
    fi

    # No se ha podido consultar cloud-init. Si pasa varias veces seguidas, se
    # da la máquina por lista en cuanto lleve GRACE_SECS respondiendo.
    n=$(( ${FALLOS_CONSULTA[$vm]:-0} + 1 ))
    FALLOS_CONSULTA[$vm]=$n

    if (( n >= 3 )) && ! $EXIGIR_ESTADO_CI; then
        if [[ -z "${ASUMIDO_DESDE[$vm]:-}" ]]; then
            ASUMIDO_DESDE[$vm]=$SECONDS
        elif (( SECONDS - ASUMIDO_DESDE[$vm] >= GRACE_SECS )); then
            IPS_DETECTADAS[$vm]="$ip"
            ESTADO_CI[$vm]="asumido"
            return 0
        fi
    fi

    return 1
}

# Espera hasta que todas las máquinas indicadas estén operativas o se agote
# WAIT_TIMEOUT. Devuelve 0 si todas terminaron, 1 si alguna no.
esperar_maquinas() {
    local -a pendientes=( "$@" ) restantes
    local inicio=$SECONDS transcurrido vm

    echo "Esperando a que cloud-init termine de configurar ${#pendientes[@]} máquina(s)."
    echo "Puede tardar entre uno y tres minutos, según lo que haya que instalar."

    while true; do
        restantes=()
        for vm in "${pendientes[@]}"; do
            if maquina_lista "$vm"; then
                transcurrido=$(( SECONDS - inicio ))
                limpiar_linea
                case "${ESTADO_CI[$vm]}" in
                    done)
                        echo "✔ $vm operativa tras ${transcurrido}s. IP: ${IPS_DETECTADAS[$vm]}"
                        ;;
                    error)
                        echo "⚠ $vm ha arrancado (IP ${IPS_DETECTADAS[$vm]}), pero cloud-init informa de errores tras ${transcurrido}s."
                        echo "  Entra en la máquina y revisa: sudo cloud-init status --long"
                        ;;
                    asumido)
                        echo "✔ $vm responde tras ${transcurrido}s. IP: ${IPS_DETECTADAS[$vm]}"
                        echo "  (no se ha podido consultar el estado de cloud-init; se da por terminado)"
                        ;;
                esac
            else
                restantes+=( "$vm" )
            fi
        done

        pendientes=( ${restantes[@]+"${restantes[@]}"} )
        if (( ${#pendientes[@]} == 0 )); then
            return 0
        fi

        transcurrido=$(( SECONDS - inicio ))
        if (( transcurrido >= WAIT_TIMEOUT )); then
            limpiar_linea
            echo "AVISO: no ha(n) terminado en ${WAIT_TIMEOUT}s: ${pendientes[*]}" >&2
            echo "       Puede que siga(n) instalando paquetes. Comprueba su estado con:" >&2
            for vm in "${pendientes[@]}"; do
                echo "         virsh domifaddr $vm --source agent" >&2
                if [[ -n "${IP_VISTA[$vm]:-}" ]]; then
                    if [[ -n "${IP_ESPERADA[$vm]:-}" && "${IP_VISTA[$vm]}" != "${IP_ESPERADA[$vm]}" ]]; then
                        echo "         ($vm responde en ${IP_VISTA[$vm]} y no en la IP fija ${IP_ESPERADA[$vm]}: la configuración de red no se ha aplicado)" >&2
                    else
                        echo "         ($vm ya responde en ${IP_VISTA[$vm]}; cloud-init sigue trabajando)" >&2
                    fi
                fi
            done
            echo "       Si no responde, entra por consola: virsh console NOMBRE" >&2
            return 1
        fi

        if [[ -t 1 ]]; then
            printf '\r  … %ss  (esperando: %s)' "$transcurrido" "${pendientes[*]}"
        fi
        sleep "$POLL_SECS"
    done
}

# Apaga una máquina de forma limpia y espera a que esté parada.
# Devuelve 1 si no se ha apagado en SHUTDOWN_TIMEOUT.
apagar_maquina() {
    local vm="$1" inicio=$SECONDS estado

    virsh shutdown "$vm" >/dev/null 2>&1 || true

    while true; do
        estado="$(virsh domstate "$vm" 2>/dev/null || true)"
        if [[ "$estado" == "shut off" ]]; then
            return 0
        fi
        if (( SECONDS - inicio >= SHUTDOWN_TIMEOUT )); then
            return 1
        fi
        sleep 2
    done
}

########################################
# Infraestructura GlusterFS completa (boletín 2, epígrafe 2.4)
#
# Dos fases, las mismas que describe el boletín, pero todo con cloud-init:
#
#   Fase 1  Base gluster-base.qcow2: por defecto, una copia COW de la imagen
#           cloud de Ubuntu (la misma que SERVER1); con --imagen ubuntu-base,
#           una copia de ubuntu-base.qcow2, como en la construcción manual
#           (apartado 2.4 b). Se arranca con glusterfs-server
#           instalado, glusterd habilitado y el machine-id vacío; se espera a
#           que termine, se apaga y se elimina su dominio conservando el disco.
#   Fase 2  Cada nodo es una copia COW de ese disco con sus discos extra
#           conectados desde el primer arranque. Un instance-id nuevo hace
#           que cloud-init lo personalice: IP fija, /etc/hosts, discos xfs
#           montados. Los nodos arrancan en paralelo y se espera a todos.
#
# Frente a crea-entorno.sh no hace falta virt-customize (el error 'supermin'
# desaparece), ni virt-format, ni xmllint; cada nodo tiene sus propias claves
# SSH de host, y las IPs se validan contra el DHCP real.
########################################

# Quita un dominio del registro de creados (cuando se elimina a propósito)
quitar_dominio_creado() {
    quitar_de_lista DOMINIOS_CREADOS "$1"
}

# Discos extra de un nodo
discos_extra_nodo() {
    discos_extra "$1" "${UNIDADES_CLUSTER[@]}"
}

# Disco de la imagen base del clúster: la que se construye en la fase 1 o,
# con --base, una que ya existe en el silo
disco_base_cluster() {
    if [[ -n "$BASE_OPT" ]]; then
        echo "${SILO_DIR}/${BASE_OPT}"
    else
        echo "${SILO_DIR}/$(disco_de "$CLUSTER_BASE")"
    fi
}

# "vdb, vdc y vdd en xfs, montados en /gluster1 /gluster2 /gluster3"
texto_discos_montados() {
    local n=${#CLUSTER_MONTAJES[@]}
    local -a u=( "${UNIDADES_CLUSTER[@]:0:$n}" )
    printf '%s y %s en xfs, montados en %s' "$(IFS=,; echo "${u[*]:0:n-1}" | sed 's/,/, /g')" "${u[-1]}" "${CLUSTER_MONTAJES[*]}"
}

# "; vde..vdh sin formatear" (nada si solo están los que se montan)
texto_discos_sin_formatear() {
    local n=${#CLUSTER_MONTAJES[@]}
    if (( ${#UNIDADES_CLUSTER[@]} == n + 1 )); then
        printf '; %s sin formatear' "${UNIDADES_CLUSTER[$n]}"
    elif (( ${#UNIDADES_CLUSTER[@]} > n + 1 )); then
        printf '; %s..%s sin formatear' "${UNIDADES_CLUSTER[$n]}" "${UNIDADES_CLUSTER[-1]}"
    fi
}

# Rellena OBJ_DOMINIOS y OBJ_FICHEROS con todo lo que crea el clúster
objetivos_cluster() {
    local host d
    OBJ_DOMINIOS=()
    OBJ_FICHEROS=()
    if [[ -z "$BASE_OPT" ]]; then
        OBJ_DOMINIOS+=( "${PREFIJO_DOMINIO}-${CLUSTER_BASE}" )
        OBJ_FICHEROS+=( "${SILO_DIR}/$(disco_de "$CLUSTER_BASE")" )
    fi
    for host in "${CLUSTER_NODOS[@]}"; do
        OBJ_DOMINIOS+=( "${PREFIJO_DOMINIO}-${host}" )
        OBJ_FICHEROS+=( "${SILO_DIR}/$(disco_de "$host")" )
        while IFS= read -r d; do
            OBJ_FICHEROS+=( "$d" )
        done < <(discos_extra_nodo "$host")
    done
}

########################################
# Base GlusterFS: crea la máquina, espera a que cloud-init termine, la apaga
# y elimina el dominio. Queda solo el disco, listo para hacer copias COW.
# Es lo que describen los apartados 2.4 a) y b) del boletín 2, y lo usan
# tanto --glusterfs como la fase 1 de --gluster-cluster.
#   crear_base_gluster DOMINIO HOSTNAME DISCO
########################################
crear_base_gluster() {
    local vm="$1" host="$2" disco="$3"

    crear_maquina "$vm" "$host" "" gluster "$disco" "$BASE_IMG"

    # Para una base no vale "se da por terminada": si no se puede consultar
    # cloud-init, se sigue esperando hasta agotar el tiempo
    local lista=true acceso
    EXIGIR_ESTADO_CI=true
    esperar_maquinas "$vm" || lista=false
    EXIGIR_ESTADO_CI=false
    if ! $lista; then
        error 70 "No se ha podido confirmar que cloud-init haya terminado en '$vm' en ${WAIT_TIMEOUT}s.
Sin esa confirmación no puede servir de base. Comprueba la carga del servidor y vuelve a intentarlo."
    fi

    if [[ "${ESTADO_CI[$vm]}" != "done" ]]; then
        # Se conserva la máquina para poder examinarla
        CREACION_COMPLETA=true
        if $NO_ROOT; then
            acceso="ssh administrador@${IPS_DETECTADAS[$vm]:-IP}    (con tu clave)"
        else
            acceso="virsh console $vm    (root, contraseña ${PASS_CONSOLA})"
        fi
        error 71 "cloud-init ha terminado con errores en '$vm' (probablemente al instalar
glusterfs-server). Las copias heredarían el problema, así que se detiene aquí.
La máquina se conserva para que puedas examinarla:
  $acceso
  y dentro: cloud-init status --long
Cuando termines, repite el comando añadiendo --limpiar, o elimínala tú:
  virsh destroy $vm; virsh undefine $vm --snapshots-metadata; rm $disco"
    fi

    echo "→ Apagando '$vm'…"
    if ! apagar_maquina "$vm"; then
        error 70 "La máquina '$vm' no se ha apagado en ${SHUTDOWN_TIMEOUT}s.
Se deshace lo creado en esta ejecución. Comprueba la carga del servidor (virsh list --all, uptime)
y vuelve a intentarlo. Si el dominio siguiera ahí: virsh destroy $vm; virsh undefine $vm --snapshots-metadata"
    fi

    # El dominio sobra: el disco se queda como respaldo de las copias
    virsh undefine "$vm" --snapshots-metadata >/dev/null
    quitar_dominio_creado "$vm"
    # A partir de aquí la base ya vale: si falla lo siguiente, se conserva
    quitar_disco_creado "$disco"
    BASE_CONSERVADA="$disco"
    echo "✔ Base lista: $(basename "$disco") (el dominio '$vm' se ha eliminado; el disco se conserva)."
}

mostrar_plan_cluster() {
    local base_vm="${PREFIJO_DOMINIO}-${CLUSTER_BASE}"
    local base_disco i host vm d comando_primero=""
    local -a extras=()
    base_disco="$(disco_base_cluster)"

    echo "→ MODO SIMULACIÓN (--dry-run): no se creará nada."
    echo
    echo "✔ Validaciones superadas."
    echo "    Usuario : $USUARIO"
    if [[ -n "$PREFIJO_OPT" ]]; then
        echo "    Prefijo : $PREFIJO_OPT (sustituye al usuario en los dominios y en los discos)"
    fi
    echo "    Red     : $NET_NAME (pasarela $NET_GATEWAY, prefijo /$NET_PREFIX)"
    echo "    Nodos   :"
    for i in "${!CLUSTER_NODOS[@]}"; do
        echo "      ${PREFIJO_DOMINIO}-${CLUSTER_NODOS[$i]}  →  ${CLUSTER_IPS[$i]}"
    done
    echo "    Sistema : $(descripcion_imagen "$IMAGEN"); variante $OS_VARIANT"
    echo "    Recursos: ${RAM_MB} MB y ${VCPUS} vCPU por máquina"
    avisar_imagen_falta
    echo

    if [[ -n "$BASE_OPT" ]]; then
        echo "Fase 1: se omite. Los nodos partirán de la imagen que ya existe: $(basename "$base_disco")"
    else
        echo "Fase 1: base GlusterFS"
        echo "    Máquina $base_vm con disco $(basename "$base_disco") ($(origen_disco_principal "$BASE_IMG"), $TAM_DISCO)."
        echo "    Instala glusterfs-server (y las herramientas para formatear en xfs), habilita glusterd, vacía el machine-id."
        echo "    Al terminar se apaga y se elimina el dominio; el disco se conserva como respaldo."
        generar_cloudinit "$base_vm" "$CLUSTER_BASE" "" gluster
        construir_comando "$base_vm" "$RAM_MB" "$VCPUS" "$base_disco"
        echo "    Ficheros cloud-init en $WORKDIR/"
        echo "    Comando:"
        imprimir_comando | sed 's/^/    /'
    fi
    echo

    echo "Fase 2: ${#CLUSTER_NODOS[@]} nodos, cada uno con ${#UNIDADES_CLUSTER[@]} discos extra de ${TAM_DISCO_EXTRA}"
    echo "    $(texto_discos_montados)$(texto_discos_sin_formatear)."
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${PREFIJO_DOMINIO}-${host}"
        generar_cloudinit "$vm" "$host" "${CLUSTER_IPS[$i]}" nodo
        echo "    $vm: disco $(disco_de "$host") (COW de $(basename "$base_disco")), IP ${CLUSTER_IPS[$i]}, cloud-init en $WORKDIR/"
        if (( i == 0 )); then
            extras=()
            while IFS= read -r d; do extras+=( "$d" ); done < <(discos_extra_nodo "$host")
            construir_comando "$vm" "$RAM_MB" "$VCPUS" "${SILO_DIR}/$(disco_de "$host")" "${extras[@]}"
            comando_primero="$(imprimir_comando)"
        fi
    done
    echo
    echo "    Comando del primer nodo (los demás son iguales, con su nombre, IP y discos):"
    sed 's/^/    /' <<< "$comando_primero"
    echo
    echo "No se ha creado ni modificado ninguna máquina, disco ni red."
}

print_summary_cluster() {
    local i host vm ip base_disco
    base_disco="$(disco_base_cluster)"
    echo "-------------------------------------------"
    echo "Infraestructura GlusterFS creada (boletín 2, epígrafe 2.4)"
    echo
    echo "Red          : $NET_NAME"
    echo "Nodos        :"
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${PREFIJO_DOMINIO}-${host}"
        ip="${IPS_DETECTADAS[$vm]:-${CLUSTER_IPS[$i]}}"
        printf '  %-28s %-16s hostname %s\n' "$vm" "$ip" "$host"
    done
    echo "RAM / vCPUs  : ${RAM_MB} MB / ${VCPUS} por nodo"
    echo "Sistema      : $(descripcion_imagen "$IMAGEN")"
    echo "Discos       : ${UNIDADES_CLUSTER[0]}..${UNIDADES_CLUSTER[-1]} (${#UNIDADES_CLUSTER[@]} × ${TAM_DISCO_EXTRA}) en cada nodo"
    echo "               $(texto_discos_montados)$(texto_discos_sin_formatear)"
    echo "GlusterFS    : glusterfs-server instalado y glusterd habilitado en todos"
    echo "/etc/hosts   : con los ${#CLUSTER_NODOS[@]} nombres, en todos"
    echo
    echo "Acceso (igual en todos los nodos, con la IP de cada uno):"
    vm="${PREFIJO_DOMINIO}-${CLUSTER_NODOS[0]}"
    bloque_acceso "$vm" "${IPS_DETECTADAS[$vm]:-${CLUSTER_IPS[0]}}"
    echo
    echo "IMPORTANTE: no borres $base_disco."
    echo "            Los discos de los ${#CLUSTER_NODOS[@]} nodos dependen de él."
    echo
    echo "Para eliminar la infraestructura entera (nodos${BASE_OPT:- e imagen base}):"
    echo "  $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--eliminar ${CLUSTER_NODOS[*]}${BASE_OPT:+}${BASE_OPT:- $CLUSTER_BASE}"
    echo "-------------------------------------------"
}

ejecutar_cluster() {
    local base_vm="${PREFIJO_DOMINIO}-${CLUSTER_BASE}"
    local base_disco i host vm ip disco d
    local -a extras nodos_vm=()
    base_disco="$(disco_base_cluster)"

    comprobar_conflictos

    if $DRY_RUN; then
        mostrar_plan_cluster
        return 0
    fi

    ########################################
    # Fase 1: base
    ########################################
    if [[ -n "$BASE_OPT" ]]; then
        echo "═══ Fase 1 de 2: se omite; los nodos parten de $(basename "$base_disco") ═══"
    else
        echo "═══ Fase 1 de 2: base GlusterFS ($base_vm) ═══"
        crear_base_gluster "$base_vm" "$CLUSTER_BASE" "$base_disco"
    fi
    echo

    ########################################
    # Fase 2: nodos
    ########################################
    echo "═══ Fase 2 de 2: ${#CLUSTER_NODOS[@]} nodos ═══"
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${PREFIJO_DOMINIO}-${host}"
        ip="${CLUSTER_IPS[$i]}"
        disco="${SILO_DIR}/$(disco_de "$host")"
        extras=()
        while IFS= read -r d; do extras+=( "$d" ); done < <(discos_extra_nodo "$host")

        echo "── $vm ($ip)"
        crear_maquina "$vm" "$host" "$ip" nodo "$disco" "$base_disco" "${extras[@]}"
        nodos_vm+=( "$vm" )
    done
    CREACION_COMPLETA=true
    echo "✔ Los ${#nodos_vm[@]} nodos están creados y arrancando."
    echo "-------------------------------------------"

    if $NO_WAIT; then
        echo "Omitiendo la espera (--no-wait activo)."
        echo "NOTA: los nodos siguen configurándose por dentro (discos xfs, /etc/hosts...)."
        echo "      No se expulsa el medio de cloud-init; apágalos antes de tomar instantáneas."
    else
        esperar_maquinas "${nodos_vm[@]}" || true
        for vm in "${nodos_vm[@]}"; do
            if [[ -n "${ESTADO_CI[$vm]:-}" ]]; then
                eject_cloudinit_media "$vm"
            fi
        done
    fi

    print_summary_cluster
    avisar_known_hosts "${CLUSTER_IPS[@]}"
}

########################################
# Ver y eliminar lo que ya existe: --listar, --eliminar y --eliminar-todo
#
# Todo parte de libvirt, no de los nombres: los discos de una máquina son los
# que dice 'virsh domblklist' (solo los que están en el silo). Nunca se borra
# un disco que use otra máquina ni una imagen de la que dependan otras copias
# (ver filtrar_borrables en limpieza.sh).
########################################

# Dominios del usuario (o del prefijo): los que empiezan por PREFIJO- y tienen
# sus discos en el silo. Los nombres de dominio son de todo el servidor: con
# --prefijo, otro usuario podría tener uno que empiece igual.
dominios_propios() {
    local lista d
    lista="$(virsh list --all --name 2>/dev/null || true)"
    while IFS= read -r d; do
        if [[ -n "$d" && "$d" == "${PREFIJO_DOMINIO}-"* ]] && dominio_en_silo "$d"; then
            echo "$d"
        fi
    done <<< "$lista" | sort
}

# Discos de un dominio que están en el silo (según su definición persistente)
discos_de_dominio() {   # DOMINIO
    local salida
    salida="$(virsh domblklist "$1" --inactive 2>/dev/null || true)"
    awk -v silo="$SILO_DIR/" 'NR > 2 && index($2, silo) == 1 { print $2 }' <<< "$salida"
}

estado_dominio() {   # DOMINIO
    local s
    s="$(virsh domstate "$1" 2>/dev/null || true)"
    case "$s" in
        running)    echo "en ejecución" ;;
        "shut off") echo "apagada" ;;
        paused)     echo "pausada" ;;
        "")         echo "?" ;;
        *)          echo "$s" ;;
    esac
}

# IP de una máquina en ejecución: la que reporta el agente o, si no, la del DHCP
ip_dominio() {   # DOMINIO
    local ip salida
    ip="$(obtener_ip_agente "$1")"
    if [[ -z "$ip" ]]; then
        salida="$(virsh domifaddr "$1" --source lease 2>/dev/null || true)"
        ip="$(awk '$3 == "ipv4" { split($4, a, "/"); print a[1]; exit }' <<< "$salida")"
    fi
    echo "${ip:--}"
}

# Imagen de la que es copia un fichero (solo el nombre), o nada. Usa el mapa
# de respaldos si ya está cargado; si no, pregunta solo por este fichero.
respaldo_de() {   # FICHERO
    local b
    if $RESPALDOS_CARGADOS; then
        b="${RESPALDO[$1]:-}"
    else
        b="$(leer_respaldo "$1")"
    fi
    if [[ -n "$b" ]]; then
        basename "$b"
    fi
}

# Copias del silo que dependen de un fichero: "a.qcow2, b.qcow2". Quien la
# llame muchas veces debe cargar antes el mapa (cargar_respaldos) en su propio
# proceso: dentro de $(...) no se conservaría entre llamadas.
copias_de() {   # FICHERO
    local c res=""
    while IFS= read -r c; do
        if [[ -n "$c" ]]; then res+="${res:+, }$(basename "$c")"; fi
    done < <(copias_directas "$1" | sort)
    echo "$res"
}

# Discos del silo (los qcow2 y la imagen cloud de Ubuntu, que es un .img) que
# no usa ninguna de las máquinas del usuario
discos_sin_maquina() {
    local f d usados=""
    for d in $(dominios_propios); do
        usados+="$(discos_de_dominio "$d")"$'\n'
    done
    for f in "$SILO_DIR"/*.qcow2 "$SILO_DIR/$IMAGEN_NOBLE"; do
        if [[ -f "$f" ]] && ! grep -qxF "$f" <<< "$usados"; then
            echo "$f"
        fi
    done
}

# Rellena con espacios hasta ANCHO caracteres. printf cuenta bytes, y con las
# tildes (dos bytes) las columnas se desalinean.
rellenar() {   # TEXTO ANCHO
    local n
    n="$(LC_ALL="$LOCALE_UTF8" wc -m <<< "$1")"
    n=$(( n - 1 ))
    if (( n >= $2 )); then
        printf '%s' "$1"
    else
        printf '%s%*s' "$1" $(( $2 - n )) ''
    fi
}

# "server1.qcow2 (copia de X) + N discos extra", a partir de los discos de un
# dominio (uno por línea)
descripcion_discos() {   # LISTA
    local lista="$1" n principal resp desc
    if [[ -z "$lista" ]]; then
        echo "sin discos en el silo"
        return 0
    fi
    n="$(grep -c . <<< "$lista" || true)"
    principal="${lista%%$'\n'*}"
    desc="$(basename "$principal")"
    resp="$(respaldo_de "$principal")"
    if [[ -n "$resp" ]]; then desc+=" (copia de $resp)"; fi
    if (( n > 1 )); then desc+=" + $(( n - 1 )) discos extra"; fi
    echo "$desc"
}

# Qué es un disco del silo que no usa ninguna máquina
descripcion_disco_suelto() {   # FICHERO
    local f="$1" resp dep desc=""
    if [[ "$f" == "$SILO_DIR/$IMAGEN_NOBLE" ]]; then
        echo "imagen cloud de Ubuntu 24.04: de ella salen las máquinas (no la borres)"
        return 0
    elif [[ "$f" == "$SILO_DIR/$IMAGEN_DEBIAN" ]]; then
        echo "imagen cloud de Debian 12: de ella salen las máquinas (no la borres)"
        return 0
    fi
    resp="$(respaldo_de "$f")"
    if [[ -n "$resp" ]]; then desc="copia de $resp"; fi
    dep="$(copias_de "$f")"
    if [[ -n "$dep" ]]; then desc+="${desc:+; }imagen base de: $dep"; fi
    if [[ -z "$desc" ]]; then desc="disco suelto"; fi
    echo "$desc"
}

########################################
# --listar
########################################
listar_maquinas() {
    local d estado ip f
    local -a doms=() sueltos=()

    cargar_respaldos

    while IFS= read -r d; do
        if [[ -n "$d" ]]; then doms+=( "$d" ); fi
    done < <(dominios_propios)

    if (( ${#doms[@]} == 0 )); then
        echo "No tienes máquinas (dominios que empiecen por ${PREFIJO_DOMINIO}-)."
    else
        echo "Máquinas ${PREFIJO_DOMINIO}-* (${#doms[@]}):"
        for d in "${doms[@]}"; do
            estado="$(estado_dominio "$d")"
            ip="-"
            if [[ "$estado" == "en ejecución" ]]; then
                ip="$(ip_dominio "$d")"
            fi
            printf '  %s %s %s %s\n' "$(rellenar "$d" 26)" "$(rellenar "$estado" 13)" "$(rellenar "$ip" 16)" "$(descripcion_discos "$(discos_de_dominio "$d")")"
        done
    fi

    while IFS= read -r f; do
        if [[ -n "$f" ]]; then sueltos+=( "$f" ); fi
    done < <(discos_sin_maquina)

    if (( ${#sueltos[@]} > 0 )); then
        echo
        echo "Discos del silo sin máquina:"
        for f in "${sueltos[@]}"; do
            printf '  %s %s\n' "$(rellenar "$(basename "$f")" 26)" "$(descripcion_disco_suelto "$f")"
        done
    fi
}

########################################
# --eliminar y --eliminar-todo
########################################

# Lo que se eliminaría y lo que se conserva (con el motivo)
ELIM_DOMINIOS=()
ELIM_FICHEROS=()
ELIM_DIRS=()
ELIM_CONSERVADOS=()
ELIM_SIN_NADA=()

# Rellena las listas anteriores para las máquinas indicadas por su nombre corto
planificar_eliminacion() {   # NOMBRE...
    local m vm f d habia
    local -a ficheros=()
    ELIM_DOMINIOS=(); ELIM_FICHEROS=(); ELIM_DIRS=(); ELIM_CONSERVADOS=(); ELIM_SIN_NADA=()

    for m in "$@"; do
        vm="${PREFIJO_DOMINIO}-${m}"
        habia=false
        if virsh dominfo "$vm" >/dev/null 2>&1 && ! dominio_en_silo "$vm"; then
            # Se llama como las tuyas, pero sus discos no están en tu silo
            ELIM_CONSERVADOS+=( "máquina $vm: sus discos no están en tu silo (no la ha creado este script para ti)" )
            habia=true
        elif virsh dominfo "$vm" >/dev/null 2>&1; then
            ELIM_DOMINIOS+=( "$vm" )
            habia=true
            while IFS= read -r f; do
                if [[ -n "$f" ]] && ! en_lista "$f" ${ficheros[@]+"${ficheros[@]}"}; then
                    ficheros+=( "$f" )
                fi
            done < <(discos_de_dominio "$vm")
        fi
        # También los discos que llevan su nombre aunque no estén conectados
        # (una imagen base hecha con --glusterfs, restos de otra ejecución)
        for f in "$SILO_DIR/$(disco_de "$m")" "$SILO_DIR/${PREFIJO_FICHERO}${m}"-vd?.qcow2; do
            if [[ -f "$f" ]] && ! en_lista "$f" ${ficheros[@]+"${ficheros[@]}"}; then
                ficheros+=( "$f" )
                habia=true
            fi
        done
        for d in "$SILO_DIR/cloudinit-${vm}" "$SILO_DIR/cloudinit-${vm}.dry-run"; do
            if [[ -d "$d" ]]; then
                ELIM_DIRS+=( "$d" )
                habia=true
            fi
        done
        if ! $habia; then
            ELIM_SIN_NADA+=( "$m" )
        fi
    done

    # Lo que use otra máquina, o de lo que dependan copias que se conservan,
    # se conserva
    OBJ_DOMINIOS=( ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"} )
    OBJ_FICHEROS=( ${ficheros[@]+"${ficheros[@]}"} )
    cargar_dominios_vecinos
    if (( ${#ficheros[@]} > 0 )); then
        filtrar_borrables "${ficheros[@]}"
        ELIM_FICHEROS=( ${BORRABLES[@]+"${BORRABLES[@]}"} )
        ELIM_CONSERVADOS+=( ${CONSERVADOS[@]+"${CONSERVADOS[@]}"} )
    fi
}

hay_algo_que_eliminar() {
    (( ${#ELIM_DOMINIOS[@]} + ${#ELIM_FICHEROS[@]} + ${#ELIM_DIRS[@]} > 0 ))
}

mostrar_plan_eliminacion() {
    local d f x
    if hay_algo_que_eliminar; then
        echo "Se va a eliminar:"
        for d in ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"}; do
            echo "  máquina  $d ($(estado_dominio "$d"))"
        done
        for f in ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"}; do
            echo "  disco    $f"
        done
        for x in ${ELIM_DIRS[@]+"${ELIM_DIRS[@]}"}; do
            echo "  ficheros $x/"
        done
    fi
    if (( ${#ELIM_CONSERVADOS[@]} > 0 )); then
        echo "Se conserva:"
        for x in "${ELIM_CONSERVADOS[@]}"; do
            echo "  $x"
        done
    fi
    for x in ${ELIM_SIN_NADA[@]+"${ELIM_SIN_NADA[@]}"}; do
        echo "  (de '$x' no hay nada: ni la máquina ${PREFIJO_DOMINIO}-$x ni discos con ese nombre)"
    done
}

ejecutar_eliminacion() {
    local d f x
    for d in ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"}; do
        virsh destroy "$d" >/dev/null 2>&1 || true
        if ! virsh undefine "$d" --snapshots-metadata >/dev/null 2>&1; then
            error 22 "No se ha podido eliminar la máquina '$d'. Inténtalo a mano:
  virsh destroy $d; virsh undefine $d --snapshots-metadata"
        fi
        echo "  ✔ máquina $d eliminada"
    done
    for f in ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"}; do
        rm -f "$f"
        echo "  ✔ disco $f eliminado"
    done
    for x in ${ELIM_DIRS[@]+"${ELIM_DIRS[@]}"}; do
        rm -rf "$x"
        echo "  ✔ ficheros $x eliminados"
    done
}

cancelar_eliminacion() {
    echo "Cancelado: no se ha eliminado nada."
    SALIDA_CONTROLADA=true
    exit 0
}

eliminar_maquinas() {   # NOMBRE...
    local x msg
    planificar_eliminacion "$@"

    if ! hay_algo_que_eliminar; then
        msg="No hay nada que eliminar."
        for x in ${ELIM_SIN_NADA[@]+"${ELIM_SIN_NADA[@]}"}; do
            msg+=$'\n'"  '$x': no existe la máquina ${PREFIJO_DOMINIO}-$x ni discos con ese nombre."
        done
        for x in ${ELIM_CONSERVADOS[@]+"${ELIM_CONSERVADOS[@]}"}; do
            msg+=$'\n'"  $x (se conserva)."
        done
        msg+=$'\n'"Para ver lo que tienes: $0 --listar"
        error 22 "$msg"
    fi

    mostrar_plan_eliminacion
    if $DRY_RUN; then
        echo "  (--dry-run: no se elimina nada)"
        return 0
    fi
    if ! confirmar "¿Eliminar?"; then
        cancelar_eliminacion
    fi
    ejecutar_eliminacion
}

eliminar_todo() {
    local d f
    local -a nombres=() candidatos=() sueltos=()

    while IFS= read -r d; do
        if [[ -n "$d" ]]; then nombres+=( "${d#"${PREFIJO_DOMINIO}-"}" ); fi
    done < <(dominios_propios)

    if (( ${#nombres[@]} > 0 )); then
        planificar_eliminacion "${nombres[@]}"
    else
        ELIM_DOMINIOS=(); ELIM_FICHEROS=(); ELIM_DIRS=(); ELIM_CONSERVADOS=(); ELIM_SIN_NADA=()
    fi

    # Directorios cloud-init que quedaran de máquinas que ya no existen
    for d in "$SILO_DIR"/cloudinit-"${PREFIJO_DOMINIO}"-*; do
        if [[ -d "$d" ]] && ! en_lista "$d" ${ELIM_DIRS[@]+"${ELIM_DIRS[@]}"}; then
            ELIM_DIRS+=( "$d" )
        fi
    done

    # Discos del silo que quedarían sin máquina, salvo las imágenes cloud.
    # Se comprueba contra todos los dominios del servidor y contra todas las
    # copias del silo. Los discos de las máquinas ya están decididos (si el
    # alumno dice que no a estos, sus copias se quedan y no pueden perder su
    # imagen base); aquí solo se decide qué otros se pueden ofrecer.
    for f in "$SILO_DIR"/*.qcow2; do
        if [[ ! -f "$f" ]] || imagen_protegida "$f"; then continue; fi
        if en_lista "$f" ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"}; then continue; fi
        if [[ -n "$PREFIJO_OPT" && "$(basename "$f")" != "${PREFIJO_OPT}-"* ]]; then continue; fi
        candidatos+=( "$f" )
    done
    if (( ${#candidatos[@]} > 0 )); then
        echo "Comprobando qué discos del silo usa alguna máquina…"
        OBJ_DOMINIOS=( ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"} )
        cargar_dominios_vecinos
        filtrar_borrables ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"} "${candidatos[@]}"
        for f in ${BORRABLES[@]+"${BORRABLES[@]}"}; do
            if en_lista "$f" "${candidatos[@]}"; then sueltos+=( "$f" ); fi
        done
        for f in ${CONSERVADOS[@]+"${CONSERVADOS[@]}"}; do
            ELIM_CONSERVADOS+=( "$f" )
        done
    fi

    if ! hay_algo_que_eliminar && (( ${#sueltos[@]} == 0 )); then
        error 22 "No hay nada que eliminar: ni máquinas ${PREFIJO_DOMINIO}-* ni discos sin máquina en $SILO_DIR
(aparte de las imágenes cloud $IMAGEN_NOBLE y $IMAGEN_DEBIAN, que se conservan siempre)."
    fi

    mostrar_plan_eliminacion
    if (( ${#sueltos[@]} > 0 )); then
        echo "Discos del silo sin máquina (se preguntará aparte):"
        for f in "${sueltos[@]}"; do
            echo "  disco    $f"
        done
    fi
    if $DRY_RUN; then
        echo "  (--dry-run: no se elimina nada)"
        return 0
    fi

    if hay_algo_que_eliminar; then
        if ! confirmar "¿Eliminar las máquinas con sus discos?"; then
            cancelar_eliminacion
        fi
        ejecutar_eliminacion
    fi
    if (( ${#sueltos[@]} > 0 )); then
        if confirmar "¿Eliminar también los ${#sueltos[@]} discos sin máquina?"; then
            for f in "${sueltos[@]}"; do
                rm -f "$f"
                echo "  ✔ disco $f eliminado"
            done
        else
            echo "Los discos sin máquina se conservan."
        fi
    fi
}

########################################
# Asistente (--menu): menús de whiptail que construyen la línea de comandos y
# la ejecutan. Toda la lógica sigue en el mismo sitio: el asistente solo elige
# los argumentos, enseña el comando equivalente y lo lanza en otro proceso.
########################################

# Colores de los diálogos: la paleta clásica de newt (fondo azul, ventanas
# grises). Si el usuario tiene NEWT_COLORS definida, se respeta la suya.
PALETA_ASISTENTE='
root=white,blue
roottext=white,blue
helpline=white,blue
window=black,lightgray
border=black,lightgray
shadow=black,black
title=blue,lightgray
textbox=black,lightgray
label=black,lightgray
listbox=black,lightgray
actlistbox=white,blue
sellistbox=black,cyan
actsellistbox=white,blue
checkbox=black,lightgray
actcheckbox=white,blue
entry=black,cyan
button=black,cyan
actbutton=white,blue
compactbutton=black,lightgray
'

# Ejecuta whiptail y devuelve su selección por stdout (whiptail la escribe por
# stderr). Estado: 0 aceptar, 1 cancelar, 255 Esc. Va con locale UTF-8: con
# LC_ALL=C (la del resto del script) whiptail corta los textos en las tildes.
wt() {
    local out rc=0
    out="$(NEWT_COLORS="${NEWT_COLORS:-$PALETA_ASISTENTE}" LC_ALL="$LOCALE_UTF8" \
           whiptail --title "ci-provision $VERSION" "$@" 3>&1 1>&2 2>&3)" || rc=$?
    printf '%s' "$out"
    return "$rc"
}

# Convierte la salida de un --checklist ("a" "b") en etiquetas sueltas
etiquetas() {
    tr -d '"' <<< "$1"
}

# IPs libres de la red del usuario, para mostrarlas. Va en una subshell: si la
# red no se encuentra, el asistente sigue (ya lo dirá el script al ejecutar).
ips_libres_texto() {
    ( detectar_red >/dev/null 2>&1 && load_network_info >/dev/null 2>&1 && free_ip_blocks ) 2>/dev/null || true
}

# La IP número N de la red del usuario (la .2 de SERVER1), o nada
ip_de_la_red() {   # N
    ( detectar_red >/dev/null 2>&1 && load_network_info >/dev/null 2>&1 && int_to_ip $(( $(red_neti) + $1 )) ) 2>/dev/null || true
}

salir_asistente() {
    echo "Sin cambios."
    SALIDA_CONTROLADA=true
    exit 0
}

asistente() {
    local sel
    while true; do
        sel="$(wt --notags --menu $'¿Qué quieres hacer?\n(muévete con las flechas y elige con Enter)' 20 78 8 \
            basica   "Crear una máquina básica (boletín 1; Debian 12 propuesta)" \
            extra    "Crear una máquina con IP .2 y 6 discos extra (boletín 2, epígrafe 2.1)" \
            cluster  "Crear la infraestructura GlusterFS (boletín 2, epígrafe 2.4)" \
            base     "Crear solo la imagen base GlusterFS" \
            listar   "Mostrar mis máquinas virtuales" \
            eliminar "Eliminar una máquina virtual (y su almacenamiento)" \
            todo     "Eliminar todas mis máquinas virtuales (y su almacenamiento)" \
            salir    "Salir")" || salir_asistente
        case "$sel" in
            basica)   asistente_maquina basica ;;
            extra)    asistente_maquina extra ;;
            cluster)  asistente_cluster ;;
            base)     asistente_base ;;
            listar)   asistente_listar ;;
            eliminar) asistente_eliminar ;;
            todo)     ejecutar_asistente --eliminar-todo ;;
            *)        salir_asistente ;;
        esac
    done
}

# Opciones marcadas en un checklist → argumentos (la contraseña se pide aparte).
# Deja el resultado en OPCIONES_ARGS; devuelve 1 si se cancela. La contraseña
# no va en los argumentos (cualquier usuario del servidor la vería con 'ps'):
# se guarda en PASS_ASISTENTE y la orden lleva '--ssh-pass -'.
OPCIONES_ARGS=()
PASS_ASISTENTE=""
opciones_a_argumentos() {   # SALIDA_DEL_CHECKLIST
    local o pass
    OPCIONES_ARGS=()
    PASS_ASISTENTE=""
    for o in $(etiquetas "$1"); do
        if [[ "$o" == ssh-pass ]]; then
            pass="$(wt --passwordbox $'Contraseña para administrador\n(solo letras sin tilde, números y signos básicos):' 10 70)" || return 1
            if [[ -z "$pass" ]]; then return 1; fi
            PASS_ASISTENTE="$pass"
            OPCIONES_ARGS+=( --ssh-pass - )
        elif [[ "$o" == discos-crea-entorno ]]; then
            OPCIONES_ARGS+=( --discos-nodo "${#UNIDADES_POSIBLES_NODO[@]}" )
        else
            OPCIONES_ARGS+=( "--$o" )
        fi
    done
    return 0
}

# on/off según si OPCION es la elegida (para los --radiolist)
marca() {   # OPCION ELEGIDA
    if [[ "$1" == "$2" ]]; then echo on; else echo off; fi
}

# Imagen de una máquina suelta. Deja --imagen en IMAGEN_ARGS (nada si es la
# de por defecto); devuelve 1 si se cancela.
IMAGEN_ARGS=()
elegir_imagen_maquina() {   # PRESELECCIONADA
    local img
    IMAGEN_ARGS=()
    img="$(wt --notags --radiolist $'Sistema de la máquina (marca con la barra espaciadora):' 11 76 2 \
        noble    "Ubuntu 24.04 (boletín 2)" "$(marca noble "$1")" \
        debian12 "Debian 12 (boletín 1)"    "$(marca debian12 "$1")")" || return 1
    if [[ -n "$img" && "$img" != "$IMAGEN_DEFECTO" ]]; then
        IMAGEN_ARGS=( --imagen "$img" )
    fi
}

# De qué imagen sale la base GlusterFS (mismo convenio que la anterior)
elegir_imagen_gluster() {
    local img
    IMAGEN_ARGS=()
    img="$(wt --notags --radiolist $'¿De qué imagen sale la base GlusterFS?\n(marca con la barra espaciadora)' 13 78 3 \
        noble       "Imagen cloud de Ubuntu 24.04, la misma que SERVER1 (recomendada)" on \
        ubuntu-base "ubuntu-base.qcow2 del boletín 1, como la construcción manual" off \
        debian12    "Imagen cloud de Debian 12" off)" || return 1
    if [[ -n "$img" && "$img" != "$IMAGEN_DEFECTO_GLUSTER" ]]; then
        IMAGEN_ARGS=( --imagen "$img" )
    fi
}

# Nombre corto válido para el asistente: si no lo es, lo dice y devuelve 1
# (un nombre que empezara por '-' se tomaría además por una opción)
nombre_valido_asistente() {   # NOMBRE
    if [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] && (( ${#1} <= 63 )); then
        return 0
    fi
    wt --msgbox "El nombre '$1' no es válido: solo letras, números y guiones, empezando
por letra o número (p.ej. server1)." 9 72 || true
    return 1
}

asistente_maquina() {   # basica | extra (IP .2 sugerida y discos extra marcados)
    local modo="$1" nombre ip sugerida libres texto marcado sel
    local -a args=()

    nombre="$(wt --inputbox $'Nombre corto de la máquina (letras, números y guiones).\nEl dominio será '"${PREFIJO_DOMINIO}"$'-NOMBRE y el disco NOMBRE.qcow2.' 11 70 server1)" || return 0
    if [[ -z "$nombre" ]]; then return 0; fi
    nombre_valido_asistente "$nombre" || return 0

    sugerida=""
    if [[ "$modo" == extra ]]; then
        sugerida="$(ip_de_la_red 2)"
    fi
    libres="$(ips_libres_texto)"
    texto="IP fija dentro de tu red virtual. Déjala vacía para usar DHCP."
    if [[ -n "$libres" ]]; then
        texto+=$'\nIPs libres de tu red:\n'"$libres"
    fi
    ip="$(wt --inputbox "$texto" 16 70 "$sugerida")" || return 0

    # El boletín 1 usa Debian 12; el 2, Ubuntu 24.04
    if [[ "$modo" == basica ]]; then
        elegir_imagen_maquina debian12 || return 0
    else
        elegir_imagen_maquina noble || return 0
    fi

    marcado=off
    if [[ "$modo" == extra ]]; then marcado=on; fi
    sel="$(wt --checklist $'Opciones (marca con la barra espaciadora):' 16 76 5 \
        extra-disks    "Seis discos extra vdb..vdg de ${TAM_DISCO_EXTRA}" "$marcado" \
        ssh-pass       "Contraseña para administrador y SSH por contraseña" off \
        no-root        "No habilitar al usuario root" off \
        no-virt-viewer "Sin consola gráfica (virt-viewer)" off \
        limpiar        "Eliminar antes lo que ya exista con esos nombres" off)" || return 0
    opciones_a_argumentos "$sel" || return 0

    args=( ${IMAGEN_ARGS[@]+"${IMAGEN_ARGS[@]}"} ${OPCIONES_ARGS[@]+"${OPCIONES_ARGS[@]}"} "$nombre" )
    if [[ -n "$ip" ]]; then args+=( "$ip" ); fi
    ejecutar_asistente "${args[@]}"
}

asistente_cluster() {
    local base sel usar_base=false
    local -a args=( --gluster-cluster )

    base="$(disco_base_cluster)"
    if [[ -f "$base" ]]; then
        if wt --yesno "Ya tienes $(basename "$base") en el silo."$'\n¿Quieres usarla como imagen base, sin volver a construirla?' 10 70; then
            args+=( --base "$(basename "$base")" )
            usar_base=true
        fi
    fi
    if ! $usar_base; then
        elegir_imagen_gluster || return 0
        args+=( ${IMAGEN_ARGS[@]+"${IMAGEN_ARGS[@]}"} )
    fi

    sel="$(wt --checklist $'Opciones (marca con la barra espaciadora):' 15 78 5 \
        limpiar             "Eliminar antes los nodos y la imagen base si ya existen" off \
        discos-crea-entorno "${#UNIDADES_POSIBLES_NODO[@]} discos por nodo (vdb..vdh), como crea-entorno.sh" off \
        ssh-pass            "Contraseña para administrador y SSH por contraseña" off \
        no-root             "No habilitar al usuario root" off \
        no-virt-viewer      "Sin consola gráfica (virt-viewer)" off)" || return 0
    opciones_a_argumentos "$sel" || return 0

    args+=( ${OPCIONES_ARGS[@]+"${OPCIONES_ARGS[@]}"} )
    ejecutar_asistente "${args[@]}"
}

asistente_base() {
    local nombre
    local -a args=( --glusterfs )

    nombre="$(wt --inputbox $'Nombre de la imagen base.\nQuedará NOMBRE.qcow2 en el silo, sin máquina, lista para hacer copias.' 11 70 "$CLUSTER_BASE")" || return 0
    if [[ -z "$nombre" ]]; then return 0; fi
    nombre_valido_asistente "$nombre" || return 0
    elegir_imagen_gluster || return 0
    args+=( ${IMAGEN_ARGS[@]+"${IMAGEN_ARGS[@]}"} )
    if wt --defaultno --yesno $'Si ya existe una máquina o un disco con ese nombre,\n¿eliminarlos antes (--limpiar)?' 9 70; then
        args+=( --limpiar )
    fi
    args+=( "$nombre" )
    ejecutar_asistente "${args[@]}"
}

# Lista de máquinas y discos sueltos; al elegir uno se abre su ficha
asistente_listar() {
    local d f sel estado ip lista n tipo
    local -a items=()

    cargar_respaldos

    while IFS= read -r d; do
        if [[ -z "$d" ]]; then continue; fi
        estado="$(estado_dominio "$d")"
        ip="-"
        if [[ "$estado" == "en ejecución" ]]; then ip="$(ip_dominio "$d")"; fi
        lista="$(discos_de_dominio "$d")"
        n=0
        if [[ -n "$lista" ]]; then n="$(grep -c . <<< "$lista" || true)"; fi
        items+=( "m:$d" "$(rellenar "${d#"${PREFIJO_DOMINIO}-"}" 14) $(rellenar "$estado" 12) $(rellenar "$ip" 15) $n disco(s)" )
    done < <(dominios_propios)

    while IFS= read -r f; do
        if [[ -z "$f" ]]; then continue; fi
        tipo="sin máquina"
        if imagen_protegida "$f"; then tipo="imagen cloud"; fi
        items+=( "d:$f" "$(rellenar "$(basename "$f")" 14) $(rellenar "$tipo" 12) $(descripcion_disco_suelto "$f")" )
    done < <(discos_sin_maquina)

    if (( ${#items[@]} == 0 )); then
        wt --msgbox "No tienes máquinas ni discos en el silo." 8 60 || true
        return 0
    fi

    while true; do
        sel="$(wt --notags --menu $'Mis máquinas virtuales y los discos del silo.\nElige una entrada para ver su ficha; Cancelar para volver.' 22 78 12 "${items[@]}")" || return 0
        case "$sel" in
            m:*) ficha_maquina "${sel#m:}" ;;
            d:*) ficha_disco "${sel#d:}" ;;
        esac
    done
}

ficha_maquina() {   # DOMINIO
    local d="$1" estado ip lista f resp texto n=4
    estado="$(estado_dominio "$d")"
    ip="-"
    if [[ "$estado" == "en ejecución" ]]; then ip="$(ip_dominio "$d")"; fi
    texto="Máquina : $d   (hostname: ${d#"${PREFIJO_DOMINIO}-"})"$'\n'"Estado  : $estado"$'\n'"IP      : $ip"$'\n'"Discos  :"
    lista="$(discos_de_dominio "$d")"
    if [[ -z "$lista" ]]; then
        texto+=" (ninguno en el silo)"
    fi
    while IFS= read -r f; do
        if [[ -n "$f" ]]; then
            resp="$(respaldo_de "$f")"
            texto+=$'\n'"          $(basename "$f")${resp:+ (copia de $resp)}"
            n=$(( n + 1 ))
        fi
    done <<< "$lista"
    if [[ "$ip" != "-" ]]; then
        texto+=$'\n'"Acceso  : ssh administrador@$ip"
        n=$(( n + 1 ))
    fi
    texto+=$'\n'"Consola : virsh console $d"
    texto+=$'\n\n'"Para eliminarla con sus discos: $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--eliminar ${d#"${PREFIJO_DOMINIO}-"}"
    n=$(( n + 3 ))
    wt --msgbox "$texto" $(( n + 6 )) 78 || true
}

ficha_disco() {   # FICHERO
    local f="$1" vs texto
    vs="$(tam_virtual "$f")"
    texto="Disco   : $(basename "$f")"$'\n'"Ruta    : $f"
    if [[ "$vs" =~ ^[0-9]+$ ]]; then
        texto+=$'\n'"Tamaño  : $(bytes_a_gib "$vs") GiB (virtual)"
    fi
    texto+=$'\n'"Qué es  : $(descripcion_disco_suelto "$f")"
    wt --msgbox "$texto" 11 78 || true
}

asistente_eliminar() {
    local d sel o
    local -a items=() args=( --eliminar )

    while IFS= read -r d; do
        if [[ -n "$d" ]]; then
            items+=( "${d#"${PREFIJO_DOMINIO}-"}" "$(estado_dominio "$d")" off )
        fi
    done < <(dominios_propios)

    if (( ${#items[@]} == 0 )); then
        wt --msgbox "No tienes máquinas (dominios ${PREFIJO_DOMINIO}-*)."$'\nLos discos sueltos del silo se ven en "Mostrar mis máquinas virtuales"\ny se eliminan con "Eliminar todas mis máquinas virtuales".' 11 76 || true
        return 0
    fi

    sel="$(wt --checklist $'Marca las máquinas a eliminar (con sus discos y sus ficheros cloud-init):' 18 72 8 "${items[@]}")" || return 0
    for o in $(etiquetas "$sel"); do
        args+=( "$o" )
    done
    if (( ${#args[@]} == 1 )); then return 0; fi
    ejecutar_asistente "${args[@]}"
}

# Enseña el comando equivalente, pide confirmación y lo ejecuta en un proceso
# aparte (este mismo script con esos argumentos). Con --directo no pregunta.
ejecutar_asistente() {   # [--directo] ARGUMENTO...
    local directo=false mostrar a prev="" rc=0 pausa
    if [[ "${1:-}" == "--directo" ]]; then
        directo=true
        shift
    fi
    if [[ -n "$PREFIJO_OPT" ]]; then
        set -- --prefijo "$PREFIJO_OPT" "$@"
    fi
    # Con --menu --dry-run, todo lo que se lance es también una simulación; con
    # --menu --si, sin preguntas
    if $SI; then
        set -- --si "$@"
    fi
    if $DRY_RUN; then
        set -- --dry-run "$@"
    fi

    mostrar="$0"
    for a in "$@"; do
        if [[ "$prev" == "--ssh-pass" ]]; then
            mostrar+=" ••••••"
        else
            mostrar+=" $a"
        fi
        prev="$a"
    done

    if ! $directo; then
        if ! wt --yesno $'Se va a ejecutar:\n\n  '"$mostrar"$'\n\n¿Adelante?' 12 76; then
            return 0
        fi
    fi

    clear 2>/dev/null || true
    echo "→ $mostrar"
    echo
    # Ctrl+C lo atiende el proceso hijo, que deshace lo suyo; aquí se ignora
    trap '' INT
    if [[ -n "$PASS_ASISTENTE" ]]; then
        CI_PROVISION_SSH_PASS="$PASS_ASISTENTE" bash "$0" "$@" || rc=$?
    else
        bash "$0" "$@" || rc=$?
    fi
    PASS_ASISTENTE=""
    trap 'INTERRUMPIDO=true; exit 130' INT
    echo
    if (( rc != 0 )); then
        echo "(el comando ha terminado con el código $rc)"
    fi
    read -r -p "Pulsa Enter para volver al menú… " pausa || true
}


# Los diálogos de whiptail necesitan una locale UTF-8 (si no, cortan los
# textos en la primera tilde): la del usuario si lo es, o C.UTF-8
LOCALE_UTF8="${LC_ALL:-${LANG:-}}"
case "${LOCALE_UTF8,,}" in
    *utf-8*|*utf8*) ;;
    *) LOCALE_UTF8="C.UTF-8" ;;
esac

# Salidas de las herramientas en formato neutro, independiente del idioma
# configurado en el servidor.
export LC_ALL=C

# Las máquinas de la asignatura son las de libvirt del sistema. Sin una sesión
# de login (p.ej. 'ssh servidor ./ci-provision.sh ...'), o con una variable
# LIBVIRT_DEFAULT_URI heredada, virsh podría conectarse a qemu:///session, no
# ver ninguna máquina y dar todos los discos por sueltos. Por eso se fija
# siempre; solo para desarrollo se puede cambiar con CI_PROVISION_LIBVIRT_URI.
export LIBVIRT_DEFAULT_URI="${CI_PROVISION_LIBVIRT_URI:-qemu:///system}"

VERSION="3.0.0"

########################################
# Configuración general
########################################
SILO_DIR="$HOME/imagenesMV"
# La clave del manual. Se puede cambiar desde el entorno: la batería de pruebas
# del servidor pone aquí su clave de usar y tirar (ver DESARROLLO.md)
PUBKEY_PATH="${CI_PROVISION_PUBKEY:-$HOME/.ssh/id_rsa.pub}"

# Imágenes de partida (--imagen). Las dos imágenes cloud se descargan al silo
# si faltan, con el nombre y desde la URL que dan los boletines.
#   noble        Ubuntu 24.04: SERVER1 y nodos GlusterFS del boletín 2
#   debian12     Debian 12: SERVER1 del boletín 1
#   ubuntu-base  la imagen del boletín 1 que dejan los profesores en
#                /home/ssoo-shared; solo para la base GlusterFS, si se quiere
#                hacer como la construcción manual del boletín (epígrafe 2.4),
#                sobre una copia suya en el silo
IMAGEN_NOBLE="noble-server-cloudimg-amd64.img"
URL_NOBLE="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGEN_DEBIAN="debian12.qcow2"
URL_DEBIAN="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
# Sumas publicadas junto a cada imagen, para comprobar la descarga
SUMAS_NOBLE="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
SUMAS_DEBIAN="https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
# Directorio compartido de los profesores: ubuntu-base.qcow2 y, si están ahí,
# copias de las imágenes cloud (se copian en vez de descargarlas). Se puede
# cambiar desde el entorno; los tests lo usan para no depender del servidor.
DIR_COMPARTIDO="${CI_PROVISION_DIR_COMPARTIDO:-/home/ssoo-shared}"
UBUNTU_BASE_COMPARTIDA="$DIR_COMPARTIDO/ubuntu-base.qcow2"
IMAGEN_DEFECTO="noble"                # máquinas sueltas
IMAGEN_DEFECTO_GLUSTER="noble"        # --glusterfs y --gluster-cluster

# Los fija elegir_imagen según --imagen (o comprobar_imagen_base, con --base)
IMAGEN=""          # noble | debian12 | ubuntu-base
BASE_IMG=""        # fichero del que sale el disco principal
BASE_IMG_URL=""    # de dónde se descarga si falta (vacío: no se descarga)
BASE_IMG_SUMAS=""  # fichero de sumas publicado junto a la imagen
OS_VARIANT=""      # variante de SO que se declara a virt-install

# Usuario del servidor: de él salen los nombres de los dominios y el de la red
USUARIO="$(id -un)"

# Contraseña de consola de 'root' (la misma que usa el manual de laboratorio).
# 'administrador' no tiene contraseña: por SSH se entra con clave; solo con
# --ssh-pass se le da una, y entonces la elige el alumno.
PASS_CONSOLA="s1st3mas"

# Discos
TAM_DISCO_DEFECTO="40G"
TAM_DISCO_EXTRA="40G"
UNIDADES_EXTRA=(vdb vdc vdd vde vdf vdg)          # --extra-disks (boletín 2, epígrafe 2.1)

# Clúster GlusterFS (boletín 2, epígrafe 2.4)
CLUSTER_BASE="gluster-base"
CLUSTER_NODOS=(server1 server2 server3 server4)
CLUSTER_IP_INICIAL=10                             # server1 = .10, server2 = .11, ... (--ip-inicial)
CLUSTER_RAM_MB=1024                               # recursos por nodo: los mismos que
CLUSTER_VCPUS=1                                   # usa crea-entorno.sh
CLUSTER_MONTAJES=(/gluster1 /gluster2 /gluster3)  # vdb, vdc y vdd, formateados en xfs
OPCIONES_FSTAB_CLUSTER="auto,async,nofail"        # las mismas líneas de fstab que crea-entorno.sh
# Discos extra por nodo (--discos-nodo): los tres del boletín por defecto;
# crea-entorno.sh conecta siete (vdb..vdh), de los que solo formatea tres
UNIDADES_POSIBLES_NODO=(vdb vdc vdd vde vdf vdg vdh)
DISCOS_NODO_DEFECTO=3
UNIDADES_CLUSTER=()                               # las fija validar_opciones

# Recursos por defecto de una máquina suelta
RAM_MB_DEFECTO=2048
VCPUS_DEFECTO=2
RAM_MB_MINIMO=512

# Espera a que cloud-init termine (segundos). Se pueden ajustar desde el
# entorno (con nombres propios, para no recoger por accidente variables del
# alumno); los tests lo usan para no esperar de verdad. Se validan en
# validar_opciones.
WAIT_TIMEOUT="${CI_PROVISION_WAIT_TIMEOUT:-300}"          # máximo antes de rendirse
POLL_SECS="${CI_PROVISION_POLL_SECS:-3}"                  # cada cuánto se consulta
GRACE_SECS="${CI_PROVISION_GRACE_SECS:-5}"                # margen si no se puede consultar cloud-init
SHUTDOWN_TIMEOUT="${CI_PROVISION_SHUTDOWN_TIMEOUT:-120}"  # apagado limpio de la base del clúster

########################################
# Opciones (valores por defecto)
########################################
EXTRA_DISKS=false
GLUSTERFS=false
CLUSTER=false
LIMPIAR=false
DRY_RUN=false
NO_WAIT=false
LISTAR=false        # --listar
ELIMINAR=false      # --eliminar MAQUINA...
ELIMINAR_TODO=false # --eliminar-todo
MENU=false          # --menu: asistente con whiptail
SI=false            # --si: da por contestadas que sí las confirmaciones
NOMBRES=()          # --eliminar: máquinas a eliminar

RED_OPT=""
DISCO_OPT=""
TAM_DISCO="$TAM_DISCO_DEFECTO"
TAM_EXPLICITO=false  # --tam: si no se indica, el disco crece hasta el tamaño de la imagen
IMAGEN_OPT=""        # --imagen
DISCOS_NODO_OPT=""   # --discos-nodo
IP_INICIAL_OPT=""    # --ip-inicial
RAM_OPT=""
VCPUS_OPT=""
SSH_PASS=""
NO_ROOT=false      # --no-root: root sin contraseña, como en las máquinas hechas a mano
NO_GRAFICOS=false  # --no-virt-viewer: sin consola gráfica
BASE_OPT=""        # --base: imagen del silo de la que hacer la copia COW
PREFIJO_OPT=""     # --prefijo: sustituye al usuario en los nombres de lo que se crea

MAQUINA=""
IP=""

# Derivados
PREFIJO_DOMINIO=""   # delante de MAQUINA en el dominio: el usuario o --prefijo
PREFIJO_FICHERO=""   # delante de MAQUINA en los ficheros: nada o "PREFIJO-"
VM_NAME=""
HOST_NAME=""
DISCO_MAIN=""
NET_NAME=""
RAM_MB=""
VCPUS=""

# Ficheros cloud-init de la máquina que se está generando
WORKDIR=""
USER_DATA=""
META_DATA=""
NETWORK_DATA=""

# Comando virt-install, como array para poder ejecutarlo y mostrarlo tal cual
VIRT_INSTALL_CMD=()

# En --dry-run: la imagen base no está y habría que descargarla
BASE_IMG_FALTA=false

########################################
# Registro de lo creado, para poder deshacerlo si algo falla a medias
########################################
DOMINIOS_CREADOS=()
DISCOS_CREADOS=()
DIRS_CREADOS=()          # directorios cloud-init nuevos de esta ejecución
BASE_CONSERVADA=""       # imagen base GlusterFS ya terminada: no se deshace aunque falle lo siguiente
CREACION_COMPLETA=false   # true cuando ya solo queda esperar: a partir de ahí no se deshace nada
SALIDA_CONTROLADA=false   # true si se sale por un error propio (validaciones)
INTERRUMPIDO=false        # true si el usuario pulsa Ctrl-C

########################################
# Carga de librerías
########################################

########################################
# Función de error con código
########################################
error() {
    local code="$1"
    shift
    SALIDA_CONTROLADA=true
    echo "ERROR [$code] $*" >&2
    exit "$code"
}

########################################
# Deshacer lo creado si la ejecución se interrumpe a medias
#
# Solo se eliminan los elementos creados por ESTA ejecución: los dominios y
# los discos que el propio script acaba de crear. Nada preexistente se toca.
########################################
revertir_cambios() {
    if (( ${#DOMINIOS_CREADOS[@]} == 0 && ${#DISCOS_CREADOS[@]} == 0 )); then
        return 0
    fi

    echo >&2
    echo "Deshaciendo lo que se había creado en esta ejecución:" >&2

    local dominio disco
    for dominio in ${DOMINIOS_CREADOS[@]+"${DOMINIOS_CREADOS[@]}"}; do
        # Se registra antes de lanzar virt-install: puede que no llegara a definirlo
        virsh dominfo "$dominio" >/dev/null 2>&1 || continue
        virsh destroy  "$dominio" >/dev/null 2>&1 || true
        if virsh undefine "$dominio" --snapshots-metadata >/dev/null 2>&1; then
            echo "  - dominio '$dominio' eliminado" >&2
        else
            echo "  - dominio '$dominio': no se ha podido eliminar. Hazlo tú: virsh undefine $dominio --snapshots-metadata" >&2
        fi
    done

    for disco in ${DISCOS_CREADOS[@]+"${DISCOS_CREADOS[@]}"}; do
        [[ -e "$disco" ]] || continue
        if rm -f "$disco"; then
            echo "  - disco '$disco' eliminado" >&2
        fi
    done
    local dir
    for dir in ${DIRS_CREADOS[@]+"${DIRS_CREADOS[@]}"}; do
        [[ -d "$dir" ]] && rm -rf "$dir" && echo "  - ficheros cloud-init '$dir' eliminados" >&2
    done
    if [[ -n "$BASE_CONSERVADA" && -e "$BASE_CONSERVADA" ]]; then
        echo "  - la imagen base $(basename "$BASE_CONSERVADA") ya estaba terminada y se conserva:" >&2
        echo "    puedes reutilizarla con --base $(basename "$BASE_CONSERVADA")" >&2
    fi

    echo "  (nada que existiera antes de ejecutar el script se ha tocado)" >&2
}

al_salir() {
    local code=$?
    # Un fallo aquí dentro (p.ej. un echo con el terminal ya cerrado) no debe
    # impedir que se deshaga lo creado
    set +e

    if (( code == 0 )); then
        return 0
    fi

    if $INTERRUMPIDO; then
        echo >&2
        echo "Interrumpido por el usuario." >&2
    elif ! $SALIDA_CONTROLADA; then
        echo >&2
        echo "ERROR: el script ha terminado de forma inesperada (código $code)." >&2
        echo "       Si el problema persiste, avisa a tu profesor indicando el comando usado." >&2
    fi

    if $CREACION_COMPLETA; then
        echo "Lo creado se conserva: no se deshace nada. Comprueba su estado con:" >&2
        echo "  virsh list --all" >&2
        if $INTERRUMPIDO; then
            echo "OJO: no se ha expulsado el medio de cloud-init. Antes de tomar instantáneas," >&2
            echo "     apaga la máquina (virsh shutdown) o espera a que termine y expúlsalo." >&2
        fi
    else
        revertir_cambios
    fi
}

trap al_salir EXIT
trap 'INTERRUMPIDO=true; exit 130' INT TERM HUP

########################################
# Función de ayuda
########################################
print_help() {
    cat <<EOF
ci-provision.sh $VERSION

Uso:
  $0 [opciones] MAQUINA [IP]
  $0 [opciones] --gluster-cluster
  $0 --listar
  $0 --eliminar MAQUINA [MAQUINA...]
  $0 --eliminar-todo
  $0 --menu                  (asistente con menús; también al ejecutarlo sin argumentos)

Crea una máquina virtual con cloud-init en tu silo ($SILO_DIR).
De MAQUINA salen el nombre del dominio (${USUARIO}-MAQUINA), el nombre de
host (MAQUINA) y el disco (MAQUINA.qcow2), que el script crea como copia COW
de la imagen cloud de Ubuntu 24.04 ($IMAGEN_NOBLE; si no está en
el silo, la descarga). La red virtual se busca por tu nombre de usuario.

Parámetros:
  MAQUINA              Nombre corto de la máquina (server1, server2, gluster-base, ...)
  IP                   (Opcional) IP fija dentro de tu red virtual. Sin ella, DHCP.

Opciones:
  --extra-disks        Crea y conecta 6 discos extra de ${TAM_DISCO_EXTRA} (vdb..vdg)
  --imagen IMAGEN      Imagen de partida:
                         noble        Ubuntu 24.04, $IMAGEN_NOBLE (por defecto,
                                      también para la base GlusterFS)
                         debian12     Debian 12, $IMAGEN_DEBIAN (la del boletín 1)
                         ubuntu-base  la imagen del boletín 1 de $DIR_COMPARTIDO;
                                      solo para la base GlusterFS, como en la construcción
                                      manual del boletín 2
                       Las dos primeras se descargan al silo si no están.
                       Con --base, indica de qué imagen sale ese fichero si el script
                       no sabe deducirlo (te lo avisa).
  --glusterfs          Construye una imagen base GlusterFS: crea la máquina con
                       glusterfs-server instalado, glusterd habilitado y el
                       machine-id vacío y, al terminar, la apaga y elimina el
                       dominio. Queda solo MAQUINA.qcow2, listo para hacer copias.
                       Con ubuntu-base, MAQUINA.qcow2 es una copia completa de esa
                       imagen (no depende del fichero de $DIR_COMPARTIDO).
  --gluster-cluster    Construye la infraestructura completa del epígrafe 2.4 del
                       boletín 2: la base anterior (${CLUSTER_BASE}.qcow2) y ${#CLUSTER_NODOS[@]} nodos
                       (${CLUSTER_NODOS[*]}) con IP fija, /etc/hosts, ${DISCOS_NODO_DEFECTO} discos
                       cada uno y ${CLUSTER_MONTAJES[*]} en xfs. No lleva MAQUINA.
  --discos-nodo N      Discos extra por nodo del clúster, de ${DISCOS_NODO_DEFECTO} a ${#UNIDADES_POSIBLES_NODO[@]} (por defecto
                       ${DISCOS_NODO_DEFECTO}, como el boletín; con ${#UNIDADES_POSIBLES_NODO[@]}, como crea-entorno.sh). Solo los
                       tres primeros se formatean y se montan.
  --ip-inicial N       Último número de la IP del primer nodo del clúster (por defecto
                       ${CLUSTER_IP_INICIAL}: .${CLUSTER_IP_INICIAL} a .$(( CLUSTER_IP_INICIAL + ${#CLUSTER_NODOS[@]} - 1 ))). Útil si el DHCP de tu red las ocupa.
  --base FICHERO       Imagen del silo de la que hacer la copia COW (p.ej. una
                       imagen base GlusterFS que ya tengas). Con --gluster-cluster
                       se omite la fase 1 y los nodos parten de ella.
  --no-root            No habilita al usuario root (queda sin contraseña, como en
                       las máquinas que se crean a mano)
  --no-virt-viewer     No habilita la consola gráfica (virt-viewer). La consola de
                       texto (virsh console) sigue funcionando.
  --limpiar            Si ya existen los dominios o discos que el script va a
                       crear, los elimina antes (solo esos; nada más), previa
                       confirmación
  --si                 Da por contestadas que sí las confirmaciones de --limpiar,
                       --eliminar y --eliminar-todo. Sin terminal (p.ej. desde otro
                       script) son obligatorias: sin --si no se elimina nada.
  --red NOMBRE         Red virtual a usar (por defecto se busca ${USUARIO}-red)
  --prefijo PREFIJO    Sustituye a tu usuario en los nombres: dominio PREFIJO-MAQUINA
                       y, en ese caso, también los discos (PREFIJO-MAQUINA.qcow2)
  --disco NOMBRE       Nombre del disco principal (por defecto MAQUINA.qcow2)
  --tam TAMAÑO         Tamaño del disco principal (por defecto ${TAM_DISCO_DEFECTO}, o el de la
                       imagen de partida si es mayor: ubuntu-base tiene 64G)
  --ram MB             Memoria (por defecto ${RAM_MB_DEFECTO}; en el clúster, ${CLUSTER_RAM_MB} por nodo)
  --vcpus N            vCPUs (por defecto ${VCPUS_DEFECTO}; en el clúster, ${CLUSTER_VCPUS} por nodo)
  --ssh-pass CONTRASEÑA
                       Da esa contraseña a 'administrador' y permite entrar por SSH
                       escribiéndola (sin --ssh-pass, por SSH solo se entra con tu
                       clave pública). Solo caracteres ASCII. Mejor '--ssh-pass -':
                       te la pide por teclado y no la ven los demás usuarios del
                       servidor ni queda en el historial.
  --dry-run            Comprueba los datos y muestra lo que se haría, SIN crear nada
  --no-wait            No esperar a que cloud-init termine de configurar la máquina
                       (en el clúster solo afecta a los nodos: la base se espera siempre)
  -h, --help           Muestra esta ayuda

Ver y eliminar lo que ya tienes:
  --listar             Muestra tus máquinas (estado, IP, discos) y los discos del silo
                       que no usa ninguna. No lleva MAQUINA.
  --eliminar MAQUINA...
                       Elimina esas máquinas con sus discos y sus ficheros cloud-init,
                       previa confirmación. Nunca borra un disco que use otra máquina
                       ni una imagen de la que dependan otras copias.
  --eliminar-todo      Elimina todas tus máquinas (las ${USUARIO}-*) con sus discos y
                       ofrece borrar los discos del silo que queden sin máquina.
  --version            Muestra la versión del script
  --menu               Asistente con menús para hacer todo lo anterior sin tener que
                       recordar las opciones. Es lo que se abre al ejecutar el script
                       sin argumentos desde una terminal.

En todas las máquinas:
  - Usuario 'administrador' con tu clave pública ($PUBKEY_PATH) y
    sudo sin contraseña. Sin contraseña propia salvo que uses --ssh-pass.
    En las que salen de ubuntu-base (la base GlusterFS y sus nodos) se queda
    como en esa imagen: con la contraseña del boletín 1, que sudo pide; el
    script solo le añade tu clave pública.
  - Usuario 'root' con contraseña '${PASS_CONSOLA}', solo para la consola
    (virsh console o virt-viewer); por SSH no puede entrar. Con --no-root,
    sin contraseña.
  - Consola gráfica activa (virt-viewer), salvo con --no-virt-viewer.

Ejemplos (XXX es el tercer número de tu red virtual; lo ves en el resumen de --dry-run):
  $0 server1                                    # Ubuntu 24.04 con DHCP
  $0 --imagen debian12 server1 192.168.XXX.2    # SERVER1 del boletín 1 (Debian 12)
  $0 --extra-disks server1 192.168.XXX.2        # SERVER1 del boletín 2, epígrafe 2.1
  $0 --gluster-cluster                          # infraestructura del boletín 2, epígrafe 2.4
  $0 --glusterfs gluster-base                   # solo la imagen base GlusterFS
  $0 --gluster-cluster --base gluster-base.qcow2   # la infraestructura a partir de esa imagen
  $0 --dry-run --extra-disks server1 192.168.XXX.2 # solo comprobar
EOF
}

########################################
# Parseo de opciones
########################################
ARGS=()   # parámetros posicionales, los rellena parse_args
parse_args() {
    ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --extra-disks)     EXTRA_DISKS=true; shift ;;
            --glusterfs)       GLUSTERFS=true;   shift ;;
            --gluster-cluster) CLUSTER=true;     shift ;;
            --limpiar)         LIMPIAR=true;     shift ;;
            --dry-run)         DRY_RUN=true;     shift ;;
            --no-wait)         NO_WAIT=true;     shift ;;
            --no-root)         NO_ROOT=true;     shift ;;
            --no-virt-viewer)  NO_GRAFICOS=true; shift ;;
            --si)              SI=true;          shift ;;
            --listar)          LISTAR=true;        shift ;;
            --eliminar)        ELIMINAR=true;      shift ;;
            --eliminar-todo)   ELIMINAR_TODO=true; shift ;;
            --menu)            MENU=true;          shift ;;
            --version)
                echo "ci-provision.sh $VERSION"
                exit 0
                ;;
            --red|--disco|--base|--tam|--ram|--vcpus|--ssh-pass|--prefijo|--imagen|--discos-nodo|--ip-inicial)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    error 11 "Falta el valor de la opción $1. Escríbelo a continuación, separado por un espacio: $1 VALOR"
                fi
                if [[ -z "$2" ]]; then
                    error 11 "La opción $1 no admite un valor vacío."
                fi
                case "$1" in
                    --red)          RED_OPT="$2"   ;;
                    --disco)        DISCO_OPT="$2" ;;
                    --base)         BASE_OPT="$2"  ;;
                    --tam)          TAM_DISCO="$2"; TAM_EXPLICITO=true ;;
                    --imagen)       IMAGEN_OPT="$2" ;;
                    --discos-nodo)  DISCOS_NODO_OPT="$2" ;;
                    --ip-inicial)   IP_INICIAL_OPT="$2" ;;
                    --ram)          RAM_OPT="$2"   ;;
                    --vcpus)        VCPUS_OPT="$2" ;;
                    --ssh-pass)     SSH_PASS="$2"  ;;
                    --prefijo)      PREFIJO_OPT="$2" ;;
                esac
                shift 2
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            # Opciones de la versión anterior: se explica qué ha cambiado
            --enable-root)
                error 12 "La opción --enable-root ya no existe: root está habilitado por consola de forma predeterminada (contraseña ${PASS_CONSOLA}); usa --no-root si no lo quieres."
                ;;
            --virt-viewer)
                error 12 "La opción --virt-viewer ya no existe: la consola gráfica está activa de forma predeterminada; usa --no-virt-viewer si no la quieres."
                ;;
            --user-pass)
                error 12 "La opción --user-pass ha sido sustituida por --ssh-pass CONTRASEÑA (o '--ssh-pass -' para escribirla por teclado).
Sin ella, 'administrador' no tiene contraseña y por SSH se entra con tu clave; por consola entra root (contraseña ${PASS_CONSOLA})."
                ;;
            --)
                shift
                ARGS+=("$@")
                break
                ;;
            --*=*)
                error 12 "La opción '${1%%=*}' se escribe con un espacio, no con '=': ${1%%=*} ${1#*=}"
                ;;
            -*)
                error 12 "Opción desconocida '$1'. Consulta la ayuda con -h."
                ;;
            *)
                ARGS+=("$1")
                shift
                ;;
        esac
    done

    # --ssh-pass -: la contraseña se pide por teclado, para que no quede en el
    # historial ni la vean otros usuarios del servidor en 'ps'. El asistente,
    # que ya la ha pedido, la pasa por el entorno (que solo puede leer el
    # propio usuario) en lugar de en la línea de órdenes.
    if [[ "$SSH_PASS" == "-" ]]; then
        if [[ -n "${CI_PROVISION_SSH_PASS:-}" ]]; then
            SSH_PASS="$CI_PROVISION_SSH_PASS"
            unset CI_PROVISION_SSH_PASS
        elif [[ ! -t 0 ]]; then
            error 11 "Con '--ssh-pass -' la contraseña se pide por teclado, y aquí no hay terminal."
        else
            read -r -s -p "Contraseña para administrador: " SSH_PASS || SSH_PASS=""
            echo
            if [[ -z "$SSH_PASS" ]]; then
                error 11 "La contraseña no puede estar vacía."
            fi
        fi
    fi
}

# Número entero positivo escrito en decimal, sin que los ceros a la izquierda
# lo conviertan en octal (bash leería 08 como un error y 010 como 8).
# Imprime el número normalizado; devuelve 1 si no es un número.
decimal() {   # TEXTO
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$(( 10#$1 ))"
}

# Comprobaciones de las opciones ya leídas: modos, parámetros y valores
validar_opciones() {
    validar_modos
    if $CLUSTER; then
        validar_cluster
    elif ! $LISTAR && ! $ELIMINAR && ! $ELIMINAR_TODO && ! $MENU; then
        validar_maquina
    fi
    validar_valores
    validar_entorno_numerico
}

# Modos: --gluster-cluster, --listar, --eliminar, --eliminar-todo, --menu
validar_modos() {
    local modos=0 m
    for m in $CLUSTER $LISTAR $ELIMINAR $ELIMINAR_TODO $MENU; do
        if [[ "$m" == true ]]; then modos=$(( modos + 1 )); fi
    done
    if (( modos > 1 )); then
        error 10 "--gluster-cluster, --listar, --eliminar, --eliminar-todo y --menu son modos distintos: usa solo uno."
    fi
    if $LISTAR || $ELIMINAR || $ELIMINAR_TODO || $MENU; then
        if $EXTRA_DISKS || $GLUSTERFS || $LIMPIAR || $NO_WAIT || $NO_ROOT || $NO_GRAFICOS || $TAM_EXPLICITO || \
           [[ -n "$RED_OPT$DISCO_OPT$BASE_OPT$RAM_OPT$VCPUS_OPT$SSH_PASS$IMAGEN_OPT$DISCOS_NODO_OPT$IP_INICIAL_OPT" ]]; then
            error 10 "Con --listar, --eliminar, --eliminar-todo y --menu solo se admiten --prefijo, --dry-run y --si."
        fi
        if $ELIMINAR; then
            if (( ${#ARGS[@]} == 0 )); then
                error 10 "Falta el nombre de la máquina a eliminar: $0 --eliminar MAQUINA [MAQUINA...]
(p.ej. $0 --eliminar server1). Para ver las que tienes: $0 --listar"
            fi
            NOMBRES=( "${ARGS[@]}" )
            for m in "${NOMBRES[@]}"; do
                validar_nombre_corto "$m"
            done
        elif (( ${#ARGS[@]} > 0 )); then
            error 10 "--listar, --eliminar-todo y --menu no llevan MAQUINA (sobra: '${ARGS[*]}')."
        fi
    fi

    if $GLUSTERFS && $NO_WAIT; then
        error 10 "--no-wait no se puede combinar con --glusterfs: la base hay que apagarla
cuando cloud-init termine, así que es imprescindible esperar."
    fi
    if [[ -n "$DISCOS_NODO_OPT" ]] && ! $CLUSTER; then
        error 10 "--discos-nodo solo se aplica a --gluster-cluster. En una máquina suelta, usa --extra-disks."
    fi
    if [[ -n "$IP_INICIAL_OPT" ]] && ! $CLUSTER; then
        error 10 "--ip-inicial solo se aplica a --gluster-cluster. En una máquina suelta, indica la IP después del nombre."
    fi
}

# Nombre corto de una máquina: válido como hostname y sin el usuario (o el
# prefijo) delante, que lo antepone el script: 'usuario-server1' daría
# 'usuario-usuario-server1', que nadie quiere
validar_nombre_corto() {   # NOMBRE
    local m="$1" pref="${PREFIJO_OPT:-$USUARIO}"
    if ! [[ "$m" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || (( ${#m} > 63 )); then
        error 20 "El nombre de máquina '$m' no es válido.
Solo letras, números y guiones, empezando por letra o número (p.ej. server1, gluster-base)."
    fi
    if [[ "${m,,}" == "${pref,,}-"* ]]; then
        error 20 "El nombre de máquina '$m' ya empieza por '$pref-': el dominio sería '${pref}-${m}'.
Indica solo el nombre corto (p.ej. '${m#"${m%%-*}-"}'); '$pref-' lo antepone el script."
    fi
}

validar_cluster() {
    if (( ${#ARGS[@]} > 0 )); then
        error 10 "Con --gluster-cluster no se indica MAQUINA ni IP: los nombres (${CLUSTER_BASE}, ${CLUSTER_NODOS[*]}) son fijos
y las IPs van de la .${CLUSTER_IP_INICIAL} en adelante (cámbialo con --ip-inicial N)."
    fi
    if [[ -n "$DISCO_OPT" ]]; then
        error 10 "La opción --disco no se aplica a --gluster-cluster: los discos se llaman como los nodos."
    fi
    if $GLUSTERFS || $EXTRA_DISKS; then
        error 10 "--gluster-cluster ya construye la imagen base y los discos de cada nodo:
no se combina con --glusterfs ni con --extra-disks."
    fi
    if [[ -n "$IP_INICIAL_OPT" ]]; then
        local n
        if ! n="$(decimal "$IP_INICIAL_OPT")" || (( n < 2 || n > 250 )); then
            error 13 "La IP inicial '$IP_INICIAL_OPT' no es válida: indica el último número de la IP del primer nodo (de 2 a 250)."
        fi
        CLUSTER_IP_INICIAL="$n"
    fi
}

validar_maquina() {
    if (( ${#ARGS[@]} == 0 )); then
        error 10 "Falta el nombre de la máquina.
Uso: $0 [opciones] MAQUINA [IP]      (p.ej. $0 server1)
Consulta la ayuda con -h. En el servidor de la asignatura también puedes
ejecutarlo sin argumentos desde una terminal: se abre un asistente con menús."
    fi
    if (( ${#ARGS[@]} > 2 )); then
        error 10 "Sobran parámetros: '${ARGS[*]}'.
Parece la sintaxis de la versión anterior. Ahora solo se indica el nombre corto
de la máquina y, opcionalmente, la IP; el disco y la red se deducen de tu usuario:
  $0 [opciones] MAQUINA [IP]      (p.ej. $0 --extra-disks server1 192.168.XXX.2)
Consulta la ayuda con -h."
    fi
    MAQUINA="${ARGS[0]}"
    IP="${ARGS[1]:-}"
    validar_nombre_corto "$MAQUINA"

    if $GLUSTERFS && $EXTRA_DISKS; then
        error 10 "--extra-disks no se combina con --glusterfs: la imagen base es un solo disco,
que es lo único que queda al terminar. Los discos extra se crean al hacer las copias
(p.ej. --gluster-cluster, o --extra-disks --base ${MAQUINA}.qcow2 server1)."
    fi
    if $GLUSTERFS && [[ -n "$IP" ]]; then
        error 10 "Con --glusterfs no se indica IP: la máquina es provisional (se elimina al terminar)
y la IP la reciben las copias que hagas de ${MAQUINA}.qcow2."
    fi
}

# Valores de las opciones: recursos, tamaños, nombres, imagen, discos por nodo
validar_valores() {
    local n

    if $CLUSTER; then
        RAM_MB="${RAM_OPT:-$CLUSTER_RAM_MB}"
        VCPUS="${VCPUS_OPT:-$CLUSTER_VCPUS}"
    else
        RAM_MB="${RAM_OPT:-$RAM_MB_DEFECTO}"
        VCPUS="${VCPUS_OPT:-$VCPUS_DEFECTO}"
    fi
    if ! n="$(decimal "$RAM_MB")" || (( n < RAM_MB_MINIMO )); then
        error 13 "La memoria RAM '$RAM_MB' no es válida. Debe ser un número de MB igual o mayor que ${RAM_MB_MINIMO}."
    fi
    RAM_MB="$n"
    if ! n="$(decimal "$VCPUS")" || (( n < 1 )); then
        error 13 "El número de vCPUs '$VCPUS' no es válido. Debe ser un número igual o mayor que 1."
    fi
    VCPUS="$n"

    TAM_DISCO="${TAM_DISCO^^}"
    if ! [[ "$TAM_DISCO" =~ ^[0-9]+[MGT]$ ]] || (( 10#${TAM_DISCO%?} == 0 )); then
        error 15 "El tamaño de disco '$TAM_DISCO' no es válido. Indícalo como 40G, 20G, 512M..."
    fi
    TAM_DISCO="$(( 10#${TAM_DISCO%?} ))${TAM_DISCO: -1}"

    if [[ -n "$RED_OPT" ]] && ! [[ "$RED_OPT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        error 40 "El nombre de red '$RED_OPT' no es válido. Consulta tus redes con: virsh net-list --all"
    fi

    if [[ -n "$DISCO_OPT" ]] && ! [[ "$DISCO_OPT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        error 16 "El nombre de disco '$DISCO_OPT' no es válido. Indica solo el nombre del fichero (sin rutas), p.ej. server1.qcow2."
    fi

    if [[ -n "$BASE_OPT" ]] && ! [[ "$BASE_OPT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        error 16 "El nombre de imagen '$BASE_OPT' (--base) no es válido. Indica solo el nombre del fichero del silo (sin rutas), p.ej. gluster-base.qcow2."
    fi
    elegir_imagen

    n="${DISCOS_NODO_OPT:-$DISCOS_NODO_DEFECTO}"
    if ! n="$(decimal "$n")" || (( n < ${#CLUSTER_MONTAJES[@]} || n > ${#UNIDADES_POSIBLES_NODO[@]} )); then
        error 13 "El número de discos por nodo '$DISCOS_NODO_OPT' no es válido. Debe estar entre ${#CLUSTER_MONTAJES[@]} (los que se montan
en ${CLUSTER_MONTAJES[*]}) y ${#UNIDADES_POSIBLES_NODO[@]} (vdb..vdh, como crea-entorno.sh)."
    fi
    UNIDADES_CLUSTER=( "${UNIDADES_POSIBLES_NODO[@]:0:$n}" )

    if [[ -n "$PREFIJO_OPT" ]] && ! [[ "$PREFIJO_OPT" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
        error 20 "El prefijo '$PREFIJO_OPT' no es válido. Solo letras, números y guiones, p.ej. demo."
    fi

    # La contraseña se teclea en la consola de la máquina virtual, cuyo teclado
    # no tiene por qué corresponderse con el del alumno. El manual ya advierte
    # de no usar tildes ni caracteres del alfabeto español.
    if [[ -n "$SSH_PASS" ]] && grep -q '[^ -~]' <<< "$SSH_PASS"; then
        error 14 "La contraseña contiene caracteres no ASCII (tildes, ñ, etc.).
No podrías teclearla en la consola de la máquina virtual.
Usa solo letras sin tilde, números y signos básicos."
    fi
}

# Los tiempos de espera que se pueden ajustar desde el entorno
validar_entorno_numerico() {
    local v n
    for v in WAIT_TIMEOUT POLL_SECS GRACE_SECS SHUTDOWN_TIMEOUT; do
        if ! n="$(decimal "${!v}")" || { [[ "$v" == POLL_SECS ]] && (( n < 1 )); }; then
            error 13 "La variable de entorno CI_PROVISION_$v ('${!v}') no es válida: debe ser un número de segundos."
        fi
        printf -v "$v" '%s' "$n"
    done
}

# Nombres que salen de las opciones (dominio, hostname, disco principal)
calcular_derivados() {
    # Sin --prefijo: dominio USUARIO-MAQUINA y ficheros MAQUINA.qcow2, como en el
    # boletín. Con él, el prefijo va también en los ficheros, para que dos juegos
    # de máquinas convivan en el mismo silo sin pisarse.
    PREFIJO_DOMINIO="${PREFIJO_OPT:-$USUARIO}"
    PREFIJO_FICHERO="${PREFIJO_OPT:+${PREFIJO_OPT}-}"
    if ! $CLUSTER; then
        VM_NAME="${PREFIJO_DOMINIO}-${MAQUINA}"
        HOST_NAME="$MAQUINA"
        DISCO_MAIN="${SILO_DIR}/${DISCO_OPT:-$(disco_de "$MAQUINA")}"
    fi
}

# Nombre del disco principal de una máquina en el silo: MAQUINA.qcow2, o
# PREFIJO-MAQUINA.qcow2 con --prefijo (solo el nombre, sin ruta)
disco_de() {   # MAQUINA
    printf '%s%s.qcow2' "$PREFIJO_FICHERO" "$1"
}

########################################
# Aviso de known_hosts
#
# El DHCP reutiliza direcciones, así que es habitual que la IP de una máquina
# nueva ya figure en known_hosts con la clave de una máquina anterior. El
# resultado es el aviso alarmante del apartado B.2 del manual. Aquí solo se
# avisa y se da el comando: no se toca el known_hosts del usuario.
########################################
avisar_known_hosts() {
    local kh="$HOME/.ssh/known_hosts"
    local ip avisado=false

    if [[ ! -f "$kh" ]] || ! command -v ssh-keygen >/dev/null 2>&1; then
        return 0
    fi

    for ip in "$@"; do
        [[ -z "$ip" ]] && continue
        if ssh-keygen -F "$ip" -f "$kh" >/dev/null 2>&1; then
            if ! $avisado; then
                echo
                echo "AVISO: estas IPs ya figuran en tu known_hosts con la clave de otra máquina."
                echo "       Al conectar por SSH verás un aviso de seguridad. Para resolverlo:"
                avisado=true
            fi
            echo "         ssh-keygen -f \"$kh\" -R \"$ip\""
        fi
    done
}

########################################
# Construcción del comando virt-install
#   construir_comando NOMBRE RAM VCPUS DISCO_PRINCIPAL [DISCOS_EXTRA...]
# Usa los ficheros cloud-init generados justo antes (USER_DATA, META_DATA,
# NETWORK_DATA). Los discos se conectan en el orden dado: el primero es vda.
########################################
construir_comando() {
    local nombre="$1" ram="$2" vcpus="$3"
    shift 3
    local disco

    VIRT_INSTALL_CMD=(
        virt-install
        --quiet
        --name "$nombre"
        --ram "$ram"
        --vcpus "$vcpus"
        --import
    )

    for disco in "$@"; do
        VIRT_INSTALL_CMD+=( --disk "path=${disco},format=qcow2,bus=virtio" )
    done

    VIRT_INSTALL_CMD+=(
        --os-variant "$OS_VARIANT"
        --network "network=$NET_NAME"
        --cloud-init "user-data=$USER_DATA,meta-data=$META_DATA${NETWORK_DATA:+,network-config=$NETWORK_DATA}"
    )

    if $NO_GRAFICOS; then
        VIRT_INSTALL_CMD+=( --graphics none )
    else
        VIRT_INSTALL_CMD+=( --graphics spice )
    fi

    VIRT_INSTALL_CMD+=( --noautoconsole )
}

# Muestra el comando de forma legible, una opción por línea
imprimir_comando() {
    local i=1 n=${#VIRT_INSTALL_CMD[@]} arg siguiente

    printf '  virt-install \\\n'
    while (( i < n )); do
        arg="${VIRT_INSTALL_CMD[$i]}"
        siguiente="${VIRT_INSTALL_CMD[$(( i + 1 ))]:-}"

        if [[ "$arg" == --* && -n "$siguiente" && "$siguiente" != --* ]]; then
            printf '    %s %s' "$arg" "$siguiente"
            i=$(( i + 2 ))
        else
            printf '    %s' "$arg"
            i=$(( i + 1 ))
        fi

        if (( i < n )); then printf ' \\\n'; else printf '\n'; fi
    done
}

# Ejecuta virt-install y registra el dominio para poder deshacerlo
crear_dominio() {
    local nombre="$1"
    # Se registra ANTES de lanzarlo: si virt-install define el dominio y luego
    # falla (o llega un Ctrl+C), el rollback tiene que eliminarlo
    DOMINIOS_CREADOS+=( "$nombre" )
    "${VIRT_INSTALL_CMD[@]}"
}

# En --dry-run, si la imagen base no está en el silo
avisar_imagen_falta() {
    local compartida
    if $BASE_IMG_FALTA; then
        compartida="$(imagen_compartida)"
        if [[ -n "$compartida" ]]; then
            echo "    Imagen  : $(basename "$BASE_IMG") no está en el silo; se copiará de $compartida"
        else
            echo "    Imagen  : $(basename "$BASE_IMG") no está en el silo; se descargará de"
            echo "              $BASE_IMG_URL"
        fi
    fi
}

servidor_fqdn() {
    local h
    h="$(hostname 2>/dev/null || echo SERVIDOR)"
    if [[ "$h" != *.* ]]; then
        h="${h}.lsi.us.es"
    fi
    printf '%s' "$h"
}

########################################
# Resumen final de una máquina suelta
########################################
# Líneas de "Acceso" del resumen, iguales para una máquina suelta y para el clúster
bloque_acceso() {   # DOMINIO IP_PARA_SSH
    local vm="$1" ip="$2"
    printf '  %-42s %s\n' "ssh administrador@$ip" "con tu clave pública"
    if [[ -n "$SSH_PASS" ]]; then
        printf '  %-42s %s\n' "" "(o con la contraseña: $SSH_PASS)"
    elif [[ "$IMAGEN" == ubuntu-base ]]; then
        printf '  %-42s %s\n' "" "(o con la contraseña de ubuntu-base del boletín 1; sudo la pide)"
    fi
    if $NO_ROOT && [[ -z "$SSH_PASS" && "$IMAGEN" == ubuntu-base ]]; then
        printf '  %-42s %s\n' "virsh console $vm" "administrador, con la contraseña de ubuntu-base"
    elif $NO_ROOT && [[ -z "$SSH_PASS" ]]; then
        printf '  %-42s %s\n' "virsh console $vm" "(con --no-root y sin --ssh-pass nadie entra por consola: usa SSH)"
    elif $NO_ROOT; then
        printf '  %-42s %s\n' "virsh console $vm" "administrador, contraseña: $SSH_PASS"
    else
        printf '  %-42s %s\n' "virsh console $vm" "root, contraseña: $PASS_CONSOLA"
    fi
    if ! $NO_GRAFICOS; then
        echo "  virt-viewer --connect qemu+ssh://${USUARIO}@$(servidor_fqdn)/system $vm"
    fi
    if [[ "$IMAGEN" == ubuntu-base && -z "$SSH_PASS" ]]; then
        echo
        echo "AVISO: 'administrador' conserva la contraseña de ubuntu-base, que es la misma para toda"
        echo "       la clase, y entra por SSH con ella (y con sudo). Cualquier usuario del servidor"
        echo "       podría entrar en esta máquina. Cámbiala dentro con: passwd"
    fi
}

print_summary() {
    local vm_ip="${IPS_DETECTADAS[$VM_NAME]:-${IP_VISTA[$VM_NAME]:-}}"
    local ip_mostrar

    if [[ -n "$IP" && -n "$vm_ip" && "$vm_ip" != "$IP" ]]; then
        ip_mostrar="$IP (fija)  AVISO: la máquina ha respondido en $vm_ip; la configuración de red no se ha aplicado"
    elif [[ -n "$IP" ]]; then
        ip_mostrar="$IP (fija)"
    elif [[ -n "$vm_ip" ]]; then
        ip_mostrar="$vm_ip (DHCP)"
    else
        ip_mostrar="(DHCP; consúltala con: virsh domifaddr $VM_NAME --source agent)"
    fi

    echo "-------------------------------------------"
    echo "Máquina      : $VM_NAME  (hostname: $HOST_NAME)"
    echo "Sistema      : $(descripcion_imagen "$IMAGEN")"
    echo "Disco        : $DISCO_MAIN ($TAM_DISCO, copia COW de $(basename "$BASE_IMG"))"
    echo "Red          : $NET_NAME"
    echo "IP           : $ip_mostrar"
    echo "RAM / vCPUs  : ${RAM_MB} MB / ${VCPUS}"

    if $EXTRA_DISKS; then
        echo "Discos extra : ${UNIDADES_EXTRA[0]}..${UNIDADES_EXTRA[-1]} (${#UNIDADES_EXTRA[@]} × ${TAM_DISCO_EXTRA}), ver: virsh domblklist $VM_NAME"
    else
        echo "Discos extra : NO"
    fi

    if $GLUSTERFS; then
        echo "GlusterFS    : glusterfs-server instalado, glusterd habilitado, machine-id reseteado"
    else
        echo "GlusterFS    : NO"
    fi

    echo
    echo "Acceso:"
    bloque_acceso "$VM_NAME" "${vm_ip:-${IP:-IP}}"
    echo
    echo "Para eliminarla con sus discos:  $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--eliminar $MAQUINA"
    echo "-------------------------------------------"
}

########################################
# Resumen final de una base GlusterFS (--glusterfs)
########################################
print_summary_base() {
    echo "-------------------------------------------"
    echo "Imagen base GlusterFS lista"
    echo
    echo "Disco        : $DISCO_MAIN ($TAM_DISCO, $(origen_disco_principal "$BASE_IMG"))"
    echo "Contenido    : $(descripcion_imagen "$IMAGEN") con glusterfs-server instalado (y las"
    echo "               herramientas para formatear en xfs), glusterd habilitado, zona horaria"
    echo "               Europe/Madrid y machine-id vacío"
    echo "Dominio      : $VM_NAME se ha eliminado; solo queda el disco"
    echo
    echo "Úsalo como respaldo de las copias COW de tus nodos. Con el script:"
    echo "  $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--gluster-cluster --base $(basename "$DISCO_MAIN")"
    echo "  $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--extra-disks --base $(basename "$DISCO_MAIN") server1 192.168.XXX.10"
    echo "O a mano, desde el silo:"
    echo "  cd $SILO_DIR && qemu-img create -f qcow2 -b $(basename "$DISCO_MAIN") -F qcow2 server1.qcow2 $TAM_DISCO"
    echo
    echo "IMPORTANTE: no borres ni modifiques $(basename "$DISCO_MAIN") mientras existan copias de él."
    if [[ -z "$DISCO_OPT" ]]; then
        echo "Cuando ya no lo necesites:  $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--eliminar $MAQUINA"
    fi
    echo "-------------------------------------------"
}

########################################
# Una máquina suelta
########################################
# Qué va a crear esta ejecución (dominios y ficheros). Se calcula antes de la
# validación que cuesta tiempo (la descarga de la imagen), para avisar de un
# conflicto cuanto antes.
EXTRAS=()
calcular_objetivos() {
    local disco
    if $CLUSTER; then
        objetivos_cluster
        return 0
    fi
    EXTRAS=()
    if $EXTRA_DISKS; then
        while IFS= read -r disco; do EXTRAS+=( "$disco" ); done < <(discos_extra "$MAQUINA" "${UNIDADES_EXTRA[@]}")
        for disco in "${EXTRAS[@]}"; do
            if [[ "$disco" == "$DISCO_MAIN" ]]; then
                error 16 "El nombre de disco '$(basename "$DISCO_MAIN")' coincide con uno de los discos extra que se crearían.
Elige otro nombre para el disco principal."
            fi
        done
    fi
    OBJ_DOMINIOS=( "$VM_NAME" )
    OBJ_FICHEROS=( "$DISCO_MAIN" ${EXTRAS[@]+"${EXTRAS[@]}"} )
}

# Crea una máquina: cloud-init, discos y dominio, registrándolo todo para el
# rollback. Lo usan la máquina suelta, la base GlusterFS y cada nodo del clúster.
#   crear_maquina DOMINIO HOSTNAME IP MODO DISCO IMAGEN_DE_PARTIDA [DISCO_EXTRA...]
crear_maquina() {
    local vm="$1" host="$2" ip="$3" modo="$4" disco="$5" base="$6"
    shift 6
    local -a extras=( "$@" )
    local d

    generar_cloudinit "$vm" "$host" "$ip" "$modo"
    construir_comando "$vm" "$RAM_MB" "$VCPUS" "$disco" ${extras[@]+"${extras[@]}"}

    echo "→ Creando el disco $(basename "$disco") ($(origen_disco_principal "$base"), $TAM_DISCO)…"
    crear_disco_principal "$disco" "$base" "$TAM_DISCO"
    if (( ${#extras[@]} > 0 )); then
        echo "→ Creando ${#extras[@]} discos extra de $TAM_DISCO_EXTRA ($(basename "${extras[0]}") … $(basename "${extras[-1]}"))…"
        for d in "${extras[@]}"; do
            crear_disco_vacio "$d" "$TAM_DISCO_EXTRA"
        done
    fi

    echo "→ Creando la máquina '$vm' con cloud-init…"
    crear_dominio "$vm"
    if [[ -n "$ip" ]]; then
        IP_ESPERADA[$vm]="$ip"
    fi
}

# Plan de --dry-run de una máquina suelta: genera los ficheros (en el
# directorio .dry-run) y enseña lo que se haría
mostrar_plan_maquina() {
    local modo="normal" disco
    if $GLUSTERFS; then
        modo="gluster"
    fi
    generar_cloudinit "$VM_NAME" "$HOST_NAME" "$IP" "$modo"
    construir_comando "$VM_NAME" "$RAM_MB" "$VCPUS" "$DISCO_MAIN" ${EXTRAS[@]+"${EXTRAS[@]}"}

    echo "→ MODO SIMULACIÓN (--dry-run): no se creará ninguna máquina."
    echo
    echo "✔ Validaciones superadas."
    echo "    Usuario : $USUARIO"
    if [[ -n "$PREFIJO_OPT" ]]; then
        echo "    Prefijo : $PREFIJO_OPT (sustituye al usuario en los dominios y en los discos)"
    fi
    echo "    Máquina : $VM_NAME  (hostname: $HOST_NAME)"
    echo "    Sistema : $(descripcion_imagen "$IMAGEN"); variante $OS_VARIANT"
    echo "    Red     : $NET_NAME (pasarela $NET_GATEWAY, prefijo /$NET_PREFIX)"
    if [[ -n "$IP" ]]; then
        echo "    IP      : $IP, disponible para asignación fija"
    else
        echo "    IP      : por DHCP"
    fi
    echo "    Recursos: ${RAM_MB} MB y ${VCPUS} vCPU"
    avisar_imagen_falta
    echo
    echo "✔ Ficheros cloud-init generados en $WORKDIR/"
    echo
    echo "Discos que se crearían en $SILO_DIR:"
    echo "    $(basename "$DISCO_MAIN")  ($(origen_disco_principal "$BASE_IMG"), $TAM_DISCO)"
    for disco in ${EXTRAS[@]+"${EXTRAS[@]}"}; do
        echo "    $(basename "$disco")  ($TAM_DISCO_EXTRA)"
    done
    echo
    echo "Comando que se ejecutaría:"
    echo
    imprimir_comando
    echo
    if $GLUSTERFS; then
        echo "Al terminar cloud-init, la máquina se apagaría y se eliminaría el dominio,"
        echo "dejando solo $(basename "$DISCO_MAIN") como imagen base."
        echo
    fi
    echo "No se ha creado ni modificado ninguna máquina, disco ni red."
}

ejecutar_maquina() {
    # Conflictos con lo que ya exista (y --limpiar, si se pidió)
    comprobar_conflictos

    if $DRY_RUN; then
        mostrar_plan_maquina
        return 0
    fi

    # Base GlusterFS: se construye, se apaga y se elimina el dominio
    if $GLUSTERFS; then
        crear_base_gluster "$VM_NAME" "$HOST_NAME" "$DISCO_MAIN"
        CREACION_COMPLETA=true
        print_summary_base
        return 0
    fi

    crear_maquina "$VM_NAME" "$HOST_NAME" "$IP" normal "$DISCO_MAIN" "$BASE_IMG" ${EXTRAS[@]+"${EXTRAS[@]}"}
    CREACION_COMPLETA=true
    echo "✔ Máquina creada y arrancada."
    echo "-------------------------------------------"

    if $NO_WAIT; then
        echo "Omitiendo la espera (--no-wait activo)."
        echo "NOTA: la máquina sigue configurándose por dentro. No se expulsa el medio de"
        echo "      cloud-init; si vas a tomar instantáneas, apágala antes."
    else
        # Solo se expulsa el medio de cloud-init si consta que la máquina ya
        # terminó de configurarse: hacerlo antes podría interrumpir a cloud-init.
        if esperar_maquinas "$VM_NAME"; then
            eject_cloudinit_media "$VM_NAME"
        fi
    fi

    print_summary
    avisar_known_hosts "${IP:-${IPS_DETECTADAS[$VM_NAME]:-}}"
}

########################################
# MAIN
########################################
main() {
    # Sin argumentos y desde una terminal: el asistente con menús
    if (( $# == 0 )) && [[ -t 0 && -t 1 ]] && command -v whiptail >/dev/null 2>&1; then
        set -- --menu
    fi

    parse_args "$@"
    validar_opciones
    calcular_derivados
    validar_entorno

    if $MENU; then
        if ! command -v whiptail >/dev/null 2>&1; then
            error 38 "El asistente (--menu) necesita el programa 'whiptail', que no está en este equipo
(en los servidores de la asignatura sí está). Usa las opciones de la línea de comandos: $0 -h"
        fi
        asistente
    elif $LISTAR; then
        listar_maquinas
    elif $ELIMINAR; then
        eliminar_maquinas "${NOMBRES[@]}"
    elif $ELIMINAR_TODO; then
        eliminar_todo
    elif $CLUSTER; then
        ejecutar_cluster
    else
        ejecutar_maquina
    fi
}

main "$@"
