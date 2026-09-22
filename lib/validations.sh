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
    local xml pista
    pista=$'\n'"Revisa su definición con: virsh net-dumpxml $NET_NAME"$'\n'"Si no ves el problema, avisa a tu profesor con esa salida."
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
        error 41 "La IP '$ip' no es una dirección IPv4 válida (cuatro números de 0 a 255 separados por puntos).
Pasarela : ${NET_GATEWAY}
IPs libres para asignación fija:
$(free_ip_blocks)

También puedes omitir el parámetro IP para que la máquina use DHCP."
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
        # Sin -U, qemu-img se niega si otra máquina tiene la imagen abierta para
        # escribir: entonces no sirve de base (las copias saldrían corruptas)
        if ! qemu-img info --output=json "$BASE_IMG" >/dev/null 2>&1 && qemu-img info "$BASE_IMG" 2>&1 | grep -qi 'lock'; then
            error 39 "La imagen $BASE_IMG la tiene abierta para escribir una máquina en ejecución.
Apágala (o elimina su dominio) antes de usarla como imagen base: las copias de un disco
que se está escribiendo quedarían corruptas."
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

    # Antes de la descarga, que cuesta tiempo: qué se va a crear y si choca
    # con algo existente. Con --limpiar, la eliminación se hace después, en su sitio.
    calcular_objetivos
    comprobar_base_no_objetivo
    comprobar_conflictos solo-detectar

    # La imagen base, en último lugar: si falta hay que descargarla, y no
    # tiene sentido hacerlo para fallar después por un dato mal escrito
    comprobar_imagen_base
    comprobar_tam_disco
}
