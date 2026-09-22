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
    local xml
    if ! xml="$(virsh net-dumpxml "$NET_NAME" 2>/dev/null)"; then
        error 40 "La red '$NET_NAME' no existe.
Consulta las redes disponibles con: virsh net-list --all"
    fi

    # Bloque <ip> de IPv4 (se descartan los de IPv6).
    # El 'head -n1' cierra la tubería en cuanto tiene su línea; sin el '|| true'
    # el SIGPIPE de los grep haría fallar la tubería por 'pipefail'.
    local ipline
    ipline="$( { printf '%s\n' "$xml" | grep -E '<ip[[:space:]]' | grep -v "family='ipv6'" | head -n1; } || true )"
    if [[ -z "$ipline" ]]; then
        error 43 "No se ha podido determinar la configuración IPv4 de la red '$NET_NAME'."
    fi

    NET_GATEWAY="$(xml_attr "$ipline" address)"
    NET_NETMASK="$(xml_attr "$ipline" netmask)"
    local pfx
    pfx="$(xml_attr "$ipline" prefix)"

    if [[ -n "$NET_NETMASK" ]]; then
        if ! NET_PREFIX="$(mask_to_prefix "$NET_NETMASK")"; then
            error 43 "La máscara '$NET_NETMASK' de la red '$NET_NAME' no es válida."
        fi
    elif [[ -n "$pfx" ]]; then
        NET_PREFIX="$pfx"
    else
        error 43 "La red '$NET_NAME' no declara ni máscara ni prefijo."
    fi

    if ! valid_ipv4 "$NET_GATEWAY"; then
        error 43 "La pasarela '$NET_GATEWAY' de la red '$NET_NAME' no es una IPv4 válida."
    fi

    # Rangos DHCP (puede haber varios)
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        NET_DHCP_STARTS+=( "$(xml_attr "$line" start)" )
        NET_DHCP_ENDS+=( "$(xml_attr "$line" end)" )
    done < <(printf '%s\n' "$xml" | grep -E '<range[[:space:]]' || true)

    # Reservas estáticas por MAC. Pueden estar fuera del rango DHCP,
    # así que hay que tenerlas en cuenta aparte.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        NET_RESERVED+=( "$(xml_attr "$line" ip)" )
    done < <(printf '%s\n' "$xml" | grep -E '<host[[:space:]].*[[:space:]]ip=' || true)
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

# Valida una IP fija contra la configuración real de la red
validar_ip_fija() {
    local ip="$1"

    if ! valid_ipv4 "$ip"; then
        error 41 "La IP '$ip' no es una dirección IPv4 válida."
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

También puedes omitir el parámetro IP para que la máquina use DHCP."
        fi
    done

    # Coincide con una reserva estática
    for (( i = 0; i < ${#NET_RESERVED[@]}; i++ )); do
        if [[ "$ip" == "${NET_RESERVED[$i]}" ]]; then
            error 42 "La IP '$ip' ya está reservada por MAC en la red '$NET_NAME'.
IPs libres para asignación fija:
$(free_ip_blocks)"
        fi
    done
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
# Imagen base: si no está, se descarga; si está, se comprueba
########################################
descargar_imagen_base() {
    local tmp="${BASE_IMG}.descargando"

    echo "→ No está $(basename "$BASE_IMG") en el silo. Se descarga de:"
    echo "  $BASE_IMG_URL  (unos 430 MB; puede tardar un rato)"

    # Se descarga a un nombre temporal y solo se renombra si termina bien:
    # así una descarga a medias nunca se confunde con la imagen.
    rm -f "$tmp"
    DISCOS_CREADOS+=( "$tmp" )

    local rc=0
    if command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -O "$tmp" "$BASE_IMG_URL" || rc=$?
    elif command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "$tmp" "$BASE_IMG_URL" || rc=$?
    else
        error 38 "No hay ni wget ni curl para descargar la imagen base.
Descárgala tú en el silo con el nombre $(basename "$BASE_IMG")."
    fi

    if (( rc != 0 )); then
        rm -f "$tmp"
        quitar_disco_creado "$tmp"
        error 37 "No se ha podido descargar la imagen base (código $rc).
Comprueba la conexión, o descárgala tú:
  wget $BASE_IMG_URL -O $BASE_IMG"
    fi

    mv "$tmp" "$BASE_IMG"
    quitar_disco_creado "$tmp"
    echo "✔ Imagen base descargada: $BASE_IMG"
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
    done
}

# --tam no puede ser menor que la imagen de la que se hace la copia: qemu-img
# lo admite, pero la máquina arrancaría con el sistema de ficheros truncado
comprobar_tam_disco() {
    local vs n tam_b
    [[ -f "$BASE_IMG" ]] || return 0
    vs="$(qemu-img info -U --output=json "$BASE_IMG" 2>/dev/null | jq -r '."virtual-size" // empty' 2>/dev/null || true)"
    [[ "$vs" =~ ^[0-9]+$ ]] || return 0
    n="${TAM_DISCO%[MGT]}"
    case "${TAM_DISCO: -1}" in
        M) tam_b=$(( n * 1024 * 1024 )) ;;
        G) tam_b=$(( n * 1024 * 1024 * 1024 )) ;;
        T) tam_b=$(( n * 1024 * 1024 * 1024 * 1024 )) ;;
        *) return 0 ;;
    esac
    if (( tam_b < vs )); then
        error 15 "El tamaño --tam $TAM_DISCO es menor que el de la imagen $(basename "$BASE_IMG") ($(( (vs + 1073741823) / 1073741824 )) GiB):
la copia quedaría truncada y la máquina no arrancaría bien. Indica un tamaño igual o mayor."
    fi
}

comprobar_imagen_base() {
    # Imagen indicada con --base: tiene que existir ya; no se descarga nada
    if [[ -n "$BASE_OPT" ]]; then
        if [[ ! -f "$BASE_IMG" ]]; then
            error 39 "La imagen indicada con --base no está en el silo: $BASE_IMG"
        fi
        local info_b fmt_b
        info_b="$(qemu-img info -U --output=json "$BASE_IMG" 2>/dev/null || true)"
        fmt_b="$(printf '%s' "$info_b" | jq -r '.format // empty' 2>/dev/null || true)"
        if [[ "$fmt_b" != "qcow2" ]]; then
            error 39 "La imagen indicada con --base no es un qcow2 válido: $BASE_IMG (formato: ${fmt_b:-desconocido})."
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
Crea ese directorio y mapéalo como silo en el hipervisor."
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
    if (( claves != 1 )) || ! [[ "$PUBKEY" =~ $re ]]; then
        error 31 "El fichero $PUBKEY_PATH debe contener una sola clave pública: una línea que empiece
por ssh-rsa, ssh-ed25519 o ecdsa-sha2-… (ahora tiene $claves líneas con contenido).
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
########################################

# Los rellena quien llama: qué dominios y qué ficheros va a crear
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

# Pregunta sí/no por teclado. Sin terminal (uso desde otro script) la opción
# ya es una petición explícita y se sigue adelante.
confirmar() {   # PREGUNTA
    if [[ ! -t 0 ]]; then return 0; fi
    local respuesta
    read -r -p "$1 [s/N] " respuesta || { respuesta=""; echo; }
    case "$respuesta" in
        s|S|si|sí|Si|Sí|SI|SÍ) return 0 ;;
        *) return 1 ;;
    esac
}

