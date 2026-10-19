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
