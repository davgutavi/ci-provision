########################################
# Datos de la red virtual (se rellenan en load_network_info)
########################################
NET_GATEWAY=""
NET_NETMASK=""
NET_PREFIX=""
NET_DOMAIN=""
NET_DHCP_STARTS=()
NET_DHCP_ENDS=()
NET_RESERVED=()

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

    # Nombre de dominio de la red (puede no existir)
    local domline
    domline="$(printf '%s\n' "$xml" | grep -E '<domain[[:space:]]' | head -n1 || true)"
    if [[ -n "$domline" ]]; then
        NET_DOMAIN="$(xml_attr "$domline" name)"
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
    local neti="$1" bcasti="$2"
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

# Valida la IP fija solicitada contra la configuración real de la red
validate_static_ip() {
    [[ -z "$IP" ]] && return 0

    if ! valid_ipv4 "$IP"; then
        error 41 "La IP '$IP' no es una dirección IPv4 válida."
    fi

    local ipi gwi maski neti bcasti
    ipi="$(ip_to_int "$IP")"
    gwi="$(ip_to_int "$NET_GATEWAY")"
    maski=$(( 0xFFFFFFFF ^ ((1 << (32 - NET_PREFIX)) - 1) ))
    neti=$(( gwi & maski ))
    bcasti=$(( neti | (~maski & 0xFFFFFFFF) ))

    if (( (ipi & maski) != neti )); then
        error 41 "La IP '$IP' no pertenece a la red '$NET_NAME'.
Red      : $(int_to_ip "$neti")/${NET_PREFIX}
Pasarela : ${NET_GATEWAY}
IPs libres para asignación fija:
$(free_ip_blocks "$neti" "$bcasti")"
    fi

    if (( ipi == neti || ipi == bcasti )); then
        error 41 "La IP '$IP' es la dirección de red o la de difusión de '$NET_NAME'. No se puede asignar a una máquina."
    fi

    if (( ipi == gwi )); then
        error 41 "La IP '$IP' es la pasarela de la red '$NET_NAME'. Elige otra."
    fi

    # Dentro de algún rango DHCP
    local i si ei
    for (( i = 0; i < ${#NET_DHCP_STARTS[@]}; i++ )); do
        si="$(ip_to_int "${NET_DHCP_STARTS[$i]}")"
        ei="$(ip_to_int "${NET_DHCP_ENDS[$i]}")"
        if (( ipi >= si && ipi <= ei )); then
            error 42 "La IP '$IP' está dentro del rango DHCP de la red '$NET_NAME' (${NET_DHCP_STARTS[$i]} - ${NET_DHCP_ENDS[$i]}).
Si se la asignas de forma fija, el servidor DHCP puede entregársela a otra máquina.
Pasarela : ${NET_GATEWAY}
IPs libres para asignación fija:
$(free_ip_blocks "$neti" "$bcasti")

También puedes omitir el parámetro IP para que la máquina use DHCP."
        fi
    done

    # Coincide con una reserva estática
    for (( i = 0; i < ${#NET_RESERVED[@]}; i++ )); do
        if [[ "$IP" == "${NET_RESERVED[$i]}" ]]; then
            error 42 "La IP '$IP' ya está reservada por MAC en la red '$NET_NAME'.
IPs libres para asignación fija:
$(free_ip_blocks "$neti" "$bcasti")"
        fi
    done
}

########################################
# Validaciones generales (entorno, disco, red, opciones)
########################################
validate_environment() {

    # Herramientas necesarias
    require_commands qemu-img virsh virt-install jq

    # Silo existente
    if [[ ! -d "$SILO_DIR" ]]; then
        error 30 "No existe el silo en: $SILO_DIR"
    fi

    # Imagen base existente
    if [[ ! -f "$BASE_IMG" ]]; then
        error 37 "No se encuentra la imagen base '$BASE_IMG'.
Descárgala y guárdala como debian12.qcow2 en el silo."
    fi

    # Clave pública existente
    if [[ ! -f "$PUBKEY_PATH" ]]; then
        error 31 "No existe la clave pública en $PUBKEY_PATH. Genera una con: ssh-keygen"
    fi

    # Disco en silo (resolver ruta y normalizarla)
    if [[ "$DISK_ARG" = /* ]]; then
        DISK_PATH="$DISK_ARG"
    else
        DISK_PATH="$SILO_DIR/$DISK_ARG"
    fi

    if [[ ! -f "$DISK_PATH" ]]; then
        error 32 "El disco no existe: $DISK_PATH"
    fi

    # Se normaliza la ruta para que '..' no permita salirse del silo
    local SILO_REAL
    DISK_PATH="$(realpath "$DISK_PATH")"
    SILO_REAL="$(realpath "$SILO_DIR")"

    case "$DISK_PATH" in
        "$SILO_REAL"/*) ;;
        *)
            error 33 "El disco debe estar dentro del silo: $SILO_DIR"
            ;;
    esac

    ########################################
    # Comprobaciones del disco con qemu-img
    #
    # Se usa la salida JSON en lugar de la de texto: 'actual-size' viene en
    # bytes exactos, con lo que no hay que interpretar unidades (KiB/MiB/GiB)
    # ni depender de 'bc'.
    ########################################
    local INFO
    if ! INFO="$(qemu-img info --output=json "$DISK_PATH" 2>/dev/null)"; then
        error 34 "No se ha podido obtener información con 'qemu-img info' sobre $DISK_PATH"
    fi

    local FILE_FMT BACKING_NAME BACKING_FMT ACTUAL_SIZE
    FILE_FMT="$(printf '%s' "$INFO"    | jq -r '.format // empty')"
    BACKING_NAME="$(printf '%s' "$INFO" | jq -r '."backing-filename" // empty')"
    BACKING_FMT="$(printf '%s' "$INFO"  | jq -r '."backing-filename-format" // empty')"
    ACTUAL_SIZE="$(printf '%s' "$INFO"  | jq -r '."actual-size" // 0')"

    if [[ "$FILE_FMT" != "qcow2" ]]; then
        error 34 "El disco $DISK_PATH no es qcow2 (file format: ${FILE_FMT:-desconocido})."
    fi

    if [[ -z "$BACKING_NAME" ]]; then
        error 34 "El disco $DISK_PATH no parece ser una copia COW (no tiene 'backing file')."
    fi

    if [[ "$BACKING_FMT" != "qcow2" ]]; then
        error 34 "El disco $DISK_PATH no parece una copia COW de otra imagen qcow2 (backing file format: ${BACKING_FMT:-desconocido})."
    fi

    if [[ "$(basename "$BACKING_NAME")" != "$(basename "$BASE_IMG")" ]]; then
        error 35 "El disco $DISK_PATH no está haciendo COW sobre $(basename "$BASE_IMG").
Backing actual: $BACKING_NAME
Esperado: $(basename "$BASE_IMG")

Vuelve a crear el disco con:
  qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 NOMBRE.qcow2 40G"
    fi

    if (( ACTUAL_SIZE > DISK_REUSE_MAX_BYTES )); then
        error 36 "El disco $DISK_PATH parece reutilizado: ocupa $ACTUAL_SIZE bytes, más del máximo admitido ($DISK_REUSE_MAX_BYTES bytes).
Un disco recién creado ocupa unos 200 KB.

Crea un disco nuevo con:
  qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 NOMBRE.qcow2 40G"
    fi

    # Red: se leen sus datos reales y se valida la IP contra ellos
    load_network_info
    validate_static_ip

    # VALIDACIÓN LÓGICA: virt-viewer requiere contraseña de admin o root habilitado
    if $ENABLE_GRAPHICS; then
        if [[ -z "$USER_PASS" && $ENABLE_ROOT = false ]]; then
            error 50 "Para usar --virt-viewer debes habilitar acceso por consola.
Usa al menos una de estas opciones:
  --user-pass PASSWORD
  --enable-root"
        fi
    fi

    # Pre-check de discos extra: si se van a crear, comprobar que no existan
    if $EXTRA_DISKS; then
        local maquina
        maquina="${VM_NAME#*-}"
        for unidad in vdb vdc vdd vde vdf vdg; do
            local ruta_extra="${SILO_DIR}/${maquina}-${unidad}.qcow2"
            if [[ -e "$ruta_extra" ]]; then
                error 60 "El disco extra '$ruta_extra' ya existe. Elimínalo o usa otro nombre de dominio."
            fi
        done
    fi
}
