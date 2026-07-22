#!/bin/bash
set -euo pipefail

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

# Extrae el valor de un atributo XML de una línea (atributos entre comillas simples)
xml_attr() {
    printf '%s' "$1" | sed -n "s/.*[[:space:]]$2='\([^']*\)'.*/\1/p"
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

    # Bloque <ip> de IPv4 (se descartan los de IPv6)
    local ipline
    ipline="$(printf '%s\n' "$xml" | grep -E '<ip[[:space:]]' | grep -v "family='ipv6'" | head -n1)"
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

########################################
# Generación de ficheros cloud-init
########################################
generate_cloudinit_files() {
    local vm="$1"
    local host="$2"

    WORKDIR="./cloudinit-${vm}"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    # Estos ficheros contienen contraseñas en texto plano y el servidor de la
    # asignatura es multiusuario: solo su propietario debe poder leerlos.
    chmod 700 "$WORKDIR"

    USER_DATA="$WORKDIR/cip-user.yaml"
    META_DATA="$WORKDIR/cip-meta.yaml"

    ########################################
    # meta-data
    ########################################
    cat > "$META_DATA" <<EOF
instance-id: ${vm}
local-hostname: ${host}
EOF

    ########################################
    # Construcción de lista de contraseñas
    ########################################
    local chpass_list=""
    local ssh_pwauth=false

    if [[ -n "$USER_PASS" ]]; then
        chpass_list+="administrador:${USER_PASS}"$'\n'
        ssh_pwauth=true
    fi

    if $ENABLE_ROOT; then
        chpass_list+="root:s1st3mas"$'\n'
    fi

    ########################################
    # user-data
    ########################################
    {
        echo "#cloud-config"
        echo "users:"
        echo "  - name: administrador"
        echo "    groups: [sudo]"
        echo "    shell: /bin/bash"
        echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']"
        echo "    ssh-authorized-keys:"
        echo "      - $(cat "$PUBKEY_PATH")"

        if [[ -n "$chpass_list" ]]; then
            if $ssh_pwauth; then
                echo "ssh_pwauth: true"
            fi
            echo "chpasswd:"
            echo "  list: |"
            while IFS= read -r line; do
                [[ -n "$line" ]] && echo "    $line"
            done <<< "$chpass_list"
            echo "  expire: false"
        fi

        echo "package_update: true"
        echo "packages:"
        echo "  - qemu-guest-agent"
        if $GLUSTERFS; then
            echo "  - glusterfs-server"
        fi

        echo "runcmd:"
        echo "  - timedatectl set-timezone Europe/Madrid"
        echo "  - systemctl start qemu-guest-agent"

        if $GLUSTERFS; then
            # Solo habilitamos glusterd (no se arranca, solo enable)
            echo "  - systemctl enable glusterd"
            # Reset de machine-id para poder clonar sin conflictos
            echo "  - truncate -s 0 /etc/machine-id"
        fi
    } > "$USER_DATA"

    chmod 600 "$USER_DATA" "$META_DATA"

    ########################################
    # network-config (solo si IP estática)
    ########################################
    # La pasarela y el prefijo se toman de la configuración real de la red
    # (ver load_network_info), no de una suposición sobre la IP indicada.
    # Se usa la forma 'routes:' en lugar de la obsoleta 'gateway4:' para que
    # coincida con la plantilla que se enseña en el manual de laboratorio.
    if [[ -n "$IP" ]]; then
        NETWORK_DATA="$WORKDIR/cip-net.yaml"

        cat > "$NETWORK_DATA" <<EOF
version: 2
ethernets:
  enp1s0:
    addresses:
      - ${IP}/${NET_PREFIX}
    routes:
      - to: default
        via: ${NET_GATEWAY}
    nameservers:
      addresses:
        - 150.214.186.69
        - 150.214.130.15
EOF
        chmod 600 "$NETWORK_DATA"
    else
        NETWORK_DATA=""
    fi
}
########################################
# Adjuntar discos extra vdb..vdg
########################################
attach_extra_disks() {
    local dominio="$1"
    local maquina="${dominio#*-}"

    echo "Añadiendo discos extra al dominio: $dominio"
    echo "Prefijo: $maquina"
    echo "Silo: $SILO_DIR"
    echo

    for unidad in vdb vdc vdd vde vdf vdg; do
        local nombre_img="${maquina}-${unidad}.qcow2"
        local ruta_img="${SILO_DIR}/${nombre_img}"

        echo "→ Creando: $ruta_img"
        qemu-img create "$ruta_img" -f qcow2 40G

        echo "→ Adjuntando como $unidad"
        virsh attach-disk "$dominio" "$ruta_img" "$unidad" \
            --driver qemu --subdriver qcow2 --targetbus virtio \
            --persistent --live
        echo "Disk attached successfully"
        echo
    done

    echo "✔ Discos extra añadidos correctamente."
    echo
}

# Salidas de las herramientas en formato neutro, independiente del idioma
# configurado en el servidor.
export LC_ALL=C

########################################
# Configuración general
########################################
SILO_DIR="$HOME/imagenesMV"
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"
BASE_IMG="$SILO_DIR/debian12.qcow2"

# Umbral para considerar que un disco ya ha sido usado (en bytes)
# 1048576 bytes = 1 MiB. Un disco recién creado ocupa unos 200 KB.
# Si cambias este valor, revisa si quieres ajustar también el mensaje de
# error 36 para que siga siendo coherente.
DISK_REUSE_MAX_BYTES=1048576

# Tiempos de espera por defecto (en segundos)
SLEEP_NO_GLUSTER=50      # sin --glusterfs
SLEEP_WITH_GLUSTER=80    # con --glusterfs
SLEEP_SECS="$SLEEP_NO_GLUSTER"

# Permite saltarse la espera final
NO_WAIT=false

########################################
# Variables de opciones (por defecto)
########################################
USER_PASS=""
ENABLE_ROOT=false
ENABLE_GRAPHICS=false
EXTRA_DISKS=false
GLUSTERFS=false

VM_NAME=""
DISK_ARG=""
DISK_PATH=""
HOSTNAME=""
NET_NAME=""
IP=""
RAM_MB=2048
VCPUS=2

WORKDIR=""
USER_DATA=""
META_DATA=""
NETWORK_DATA=""

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
    echo "ERROR [$code] $*" >&2
    exit "$code"
}