# Dominios "vecinos": los que NO son objetivo de esta ejecución y podrían
# estar usando ficheros de este silo. Por defecto, los del usuario (o del
# prefijo); con 'todos', todos los del servidor. De cada uno se anotan sus
# discos, para saber quién usa cada fichero.
DOMINIOS_VECINOS=()
declare -A DISCO_USADO_POR=()   # fichero → dominio vecino que lo usa
cargar_dominios_vecinos() {   # [todos]
    local lista d f salida todos="${1:-}" pref1="${USUARIO,,}" pref2="${PREFIJO_DOMINIO,,}"
    DOMINIOS_VECINOS=()
    DISCO_USADO_POR=()
    lista="$(virsh list --all --name 2>/dev/null || true)"
    while IFS= read -r d; do
        if [[ -z "$d" ]]; then continue; fi
        if [[ -z "$todos" && "${d,,}" != "$pref1"* && "${d,,}" != "$pref2"* ]]; then continue; fi
        if en_lista "$d" ${OBJ_DOMINIOS[@]+"${OBJ_DOMINIOS[@]}"}; then continue; fi
        DOMINIOS_VECINOS+=( "$d" )
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

# ¿Es este fichero el respaldo (imagen base) de otro qcow2 del silo que se
# conserva? Devuelve ese otro fichero por stdout.
copia_que_depende() {   # FICHERO
    local f="$1" o b x
    for o in "$SILO_DIR"/*.qcow2; do
        [[ -f "$o" && "$o" != "$f" ]] || continue
        for x in ${OBJ_FICHEROS[@]+"${OBJ_FICHEROS[@]}"}; do
            [[ "$x" == "$o" ]] && continue 2
        done
        b="$(qemu-img info -U --output=json "$o" 2>/dev/null | jq -r '."backing-filename" // empty' 2>/dev/null || true)"
        if [[ -n "$b" && "$(basename "$b")" == "$(basename "$f")" ]]; then
            echo "$o"
            return 0
        fi
    done
    return 1
}

comprobar_conflictos() {
    local -a dominios=() ficheros=()
    local d f

    for d in ${OBJ_DOMINIOS[@]+"${OBJ_DOMINIOS[@]}"}; do
        if virsh dominfo "$d" >/dev/null 2>&1; then
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
    # con otro nombre) o el respaldo de otras copias. Entonces ni se elimina
    # ni se aconseja eliminarlo.
    if (( ${#ficheros[@]} > 0 )); then
        local otro
        cargar_dominios_vecinos
        for f in "${ficheros[@]}"; do
            if otro="$(dominio_que_usa_disco "$f")"; then
                error 21 "El disco $f ya existe y lo usa la máquina '$otro', que este script no va a crear ni a eliminar.
Elige otro nombre de máquina (o de disco, con --disco). Si lo que quieres es deshacerte de '$otro':
  virsh destroy $otro; virsh undefine $otro --snapshots-metadata; rm $f"
            fi
            if otro="$(copia_que_depende "$f")"; then
                error 21 "El disco $f ya existe y es la imagen base de $(basename "$otro"), que dejaría de arrancar sin él.
Elige otro nombre de máquina (o de disco, con --disco), o elimina antes esa copia."
            fi
        done
    fi

    if ! $LIMPIAR; then
        local msg="Ya existen elementos que este script tendría que crear:"
        for d in ${dominios[@]+"${dominios[@]}"}; do msg+=$'\n'"  dominio  $d"; done
        for f in ${ficheros[@]+"${ficheros[@]}"}; do msg+=$'\n'"  disco    $f"; done
        msg+=$'\n\n'"El script siempre crea máquinas y discos nuevos. Tienes dos opciones:"
        msg+=$'\n'"  a) Eliminarlos tú:"
        for d in ${dominios[@]+"${dominios[@]}"}; do
            msg+=$'\n'"       virsh destroy $d; virsh undefine $d --snapshots-metadata"
        done
        for f in ${ficheros[@]+"${ficheros[@]}"}; do
            msg+=$'\n'"       rm $f"
        done
        msg+=$'\n'"  b) Repetir el comando añadiendo --limpiar, que elimina exactamente eso y nada más."
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

    # Confirmación por teclado. Si no hay terminal (uso desde otro script),
    # --limpiar ya es una petición explícita y se sigue adelante.
    if ! confirmar "¿Eliminar estos elementos?"; then
        echo "Cancelado: no se ha eliminado nada."
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
########################################
generar_cloudinit() {
    local vm="$1" host="$2" ip="$3" modo="$4"

    # En modo simulación se usa un directorio aparte, para no sobrescribir los
    # ficheros de una máquina que ya exista.
    if $DRY_RUN; then
        WORKDIR="${SILO_DIR}/cloudinit-${vm}.dry-run"
    else
        WORKDIR="${SILO_DIR}/cloudinit-${vm}"
    fi

    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    # Estos ficheros contienen contraseñas en texto plano y el servidor de la
    # asignatura es multiusuario: solo su propietario debe poder leerlos.
    chmod 700 "$WORKDIR"

    USER_DATA="$WORKDIR/cip-user.yaml"
    META_DATA="$WORKDIR/cip-meta.yaml"
    NETWORK_DATA=""

    ########################################
    # meta-data
    #
    # El instance-id importa: cloud-init vuelve a configurar una máquina
    # cuando ve uno distinto del que tenía. Así se personalizan los nodos del
    # clúster, que parten de un disco ya configurado.
    ########################################
    cat > "$META_DATA" <<EOF
instance-id: ${vm}
local-hostname: ${host}
EOF

    ########################################
    # user-data
    ########################################
    local i

    {
        echo "#cloud-config"
        echo "users:"
        echo "  - name: administrador"
        echo "    groups: [sudo]"
        echo "    shell: /bin/bash"
        echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']"
        echo "    ssh-authorized-keys:"
        echo "      - $PUBKEY"

        # root tiene contraseña para poder entrar por consola (por SSH no
        # entra: sshd de Debian trae PermitRootLogin prohibit-password).
        # 'administrador' solo la tiene si se pide --ssh-pass; si no, entra
        # únicamente por SSH con su clave, igual que en las máquinas que se
        # crean a mano siguiendo el manual.
        if [[ -n "$SSH_PASS" ]] || ! $NO_ROOT; then
            echo "chpasswd:"
            echo "  list: |"
            if [[ -n "$SSH_PASS" ]]; then
                echo "    administrador:${SSH_PASS}"
            fi
            if ! $NO_ROOT; then
                echo "    root:${PASS_CONSOLA}"
            fi
            echo "  expire: false"
        fi

        # SSH por contraseña solo si el alumno lo pide explícitamente. Se fija
        # también el 'false' para no depender del valor por defecto de la imagen.
        if [[ -n "$SSH_PASS" ]]; then
            echo "ssh_pwauth: true"
        else
            echo "ssh_pwauth: false"
        fi

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

                # Resolución por nombre entre los nodos (apartado A.3.2).
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
                # runcmd (más abajo) para que las líneas de /etc/fstab sean
                # exactamente las que muestran los ejercicios del manual; el
                # módulo 'mounts' de cloud-init las escribiría a su manera.
                echo "fs_setup:"
                for i in "${!CLUSTER_MONTAJES[@]}"; do
                    echo "  - device: /dev/${UNIDADES_CLUSTER[$i]}"
                    echo "    filesystem: xfs"
                    echo "    partition: none"
                    echo "    overwrite: false"
                done
                ;;
        esac

        echo "runcmd:"
        if [[ "$modo" == "nodo" ]]; then
            echo "  - mkdir -p ${CLUSTER_MONTAJES[*]}"
            for i in "${!CLUSTER_MONTAJES[@]}"; do
                echo "  - echo '/dev/${UNIDADES_CLUSTER[$i]} ${CLUSTER_MONTAJES[$i]} xfs ${OPCIONES_FSTAB_CLUSTER} 0 0' >> /etc/fstab"
            done
            echo "  - mount -a"
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
    } > "$USER_DATA"

    chmod 600 "$USER_DATA" "$META_DATA"

    ########################################
    # network-config (solo si IP estática)
    #
    # La pasarela y el prefijo se toman de la configuración real de la red
    # (ver load_network_info). Se usa la forma 'routes:' en lugar de la
    # obsoleta 'gateway4:' para que coincida con la plantilla del manual.
    ########################################
    if [[ -n "$ip" ]]; then
        NETWORK_DATA="$WORKDIR/cip-net.yaml"

        cat > "$NETWORK_DATA" <<EOF
version: 2
ethernets:
  enp1s0:
    addresses:
      - ${ip}/${NET_PREFIX}
    routes:
      - to: default
        via: ${NET_GATEWAY}
    nameservers:
      addresses:
        - 150.214.186.69
        - 150.214.130.15
EOF
        chmod 600 "$NETWORK_DATA"
    fi
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

# Disco vacío (sin respaldo)
#   crear_disco_vacio RUTA TAMAÑO
crear_disco_vacio() {
    local ruta="$1" tam="$2"

    DISCOS_CREADOS+=( "$ruta" )
    qemu-img create -f qcow2 "$ruta" "$tam" >/dev/null
}

# Quita un fichero del registro de creados (cuando pasa a ser definitivo)
quitar_disco_creado() {
    local quitar="$1" d
    local -a nuevos=()
    for d in ${DISCOS_CREADOS[@]+"${DISCOS_CREADOS[@]}"}; do
        if [[ "$d" != "$quitar" ]]; then
            nuevos+=( "$d" )
        fi
    done
    DISCOS_CREADOS=( ${nuevos[@]+"${nuevos[@]}"} )
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
cloudinit_status() {
    local vm="$1" r pid s exited datos i

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
            awk '/^status:/ { sub(/^status: */, ""); print; exit }' <<< "$datos"
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
            error)
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
# Infraestructura GlusterFS completa (apartado A.3.2 del manual)
#
# Dos fases, las mismas que describe el manual, pero todo con cloud-init:
#
#   Fase 1  Se crea una máquina base con glusterfs-server instalado, glusterd
#           habilitado y el machine-id vacío; se espera a que termine, se
#           apaga y se elimina su dominio conservando el disco.
#   Fase 2  Cada nodo es una copia COW de ese disco con sus discos extra
#           conectados desde el primer arranque. Un instance-id nuevo hace
#           que cloud-init lo personalice: IP fija, /etc/hosts, discos xfs
#           montados. Los nodos arrancan en paralelo y se espera a todos.
#
# Frente a crea-entorno.sh no hace falta virt-customize (el error 'supermin'
# del apartado B.5 desaparece), ni virt-format, ni xmllint; cada nodo tiene
# sus propias claves SSH de host, y las IPs se validan contra el DHCP real.
########################################