########################################
# Función de ayuda
########################################
print_help() {
    cat <<EOF
Uso:
  $0 [opciones] NOMBRE_VM DISCO HOSTNAME RED [IP] [RAM_MB] [VCPUS]

Opciones:
  --user-pass PASS     Establece contraseña para el usuario 'administrador'
  --enable-root        Habilita root SOLO por consola (contraseña: s1st3mas)
  --virt-viewer        Habilita gráficos para virt-viewer
  --extra-disks        Crea y adjunta discos extra vdb..vdg en el silo
  --glusterfs          Prepara la VM como nodo GlusterFS (glusterfs-server + enable glusterd + reset de machine-id)
  --no-wait            No esperar tras crear la VM (omite la pausa final)
  -h, --help           Muestra esta ayuda

Parámetros:
  NOMBRE_VM            Nombre del dominio en libvirt (p.ej., alu345-server1)
  DISCO                Archivo .qcow2 (debe estar dentro del silo)
  HOSTNAME             Nombre interno de la máquina
  RED                  Nombre de la red virtual
  IP                   (Opcional) IP fija (si no → DHCP)
  RAM_MB               (Opcional) Memoria en MB (por defecto 2048)
  VCPUS                (Opcional) Núcleos de CPU (por defecto 2)
EOF
}

########################################
# Parseo de opciones
########################################
parse_args() {
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user-pass)
                [[ $# -lt 2 ]] && error 11 "Falta el valor para --user-pass"
                USER_PASS="$2"
                shift 2
                ;;
            --enable-root)
                ENABLE_ROOT=true
                shift
                ;;
            --virt-viewer)
                ENABLE_GRAPHICS=true
                shift
                ;;
            --extra-disks)
                EXTRA_DISKS=true
                shift
                ;;
            --glusterfs)
                GLUSTERFS=true
                shift
                ;;
            --no-wait)
                NO_WAIT=true
                shift
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            --)
                shift
                args+=("$@")
                break
                ;;
            -*)
                error 12 "Opción desconocida '$1'"
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # Mínimo 4 argumentos obligatorios
    if (( ${#args[@]} < 4 )); then
        error 10 "Faltan parámetros obligatorios."
    fi

    VM_NAME="${args[0]}"
    DISK_ARG="${args[1]}"
    HOSTNAME="${args[2]}"
    NET_NAME="${args[3]}"

    # IP opcional
    if (( ${#args[@]} >= 5 )); then
        IP="${args[4]}"
    fi

    # RAM opcional
    if (( ${#args[@]} >= 6 )); then
        RAM_MB="${args[5]}"
    fi

    # CPUs opcional
    if (( ${#args[@]} >= 7 )); then
        VCPUS="${args[6]}"
    fi

    # Comprobación de formato del nombre de dominio: usuario-maquina
    # Se admiten guiones adicionales en la parte de la máquina (p.ej.,
    # alu345-gluster-base) pero no barras ni puntos, porque el nombre se usa
    # para construir el directorio de trabajo de cloud-init.
    if ! [[ "$VM_NAME" =~ ^[A-Za-z0-9_]+-[A-Za-z0-9_-]+$ ]]; then
        error 20 "El nombre del dominio '$VM_NAME' no es válido.
Formato requerido: usuario-nombremv (p.ej., alu345-server1).
Solo se admiten letras, números, guiones bajos y guiones, con al menos un guión separador."
    fi

    # Comprobar que no exista ya un dominio con ese nombre
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        error 21 "El dominio '$VM_NAME' ya existe en libvirt. Usa otro nombre o elimina el dominio actual."
    fi
}

########################################
# Resumen final
########################################
print_summary() {
    echo "-------------------------------------------"
    echo "VM (dominio) : $VM_NAME"
    echo "Disco        : $DISK_PATH"
    echo "Hostname     : $HOSTNAME"
    echo "Red          : $NET_NAME"
    echo "IP           : ${IP:-(DHCP)}"
    echo "RAM          : ${RAM_MB} MB"
    echo "vCPUs        : ${VCPUS}"

    if $ENABLE_GRAPHICS; then
        echo "Virt-viewer  : habilitado"
    else
        echo "Virt-viewer  : deshabilitado"
    fi

    if $EXTRA_DISKS; then
        echo "Discos extra : SÍ"
    else
        echo "Discos extra : NO"
    fi

    if $GLUSTERFS; then
        echo "GlusterFS    : activado (server instalado + glusterd habilitado + machine-id reseteado)"
    else
        echo "GlusterFS    : NO"
    fi

    echo
    echo "Usuario 'administrador':"
    echo "  - Clave pública: $PUBKEY_PATH"
    if [[ -n "$USER_PASS" ]]; then
        echo "  - Contraseña activada: $USER_PASS"
    else
        echo "  - Contraseña activada: NO"
    fi
    echo

    echo "Root:"
    if $ENABLE_ROOT; then
        echo "  - Habilitado SOLO consola"
        echo "  - Contraseña: s1st3mas"
    else
        echo "  - Deshabilitado"
    fi

    if $EXTRA_DISKS; then
        echo
        echo "Discos extra:"
        echo "  - Se han creado y adjuntado vdb..vdg en $SILO_DIR"
        echo "  - Puedes verlos con:"
        echo "      virsh domblklist '$VM_NAME'"
    fi

    echo "-------------------------------------------"
}

########################################
# MAIN
########################################
main() {
    parse_args "$@"
    validate_environment
    generate_cloudinit_files "$VM_NAME" "$HOSTNAME"

    echo "→ Creando VM '$VM_NAME' con cloud-init…"

    virt-install \
      --name "$VM_NAME" \
      --ram "$RAM_MB" \
      --vcpus "$VCPUS" \
      --import \
      --disk "path=$DISK_PATH,format=qcow2" \
      --os-variant debian12 \
      --network "network=$NET_NAME" \
      --cloud-init "user-data=$USER_DATA,meta-data=$META_DATA${NETWORK_DATA:+,network-config=$NETWORK_DATA}" \
      $( $ENABLE_GRAPHICS && echo "--graphics spice" || echo "--graphics none" ) \
      --noautoconsole

    # Añadir discos extra si procede
    if $EXTRA_DISKS; then
        attach_extra_disks "$VM_NAME"
    fi

    echo "-------------------------------------------"

    # Ajustar tiempo de espera según opciones
    if $NO_WAIT; then
        SLEEP_SECS=0
    else
        if $GLUSTERFS; then
            SLEEP_SECS="$SLEEP_WITH_GLUSTER"
        else
            SLEEP_SECS="$SLEEP_NO_GLUSTER"
        fi
    fi

    if (( SLEEP_SECS > 0 )); then
        echo "Esperando arranque de la máquina (${SLEEP_SECS}s)…"
        sleep "$SLEEP_SECS"
    else
        echo "Omitiendo espera final (--no-wait activo)."
    fi

    print_summary
}

main "$@"