# Quita un dominio del registro de creados (cuando se elimina a propósito)
quitar_dominio_creado() {
    local quitar="$1" d
    local -a nuevos=()
    for d in ${DOMINIOS_CREADOS[@]+"${DOMINIOS_CREADOS[@]}"}; do
        if [[ "$d" != "$quitar" ]]; then
            nuevos+=( "$d" )
        fi
    done
    DOMINIOS_CREADOS=( ${nuevos[@]+"${nuevos[@]}"} )
}

# Discos extra de un nodo
discos_extra_nodo() {
    local host="$1" u
    for u in "${UNIDADES_CLUSTER[@]}"; do
        echo "${SILO_DIR}/${PREFIJO_FICHERO}${host}-${u}.qcow2"
    done
}

# Disco de la imagen base del clúster: la que se construye en la fase 1 o,
# con --base, una que ya existe en el silo
disco_base_cluster() {
    if [[ -n "$BASE_OPT" ]]; then
        echo "${SILO_DIR}/${BASE_OPT}"
    else
        echo "${SILO_DIR}/${PREFIJO_FICHERO}${CLUSTER_BASE}.qcow2"
    fi
}

# Rellena OBJ_DOMINIOS y OBJ_FICHEROS con todo lo que crea el clúster
objetivos_cluster() {
    local host d
    OBJ_DOMINIOS=()
    OBJ_FICHEROS=()
    if [[ -z "$BASE_OPT" ]]; then
        OBJ_DOMINIOS+=( "${PREFIJO_DOMINIO}-${CLUSTER_BASE}" )
        OBJ_FICHEROS+=( "${SILO_DIR}/${PREFIJO_FICHERO}${CLUSTER_BASE}.qcow2" )
    fi
    for host in "${CLUSTER_NODOS[@]}"; do
        OBJ_DOMINIOS+=( "${PREFIJO_DOMINIO}-${host}" )
        OBJ_FICHEROS+=( "${SILO_DIR}/${PREFIJO_FICHERO}${host}.qcow2" )
        while IFS= read -r d; do
            OBJ_FICHEROS+=( "$d" )
        done < <(discos_extra_nodo "$host")
    done
}

########################################
# Base GlusterFS: crea la máquina, espera a que cloud-init termine, la apaga
# y elimina el dominio. Queda solo el disco, listo para hacer copias COW.
# Es lo que describen los pasos 3 a 5 del procedimiento del apéndice A.3.2,
# y lo usan tanto --glusterfs como la fase 1 de --gluster-cluster.
#   crear_base_gluster DOMINIO HOSTNAME DISCO
########################################
crear_base_gluster() {
    local vm="$1" host="$2" disco="$3"

    generar_cloudinit "$vm" "$host" "" gluster
    construir_comando "$vm" "$RAM_MB" "$VCPUS" "$disco"

    echo "→ Creando el disco $(basename "$disco") (copia COW de $(basename "$BASE_IMG"), $TAM_DISCO)…"
    crear_disco_cow "$disco" "$BASE_IMG" "$TAM_DISCO"

    echo "→ Creando la máquina '$vm' con cloud-init…"
    crear_dominio "$vm"

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
        error 70 "La máquina '$vm' no se ha apagado en ${SHUTDOWN_TIMEOUT}s."
    fi

    # El dominio sobra: el disco se queda como respaldo de las copias
    virsh undefine "$vm" --snapshots-metadata >/dev/null
    quitar_dominio_creado "$vm"
    echo "✔ Base lista: $(basename "$disco") (el dominio '$vm' se ha eliminado; el disco se conserva)."
}

mostrar_plan_cluster() {
    local base_vm="${PREFIJO_DOMINIO}-${CLUSTER_BASE}"
    local base_disco i host vm
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
    echo "    Recursos: ${RAM_MB} MB y ${VCPUS} vCPU por máquina"
    avisar_imagen_falta
    echo

    if [[ -n "$BASE_OPT" ]]; then
        echo "Fase 1: se omite. Los nodos partirán de la imagen que ya existe: $(basename "$base_disco")"
    else
        echo "Fase 1: base GlusterFS"
        echo "    Máquina $base_vm con disco $(basename "$base_disco") (COW de $(basename "$BASE_IMG"), $TAM_DISCO)."
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
    echo "    ${UNIDADES_CLUSTER[0]}, ${UNIDADES_CLUSTER[1]} y ${UNIDADES_CLUSTER[2]} en xfs, montados en ${CLUSTER_MONTAJES[*]}; el resto sin formatear."
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${PREFIJO_DOMINIO}-${host}"
        generar_cloudinit "$vm" "$host" "${CLUSTER_IPS[$i]}" nodo
        echo "    $vm: disco ${PREFIJO_FICHERO}${host}.qcow2 (COW de $(basename "$base_disco")), IP ${CLUSTER_IPS[$i]}, cloud-init en $WORKDIR/"
    done
    echo
    echo "    Comando del primer nodo (los demás son iguales, con su nombre, IP y discos):"
    local -a extras=()
    while IFS= read -r i; do extras+=( "$i" ); done < <(discos_extra_nodo "${CLUSTER_NODOS[0]}")
    generar_cloudinit "${PREFIJO_DOMINIO}-${CLUSTER_NODOS[0]}" "${CLUSTER_NODOS[0]}" "${CLUSTER_IPS[0]}" nodo
    construir_comando "${PREFIJO_DOMINIO}-${CLUSTER_NODOS[0]}" "$RAM_MB" "$VCPUS" "${SILO_DIR}/${PREFIJO_FICHERO}${CLUSTER_NODOS[0]}.qcow2" "${extras[@]}"
    imprimir_comando | sed 's/^/    /'
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
    echo "Discos       : ${UNIDADES_CLUSTER[0]}..${UNIDADES_CLUSTER[-1]} (${#UNIDADES_CLUSTER[@]} × ${TAM_DISCO_EXTRA}) en cada nodo"
    echo "               ${UNIDADES_CLUSTER[0]}, ${UNIDADES_CLUSTER[1]} y ${UNIDADES_CLUSTER[2]} en xfs, montados en ${CLUSTER_MONTAJES[*]}"
    echo "GlusterFS    : glusterfs-server instalado y glusterd habilitado en todos"
    echo "/etc/hosts   : con los ${#CLUSTER_NODOS[@]} nombres, en todos"
    echo
    echo "Acceso (igual en todos los nodos):"
    echo "  ssh administrador@IP                  con tu clave pública"
    if [[ -n "$SSH_PASS" ]]; then
        echo "                                        (o con la contraseña: $SSH_PASS)"
    fi
    if $NO_ROOT; then
        echo "  virsh console ${PREFIJO_DOMINIO}-server1        (root sin contraseña: --no-root)"
    else
        echo "  virsh console ${PREFIJO_DOMINIO}-server1        root, contraseña: $PASS_CONSOLA"
    fi
    if ! $NO_GRAFICOS; then
        echo "  virt-viewer --connect qemu+ssh://${USUARIO}@$(servidor_fqdn)/system ${PREFIJO_DOMINIO}-server1"
    fi
    echo
    echo "IMPORTANTE: no borres $base_disco."
    echo "            Los discos de los ${#CLUSTER_NODOS[@]} nodos dependen de él."
    echo
    echo "Para eliminar la infraestructura entera (nodos${BASE_OPT:+ }${BASE_OPT:-e imagen base}):"
    echo "  $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--eliminar ${CLUSTER_NODOS[*]}${BASE_OPT:+}${BASE_OPT:- $CLUSTER_BASE}"
    echo "-------------------------------------------"
}

ejecutar_cluster() {
    local base_vm="${PREFIJO_DOMINIO}-${CLUSTER_BASE}"
    local base_disco i host vm ip disco d
    local -a extras nodos_vm=()
    base_disco="$(disco_base_cluster)"

    objetivos_cluster
    comprobar_base_no_objetivo
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
        disco="${SILO_DIR}/${PREFIJO_FICHERO}${host}.qcow2"
        extras=()
        while IFS= read -r d; do extras+=( "$d" ); done < <(discos_extra_nodo "$host")

        generar_cloudinit "$vm" "$host" "$ip" nodo
        construir_comando "$vm" "$RAM_MB" "$VCPUS" "$disco" "${extras[@]}"

        echo "→ $vm ($ip): creando $(basename "$disco") y ${#extras[@]} discos extra…"
        crear_disco_cow "$disco" "$base_disco" "$TAM_DISCO"
        for d in "${extras[@]}"; do
            crear_disco_vacio "$d" "$TAM_DISCO_EXTRA"
        done

        echo "→ $vm: creando la máquina…"
        crear_dominio "$vm"
        IP_ESPERADA[$vm]="$ip"
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
# un disco que use otra máquina ni una imagen de la que dependan otras copias.
########################################

# Dominios del usuario (o del prefijo): los que empiezan por PREFIJO-
dominios_propios() {
    local lista d
    lista="$(virsh list --all --name 2>/dev/null || true)"
    while IFS= read -r d; do
        if [[ -n "$d" && "$d" == "${PREFIJO_DOMINIO}-"* ]]; then
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

# Imagen de la que es copia un qcow2 (solo el nombre), o nada
respaldo_de() {   # FICHERO
    local b
    b="$(qemu-img info -U --output=json "$1" 2>/dev/null | jq -r '."backing-filename" // empty' 2>/dev/null || true)"
    if [[ -n "$b" ]]; then
        basename "$b"
    fi
}

# Copias del silo que dependen de un fichero: "a.qcow2, b.qcow2"
copias_de() {   # FICHERO
    local o b res=""
    for o in "$SILO_DIR"/*.qcow2; do
        if [[ ! -f "$o" || "$o" == "$1" ]]; then continue; fi
        b="$(respaldo_de "$o")"
        if [[ -n "$b" && "$b" == "$(basename "$1")" ]]; then
            res+="${res:+, }$(basename "$o")"
        fi
    done
    echo "$res"
}

# Ficheros qcow2 del silo que no usa ninguna de las máquinas del usuario
discos_sin_maquina() {
    local f d usados=""
    for d in $(dominios_propios); do
        usados+="$(discos_de_dominio "$d")"$'\n'
    done
    for f in "$SILO_DIR"/*.qcow2; do
        if [[ -f "$f" ]] && ! grep -qxF "$f" <<< "$usados"; then
            echo "$f"
        fi
    done
}

########################################
# --listar
########################################
listar_maquinas() {
    local d estado ip lista n principal resp desc f dep
    local -a doms=() sueltos=()

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
            lista="$(discos_de_dominio "$d")"
            if [[ -n "$lista" ]]; then
                n="$(grep -c . <<< "$lista" || true)"
                principal="${lista%%$'\n'*}"
                desc="$(basename "$principal")"
                resp="$(respaldo_de "$principal")"
                if [[ -n "$resp" ]]; then desc+=" (copia de $resp)"; fi
                if (( n > 1 )); then desc+=" + $(( n - 1 )) discos extra"; fi
            else
                desc="sin discos en el silo"
            fi
            printf '  %-26s %-13s %-16s %s\n' "$d" "$estado" "$ip" "$desc"
        done
    fi

    while IFS= read -r f; do
        if [[ -n "$f" ]]; then sueltos+=( "$f" ); fi
    done < <(discos_sin_maquina)

    if (( ${#sueltos[@]} > 0 )); then
        echo
        echo "Discos del silo sin máquina:"
        for f in "${sueltos[@]}"; do
            if [[ "$f" == "$BASE_IMG" ]]; then
                desc="imagen cloud de Debian: de ella salen todas las máquinas (no la borres)"
            else
                desc=""
                resp="$(respaldo_de "$f")"
                if [[ -n "$resp" ]]; then desc="copia de $resp"; fi
                dep="$(copias_de "$f")"
                if [[ -n "$dep" ]]; then desc+="${desc:+; }imagen base de: $dep"; fi
                if [[ -z "$desc" ]]; then desc="disco suelto"; fi
            fi
            printf '  %-26s %s\n' "$(basename "$f")" "$desc"
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
    local m vm f d otro habia
    local -a ficheros=()
    ELIM_DOMINIOS=(); ELIM_FICHEROS=(); ELIM_DIRS=(); ELIM_CONSERVADOS=(); ELIM_SIN_NADA=()

    for m in "$@"; do
        vm="${PREFIJO_DOMINIO}-${m}"
        habia=false
        if virsh dominfo "$vm" >/dev/null 2>&1; then
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
        for f in "$SILO_DIR/${PREFIJO_FICHERO}${m}.qcow2" "$SILO_DIR/${PREFIJO_FICHERO}${m}"-vd?.qcow2; do
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

    # Lo que use otra máquina, o de lo que dependan otras copias, se conserva
    OBJ_DOMINIOS=( ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"} )
    OBJ_FICHEROS=( ${ficheros[@]+"${ficheros[@]}"} )
    cargar_dominios_vecinos
    for f in ${ficheros[@]+"${ficheros[@]}"}; do
        if otro="$(dominio_que_usa_disco "$f")"; then
            ELIM_CONSERVADOS+=( "$(basename "$f"): lo usa la máquina '$otro'" )
        elif otro="$(copia_que_depende "$f")"; then
            ELIM_CONSERVADOS+=( "$(basename "$f"): es la imagen base de $(basename "$otro")" )
        else
            ELIM_FICHEROS+=( "$f" )
        fi
    done
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
    local d f otro
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

    # Discos del silo que quedarían sin máquina, salvo la imagen cloud. Aquí se
    # comprueba contra TODOS los dominios del servidor: una máquina con otro
    # prefijo (o de otro usuario) podría estar usando un fichero de este silo.
    for f in "$SILO_DIR"/*.qcow2; do
        if [[ ! -f "$f" || "$f" == "$BASE_IMG" ]]; then continue; fi
        if en_lista "$f" ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"}; then continue; fi
        if [[ -n "$PREFIJO_OPT" && "$(basename "$f")" != "${PREFIJO_OPT}-"* ]]; then continue; fi
        candidatos+=( "$f" )
    done
    if (( ${#candidatos[@]} > 0 )); then
        echo "Comprobando qué discos del silo usa alguna máquina…"
        OBJ_DOMINIOS=( ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"} )
        OBJ_FICHEROS=( ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"} "${candidatos[@]}" )
        cargar_dominios_vecinos todos
        for f in "${candidatos[@]}"; do
            if otro="$(dominio_que_usa_disco "$f")"; then
                ELIM_CONSERVADOS+=( "$(basename "$f"): lo usa la máquina '$otro'" )
            elif otro="$(copia_que_depende "$f")"; then
                ELIM_CONSERVADOS+=( "$(basename "$f"): es la imagen base de $(basename "$otro")" )
            else
                sueltos+=( "$f" )
            fi
        done
    fi

    if ! hay_algo_que_eliminar && (( ${#sueltos[@]} == 0 )); then
        error 22 "No hay nada que eliminar: ni máquinas ${PREFIJO_DOMINIO}-* ni discos sin máquina en $SILO_DIR
(aparte de $(basename "$BASE_IMG"), que se conserva siempre)."
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

# Ejecuta whiptail y devuelve su selección por stdout (whiptail la escribe por
# stderr). Estado: 0 aceptar, 1 cancelar, 255 Esc. Va con locale UTF-8: con
# LC_ALL=C (la del resto del script) whiptail corta los textos en las tildes.
wt() {
    local out rc=0
    out="$(LC_ALL="$LOCALE_UTF8" whiptail --title "ci-provision $VERSION" "$@" 3>&1 1>&2 2>&3)" || rc=$?
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
        sel="$(wt --menu $'¿Qué quieres hacer?\n(muévete con las flechas y elige con Enter)' 20 76 8 \
            basica   "Crear una máquina" \
            server1  "Crear SERVER1 del boletín 2 (IP .2 y seis discos extra)" \
            cluster  "Crear la infraestructura GlusterFS del boletín 2" \
            base     "Crear solo la imagen base GlusterFS" \
            listar   "Ver lo que tengo" \
            eliminar "Eliminar máquinas" \
            todo     "Eliminar todas mis máquinas" \
            salir    "Salir")" || salir_asistente
        case "$sel" in
            basica)   asistente_maquina "" ;;
            server1)  asistente_maquina server1 ;;
            cluster)  asistente_cluster ;;
            base)     asistente_base ;;
            listar)   ejecutar_asistente --directo --listar ;;
            eliminar) asistente_eliminar ;;
            todo)     ejecutar_asistente --eliminar-todo ;;
            *)        salir_asistente ;;
        esac
    done
}

# Opciones marcadas en un checklist → argumentos (la contraseña se pide aparte).
# Deja el resultado en OPCIONES_ARGS; devuelve 1 si se cancela.
OPCIONES_ARGS=()
opciones_a_argumentos() {   # SALIDA_DEL_CHECKLIST
    local o pass
    OPCIONES_ARGS=()
    for o in $(etiquetas "$1"); do
        if [[ "$o" == ssh-pass ]]; then
            pass="$(wt --passwordbox $'Contraseña para administrador\n(solo letras sin tilde, números y signos básicos):' 10 70)" || return 1
            if [[ -z "$pass" ]]; then return 1; fi
            OPCIONES_ARGS+=( --ssh-pass "$pass" )
        else
            OPCIONES_ARGS+=( "--$o" )
        fi
    done
    return 0
}

asistente_maquina() {   # "" (nombre a elegir) o server1
    local preset="$1" nombre ip sugerida libres texto marcado sel
    local -a args=()

    if [[ -n "$preset" ]]; then
        nombre="$preset"
    else
        nombre="$(wt --inputbox $'Nombre corto de la máquina (letras, números y guiones).\nEl dominio será '"${PREFIJO_DOMINIO}"$'-NOMBRE y el disco NOMBRE.qcow2.' 11 70 server1)" || return 0
        if [[ -z "$nombre" ]]; then return 0; fi
    fi

    sugerida=""
    if [[ -n "$preset" ]]; then
        sugerida="$(ip_de_la_red 2)"
    fi
    libres="$(ips_libres_texto)"
    texto="IP fija dentro de tu red virtual. Déjala vacía para usar DHCP."
    if [[ -n "$libres" ]]; then
        texto+=$'\nIPs libres de tu red:\n'"$libres"
    fi
    ip="$(wt --inputbox "$texto" 16 70 "$sugerida")" || return 0

    marcado=off
    if [[ -n "$preset" ]]; then marcado=on; fi
    sel="$(wt --checklist $'Opciones (marca con la barra espaciadora):' 16 76 5 \
        extra-disks    "Seis discos extra vdb..vdg de ${TAM_DISCO_EXTRA}" "$marcado" \
        ssh-pass       "Contraseña para administrador y SSH por contraseña" off \
        no-root        "No habilitar al usuario root" off \
        no-virt-viewer "Sin consola gráfica (virt-viewer)" off \
        limpiar        "Eliminar antes lo que ya exista con esos nombres" off)" || return 0
    opciones_a_argumentos "$sel" || return 0

    args=( ${OPCIONES_ARGS[@]+"${OPCIONES_ARGS[@]}"} "$nombre" )
    if [[ -n "$ip" ]]; then args+=( "$ip" ); fi
    ejecutar_asistente "${args[@]}"
}

asistente_cluster() {
    local base sel
    local -a args=( --gluster-cluster )

    base="${SILO_DIR}/${PREFIJO_FICHERO}${CLUSTER_BASE}.qcow2"
    if [[ -f "$base" ]]; then
        if wt --yesno "Ya tienes $(basename "$base") en el silo."$'\n¿Quieres usarla como imagen base, sin volver a construirla?' 10 70; then
            args+=( --base "$(basename "$base")" )
        fi
    fi

    sel="$(wt --checklist $'Opciones (marca con la barra espaciadora):' 14 76 4 \
        limpiar        "Eliminar antes ${CLUSTER_NODOS[*]} si ya existen" off \
        ssh-pass       "Contraseña para administrador y SSH por contraseña" off \
        no-root        "No habilitar al usuario root" off \
        no-virt-viewer "Sin consola gráfica (virt-viewer)" off)" || return 0
    opciones_a_argumentos "$sel" || return 0

    args+=( ${OPCIONES_ARGS[@]+"${OPCIONES_ARGS[@]}"} )
    ejecutar_asistente "${args[@]}"
}

asistente_base() {
    local nombre
    local -a args=( --glusterfs )

    nombre="$(wt --inputbox $'Nombre de la imagen base.\nQuedará NOMBRE.qcow2 en el silo, sin máquina, lista para hacer copias.' 11 70 "$CLUSTER_BASE")" || return 0
    if [[ -z "$nombre" ]]; then return 0; fi
    if wt --defaultno --yesno $'Si ya existe una máquina o un disco con ese nombre,\n¿eliminarlos antes (--limpiar)?' 9 70; then
        args+=( --limpiar )
    fi
    args+=( "$nombre" )
    ejecutar_asistente "${args[@]}"
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
        wt --msgbox "No tienes máquinas (dominios ${PREFIJO_DOMINIO}-*)."$'\nLos discos sueltos del silo se ven en "Ver lo que tengo" y se eliminan\ncon "Eliminar todas mis máquinas".' 11 72 || true
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
    bash "$0" "$@" || rc=$?
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

VERSION="2.3.0"

########################################
# Configuración general
########################################
SILO_DIR="$HOME/imagenesMV"
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"
BASE_IMG="$SILO_DIR/debian12.qcow2"
# De dónde se descarga si no está en el silo (la misma URL del manual)
BASE_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"

# Usuario del servidor: de él salen los nombres de los dominios y el de la red
USUARIO="$(id -un)"

# Contraseña de consola de 'root' (la misma que usa el manual de laboratorio).
# 'administrador' no tiene contraseña: por SSH se entra con clave; solo con
# --ssh-pass se le da una, y entonces la elige el alumno.
PASS_CONSOLA="s1st3mas"

# Discos
TAM_DISCO_DEFECTO="40G"
TAM_DISCO_EXTRA="40G"
UNIDADES_EXTRA=(vdb vdc vdd vde vdf vdg)          # --extra-disks (apartado A.3.1 del manual)
UNIDADES_CLUSTER=(vdb vdc vdd vde vdf vdg vdh)    # nodos del clúster (apartado A.3.2)

# Clúster GlusterFS (apartado A.3.2 del manual)
CLUSTER_BASE="glusterbase"
CLUSTER_NODOS=(server1 server2 server3 server4)
CLUSTER_IP_INICIAL=10                             # server1 = .10, server2 = .11, ...
CLUSTER_RAM_MB=1024                               # recursos por nodo: los mismos que
CLUSTER_VCPUS=1                                   # usa crea-entorno.sh
CLUSTER_MONTAJES=(/gluster1 /gluster2 /gluster3)  # vdb, vdc y vdd, formateados en xfs
OPCIONES_FSTAB_CLUSTER="auto,async,nofail"        # las mismas líneas de fstab que muestra el manual

# Recursos por defecto de una máquina suelta
RAM_MB_DEFECTO=2048
VCPUS_DEFECTO=2
RAM_MB_MINIMO=512

# Espera a que cloud-init termine (segundos). Se pueden ajustar desde el
# entorno; los tests lo usan para no esperar de verdad.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"          # máximo antes de rendirse
POLL_SECS="${POLL_SECS:-3}"                  # cada cuánto se consulta
GRACE_SECS="${GRACE_SECS:-5}"                # margen si no se puede consultar cloud-init
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-120}"  # apagado limpio de la base del clúster

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
NOMBRES=()          # --eliminar: máquinas a eliminar

RED_OPT=""
DISCO_OPT=""
TAM_DISCO="$TAM_DISCO_DEFECTO"
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
CREACION_COMPLETA=false   # true cuando ya solo queda esperar: a partir de ahí no se deshace nada
SALIDA_CONTROLADA=false   # true si se sale por un error propio (validaciones)
INTERRUMPIDO=false        # true si el usuario pulsa Ctrl-C

########################################
# Carga de librerías
########################################
# Ajusta las rutas si tu estructura es distinta

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

Crea una máquina virtual Debian 12 con cloud-init en tu silo ($SILO_DIR).
De MAQUINA salen el nombre del dominio (${USUARIO}-MAQUINA), el nombre de
host (MAQUINA) y el disco (MAQUINA.qcow2), que el script crea como copia COW
de debian12.qcow2 (si no está en el silo, la descarga). La red virtual se
busca por tu nombre de usuario.

Parámetros:
  MAQUINA              Nombre corto de la máquina (server1, server2, glusterbase, ...)
  IP                   (Opcional) IP fija dentro de tu red virtual. Sin ella, DHCP.

Opciones:
  --extra-disks        Crea y conecta 6 discos extra de ${TAM_DISCO_EXTRA} (vdb..vdg)
  --glusterfs          Construye una imagen base GlusterFS: crea la máquina con
                       glusterfs-server instalado, glusterd habilitado y el
                       machine-id vacío y, al terminar, la apaga y elimina el
                       dominio. Queda solo MAQUINA.qcow2, listo para hacer copias.
  --gluster-cluster    Construye la infraestructura completa del epígrafe 2.4 del
                       boletín 2: la base anterior y ${#CLUSTER_NODOS[@]} nodos (${CLUSTER_NODOS[*]})
                       con IP fija, /etc/hosts, ${#UNIDADES_CLUSTER[@]} discos cada uno y
                       ${CLUSTER_MONTAJES[*]} en xfs. No lleva MAQUINA.
  --base FICHERO       Imagen del silo de la que hacer la copia COW, en lugar de
                       debian12.qcow2 (p.ej. una imagen base GlusterFS que ya
                       tengas). Con --gluster-cluster se omite la fase 1 y los
                       nodos parten de ella.
  --no-root            No habilita al usuario root (queda sin contraseña, como en
                       las máquinas que se crean a mano)
  --no-virt-viewer     No habilita la consola gráfica (virt-viewer). La consola de
                       texto (virsh console) sigue funcionando.
  --limpiar            Si ya existen los dominios o discos que el script va a
                       crear, los elimina antes (solo esos; nada más), previa
                       confirmación
  --red NOMBRE         Red virtual a usar (por defecto se busca ${USUARIO}-red)
  --prefijo PREFIJO    Sustituye a tu usuario en los nombres: dominio PREFIJO-MAQUINA
                       y, en ese caso, también los discos (PREFIJO-MAQUINA.qcow2)
  --disco NOMBRE       Nombre del disco principal (por defecto MAQUINA.qcow2)
  --tam TAMAÑO         Tamaño del disco principal (por defecto ${TAM_DISCO_DEFECTO})
  --ram MB             Memoria (por defecto ${RAM_MB_DEFECTO}; en el clúster, ${CLUSTER_RAM_MB} por nodo)
  --vcpus N            vCPUs (por defecto ${VCPUS_DEFECTO}; en el clúster, ${CLUSTER_VCPUS} por nodo)
  --ssh-pass CONTRASEÑA
                       Da esa contraseña a 'administrador' y permite entrar por SSH
                       escribiéndola (sin --ssh-pass, por SSH solo se entra con tu
                       clave pública). Solo caracteres ASCII.
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
  - Usuario 'root' con contraseña '${PASS_CONSOLA}', solo para la consola
    (virsh console o virt-viewer); por SSH no puede entrar. Con --no-root,
    sin contraseña.
  - Consola gráfica activa (virt-viewer), salvo con --no-virt-viewer.

Ejemplos (XXX es el tercer número de tu red virtual; lo ves en el resumen de --dry-run):
  $0 server1                                    # DHCP
  $0 --extra-disks server1 192.168.XXX.2        # SERVER1 del boletín 2, epígrafe 2.1
  $0 --gluster-cluster                          # infraestructura del boletín 2, epígrafe 2.4
  $0 --glusterfs glusterbase                    # solo la imagen base GlusterFS
  $0 --gluster-cluster --base glusterbase.qcow2 # la infraestructura a partir de esa imagen
  $0 --dry-run --extra-disks server1 192.168.XXX.2   # solo comprobar
EOF
}

########################################
# Parseo de opciones
########################################
parse_args() {
    local args=()

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
            --listar)          LISTAR=true;        shift ;;
            --eliminar)        ELIMINAR=true;      shift ;;
            --eliminar-todo)   ELIMINAR_TODO=true; shift ;;
            --menu)            MENU=true;          shift ;;
            --version)
                echo "ci-provision.sh $VERSION"
                exit 0
                ;;
            --red|--disco|--base|--tam|--ram|--vcpus|--ssh-pass|--prefijo)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    error 11 "Falta el valor de la opción $1. Escríbelo a continuación, separado por un espacio: $1 VALOR"
                fi
                if [[ -z "$2" ]]; then
                    error 11 "La opción $1 no admite un valor vacío."
                fi
                case "$1" in
                    --red)      RED_OPT="$2"   ;;
                    --disco)    DISCO_OPT="$2" ;;
                    --base)     BASE_OPT="$2"  ;;
                    --tam)      TAM_DISCO="$2" ;;
                    --ram)      RAM_OPT="$2"   ;;
                    --vcpus)    VCPUS_OPT="$2" ;;
                    --ssh-pass) SSH_PASS="$2"  ;;
                    --prefijo)  PREFIJO_OPT="$2" ;;
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
                error 12 "La opción --user-pass ha sido sustituida por --ssh-pass CONTRASEÑA.
Sin ella, 'administrador' ya tiene contraseña de consola (${PASS_CONSOLA}) y por SSH se entra con clave."
                ;;
            --)
                shift
                args+=("$@")
                break
                ;;
            --*=*)
                error 12 "La opción '${1%%=*}' se escribe con un espacio, no con '=': ${1%%=*} ${1#*=}"
                ;;
            -*)
                error 12 "Opción desconocida '$1'. Consulta la ayuda con -h."
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    ########################################
    # Parámetros posicionales
    ########################################
    ########################################
    # Modos de gestión: --listar, --eliminar, --eliminar-todo
    ########################################
    local modos=0 m
    for m in $CLUSTER $LISTAR $ELIMINAR $ELIMINAR_TODO $MENU; do
        if [[ "$m" == true ]]; then modos=$(( modos + 1 )); fi
    done
    if (( modos > 1 )); then
        error 10 "--gluster-cluster, --listar, --eliminar, --eliminar-todo y --menu son modos distintos: usa solo uno."
    fi
    if $LISTAR || $ELIMINAR || $ELIMINAR_TODO || $MENU; then
        if $EXTRA_DISKS || $GLUSTERFS || $LIMPIAR || $NO_WAIT || $NO_ROOT || $NO_GRAFICOS || \
           [[ -n "$RED_OPT$DISCO_OPT$BASE_OPT$RAM_OPT$VCPUS_OPT$SSH_PASS" ]] || [[ "$TAM_DISCO" != "$TAM_DISCO_DEFECTO" ]]; then
            error 10 "Con --listar, --eliminar, --eliminar-todo y --menu solo se admiten --prefijo y --dry-run."
        fi
        if $ELIMINAR; then
            if (( ${#args[@]} == 0 )); then
                error 10 "Falta el nombre de la máquina a eliminar: $0 --eliminar MAQUINA [MAQUINA...]
(p.ej. $0 --eliminar server1). Para ver las que tienes: $0 --listar"
            fi
            NOMBRES=( "${args[@]}" )
            local pref="${PREFIJO_OPT:-$USUARIO}"
            for m in "${NOMBRES[@]}"; do
                if ! [[ "$m" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
                    error 20 "El nombre de máquina '$m' no es válido. Solo letras, números y guiones (p.ej. server1)."
                fi
                if [[ "${m,,}" == "${pref,,}-"* ]]; then
                    error 20 "Indica solo el nombre corto de la máquina, sin '$pref-' delante: '${m#"${m%%-*}-"}' en vez de '$m'."
                fi
            done
        elif (( ${#args[@]} > 0 )); then
            error 10 "--listar, --eliminar-todo y --menu no llevan MAQUINA (sobra: '${args[*]}')."
        fi
    fi

    if $GLUSTERFS && $NO_WAIT; then
        error 10 "--no-wait no se puede combinar con --glusterfs: la base hay que apagarla
cuando cloud-init termine, así que es imprescindible esperar."
    fi

    if $CLUSTER; then
        if (( ${#args[@]} > 0 )); then
            error 10 "Con --gluster-cluster no se indica MAQUINA ni IP: los nombres (${CLUSTER_BASE}, ${CLUSTER_NODOS[*]}) y las IPs (.${CLUSTER_IP_INICIAL} en adelante) son fijos."
        fi
        if [[ -n "$DISCO_OPT" ]]; then
            error 10 "La opción --disco no se aplica a --gluster-cluster: los discos se llaman como los nodos."
        fi
        if $GLUSTERFS || $EXTRA_DISKS; then
            error 10 "--gluster-cluster ya construye la imagen base y los ${#UNIDADES_CLUSTER[@]} discos de cada nodo:
no se combina con --glusterfs ni con --extra-disks."
        fi
    elif $LISTAR || $ELIMINAR || $ELIMINAR_TODO || $MENU; then
        :
    else
        if (( ${#args[@]} == 0 )); then
            error 10 "Falta el nombre de la máquina.
Uso: $0 [opciones] MAQUINA [IP]      (p.ej. $0 server1)
Consulta la ayuda con -h. En el servidor de la asignatura también puedes
ejecutarlo sin argumentos desde una terminal: se abre un asistente con menús."
        fi
        if (( ${#args[@]} > 2 )); then
            error 10 "Sobran parámetros: '${args[*]}'.
Parece la sintaxis de la versión anterior. Ahora solo se indica el nombre corto
de la máquina y, opcionalmente, la IP; el disco y la red se deducen de tu usuario:
  $0 [opciones] MAQUINA [IP]      (p.ej. $0 --extra-disks server1 192.168.XXX.2)
Consulta la ayuda con -h."
        fi
        MAQUINA="${args[0]}"
        IP="${args[1]:-}"

        # De MAQUINA sale el hostname, así que solo se admiten caracteres válidos
        # en un nombre de host
        if ! [[ "$MAQUINA" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || (( ${#MAQUINA} > 63 )); then
            error 20 "El nombre de máquina '$MAQUINA' no es válido.
Solo letras, números y guiones, empezando por letra o número (p.ej. server1, gluster-base)."
        fi

        # El usuario (o el prefijo) lo antepone el script: 'usuario-server1'
        # daría 'usuario-usuario-server1', que nadie quiere
        local pref="${PREFIJO_OPT:-$USUARIO}"
        if [[ "${MAQUINA,,}" == "${pref,,}-"* ]]; then
            error 20 "El nombre de máquina '$MAQUINA' ya empieza por '$pref-': el dominio sería '${pref}-${MAQUINA}'.
Indica solo el nombre corto (p.ej. '${MAQUINA#"${MAQUINA%%-*}-"}'); '$pref-' lo antepone el script."
        fi

        if $GLUSTERFS && $EXTRA_DISKS; then
            error 10 "--extra-disks no se combina con --glusterfs: la imagen base es un solo disco,
que es lo único que queda al terminar. Los discos extra se crean al hacer las copias
(p.ej. --gluster-cluster, o --extra-disks --base ${MAQUINA}.qcow2 server1)."
        fi
        if $GLUSTERFS && [[ -n "$IP" ]]; then
            error 10 "Con --glusterfs no se indica IP: la máquina es provisional (se elimina al terminar)
y la IP la reciben las copias que hagas de ${MAQUINA}.qcow2."
        fi
    fi

    ########################################
    # Recursos: por defecto según el modo
    ########################################
    if $CLUSTER; then
        RAM_MB="${RAM_OPT:-$CLUSTER_RAM_MB}"
        VCPUS="${VCPUS_OPT:-$CLUSTER_VCPUS}"
    else
        RAM_MB="${RAM_OPT:-$RAM_MB_DEFECTO}"
        VCPUS="${VCPUS_OPT:-$VCPUS_DEFECTO}"
    fi

    if ! [[ "$RAM_MB" =~ ^[0-9]+$ ]] || (( RAM_MB < RAM_MB_MINIMO )); then
        error 13 "La memoria RAM '$RAM_MB' no es válida. Debe ser un número de MB igual o mayor que ${RAM_MB_MINIMO}."
    fi

    if ! [[ "$VCPUS" =~ ^[0-9]+$ ]] || (( VCPUS < 1 )); then
        error 13 "El número de vCPUs '$VCPUS' no es válido. Debe ser un número igual o mayor que 1."
    fi

    if ! [[ "$TAM_DISCO" =~ ^[0-9]+[MGT]$ ]]; then
        error 15 "El tamaño de disco '$TAM_DISCO' no es válido. Indícalo como 40G, 20G, 512M..."
    fi

    if [[ -n "$DISCO_OPT" ]] && ! [[ "$DISCO_OPT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        error 16 "El nombre de disco '$DISCO_OPT' no es válido. Indica solo el nombre del fichero (sin rutas), p.ej. server1.qcow2."
    fi

    if [[ -n "$BASE_OPT" ]]; then
        if ! [[ "$BASE_OPT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            error 16 "El nombre de imagen '$BASE_OPT' (--base) no es válido. Indica solo el nombre del fichero del silo (sin rutas), p.ej. glusterbase.qcow2."
        fi
        BASE_IMG="${SILO_DIR}/${BASE_OPT}"
    fi

    if [[ -n "$PREFIJO_OPT" ]] && ! [[ "$PREFIJO_OPT" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
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

    ########################################
    # Derivados
    ########################################
    # Sin --prefijo: dominio USUARIO-MAQUINA y ficheros MAQUINA.qcow2, como en el
    # manual. Con él, el prefijo va también en los ficheros, para que dos juegos
    # de máquinas convivan en el mismo silo sin pisarse.
    PREFIJO_DOMINIO="${PREFIJO_OPT:-$USUARIO}"
    PREFIJO_FICHERO="${PREFIJO_OPT:+${PREFIJO_OPT}-}"
    if ! $CLUSTER; then
        VM_NAME="${PREFIJO_DOMINIO}-${MAQUINA}"
        HOST_NAME="$MAQUINA"
        DISCO_MAIN="${SILO_DIR}/${DISCO_OPT:-${PREFIJO_FICHERO}${MAQUINA}.qcow2}"
    fi
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
        --os-variant debian12
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
    if $BASE_IMG_FALTA; then
        echo "    Imagen  : $(basename "$BASE_IMG") no está en el silo; se descargará de"
        echo "              $BASE_IMG_URL"
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
print_summary() {
    local vm_ip="${IPS_DETECTADAS[$VM_NAME]:-}"
    local ip_mostrar

    if [[ -n "$IP" ]]; then
        ip_mostrar="$IP (fija)"
    elif [[ -n "$vm_ip" ]]; then
        ip_mostrar="$vm_ip (DHCP)"
    else
        ip_mostrar="(DHCP; consúltala con: virsh domifaddr $VM_NAME --source agent)"
    fi

    echo "-------------------------------------------"
    echo "Máquina      : $VM_NAME  (hostname: $HOST_NAME)"
    echo "Disco        : $DISCO_MAIN ($TAM_DISCO)"
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
    echo "  ssh administrador@${IP:-${vm_ip:-IP}}        con tu clave pública"
    if [[ -n "$SSH_PASS" ]]; then
        echo "                                        (o con la contraseña: $SSH_PASS)"
    fi
    if $NO_ROOT; then
        echo "  virsh console $VM_NAME        (root sin contraseña: --no-root)"
    else
        echo "  virsh console $VM_NAME        root, contraseña: $PASS_CONSOLA"
    fi
    if ! $NO_GRAFICOS; then
        echo "  virt-viewer --connect qemu+ssh://${USUARIO}@$(servidor_fqdn)/system $VM_NAME"
    fi
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
    echo "Disco        : $DISCO_MAIN ($TAM_DISCO)"
    echo "Contenido    : Debian 12 con glusterfs-server instalado (y las herramientas para"
    echo "               formatear en xfs), glusterd habilitado, zona horaria Europe/Madrid"
    echo "               y machine-id vacío"
    echo "Dominio      : $VM_NAME se ha eliminado; solo queda el disco"
    echo
    echo "Úsalo como respaldo de las copias COW de tus nodos, por ejemplo:"
    echo "  qemu-img create -f qcow2 -b $(basename "$DISCO_MAIN") -F qcow2 server1.qcow2 40G"
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
ejecutar_maquina() {
    local modo="normal"
    local -a extras=()
    local unidad disco

    if $GLUSTERFS; then
        modo="gluster"
    fi

    if $EXTRA_DISKS; then
        for unidad in "${UNIDADES_EXTRA[@]}"; do
            extras+=( "${SILO_DIR}/${PREFIJO_FICHERO}${MAQUINA}-${unidad}.qcow2" )
        done
        for disco in "${extras[@]}"; do
            if [[ "$disco" == "$DISCO_MAIN" ]]; then
                error 16 "El nombre de disco '$(basename "$DISCO_MAIN")' coincide con uno de los discos extra que se crearían.
Elige otro nombre para el disco principal."
            fi
        done
    fi

    # Conflictos con lo que ya exista (y --limpiar, si se pidió)
    OBJ_DOMINIOS=( "$VM_NAME" )
    OBJ_FICHEROS=( "$DISCO_MAIN" ${extras[@]+"${extras[@]}"} )
    comprobar_base_no_objetivo
    comprobar_conflictos

    generar_cloudinit "$VM_NAME" "$HOST_NAME" "$IP" "$modo"
    construir_comando "$VM_NAME" "$RAM_MB" "$VCPUS" "$DISCO_MAIN" ${extras[@]+"${extras[@]}"}

    ########################################
    # Modo simulación: nada de lo de abajo se ejecuta
    ########################################
    if $DRY_RUN; then
        echo "→ MODO SIMULACIÓN (--dry-run): no se creará ninguna máquina."
        echo
        echo "✔ Validaciones superadas."
        echo "    Usuario : $USUARIO"
        echo "    Red     : $NET_NAME (pasarela $NET_GATEWAY, prefijo /$NET_PREFIX)"
        if [[ -n "$IP" ]]; then
            echo "    IP      : $IP, disponible para asignación fija"
        else
            echo "    IP      : por DHCP"
        fi
        avisar_imagen_falta
        echo
        echo "✔ Ficheros cloud-init generados en $WORKDIR/"
        echo
        echo "Discos que se crearían en $SILO_DIR:"
        echo "    $(basename "$DISCO_MAIN")  (copia COW de $(basename "$BASE_IMG"), $TAM_DISCO)"
        for disco in ${extras[@]+"${extras[@]}"}; do
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
        return 0
    fi

    # Base GlusterFS: se construye, se apaga y se elimina el dominio
    if $GLUSTERFS; then
        crear_base_gluster "$VM_NAME" "$HOST_NAME" "$DISCO_MAIN"
        CREACION_COMPLETA=true
        print_summary_base
        return 0
    fi

    echo "→ Creando el disco $(basename "$DISCO_MAIN") (copia COW de $(basename "$BASE_IMG"), $TAM_DISCO)…"
    crear_disco_cow "$DISCO_MAIN" "$BASE_IMG" "$TAM_DISCO"

    for disco in ${extras[@]+"${extras[@]}"}; do
        echo "→ Creando el disco extra $(basename "$disco") ($TAM_DISCO_EXTRA)…"
        crear_disco_vacio "$disco" "$TAM_DISCO_EXTRA"
    done

    echo "→ Creando la máquina '$VM_NAME' con cloud-init…"
    crear_dominio "$VM_NAME"
    CREACION_COMPLETA=true
    echo "✔ Máquina creada y arrancada."
    echo "-------------------------------------------"

    if [[ -n "$IP" ]]; then
        IP_ESPERADA[$VM_NAME]="$IP"
    fi

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
