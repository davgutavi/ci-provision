#!/bin/bash
set -euo pipefail

########################################
# Configuración general
########################################
SILO_DIR="$HOME/imagenesMV"
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"
BASE_IMG="$SILO_DIR/debian12.qcow2"

# Umbral para considerar que un disco ya ha sido usado (en KiB)
DISK_REUSE_MAX_KIB=1024

# Espera al arranque para qemu-guest-agent
SLEEP_SECS=40

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
    if ! [[ "$VM_NAME" =~ ^[^-]+-[^-]+$ ]]; then
        error 20 "El nombre del dominio '$VM_NAME' no es válido. Formato requerido: usuario-nombremv (p.ej., alu345-server1)."
    fi

    # Comprobar que no exista ya un dominio con ese nombre
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        error 21 "El dominio '$VM_NAME' ya existe en libvirt. Usa otro nombre o elimina el dominio actual."
    fi
}

########################################
# Validaciones generales
########################################
validate_environment() {

    # Silo existente
    if [[ ! -d "$SILO_DIR" ]]; then
        error 30 "No existe el silo en: $SILO_DIR"
    fi

    # Clave pública existente
    if [[ ! -f "$PUBKEY_PATH" ]]; then
        error 31 "No existe la clave pública en $PUBKEY_PATH. Genera una con: ssh-keygen"
    fi

    # Disco en silo (resolver ruta)
    if [[ "$DISK_ARG" = /* ]]; then
        DISK_PATH="$DISK_ARG"
    else
        DISK_PATH="$SILO_DIR/$DISK_ARG"
    fi

    if [[ ! -f "$DISK_PATH" ]]; then
        error 32 "El disco no existe: $DISK_PATH"
    fi

    case "$DISK_PATH" in
        "$SILO_DIR"/*) ;;
        *)
            error 33 "El disco debe estar dentro del silo: $SILO_DIR"
            ;;
    esac

    # Comprobar qcow2, backing file y disco reutilizado
    local TMP_LOG
    TMP_LOG="$(mktemp /tmp/ci-provision-qemu-img.XXXXXX)"

    if ! qemu-img info "$DISK_PATH" &>"$TMP_LOG"; then
        rm -f "$TMP_LOG"
        error 34 "No se ha podido obtener información con 'qemu-img info' sobre $DISK_PATH"
    fi

    # Formato de fichero
    local FILE_FMT
    FILE_FMT="$(grep -E '^file format:' "$TMP_LOG" | awk '{print $3}')"
    if [[ "$FILE_FMT" != "qcow2" ]]; then
        rm -f "$TMP_LOG"
        error 34 "El disco $DISK_PATH no es qcow2 (file format: $FILE_FMT)."
    fi

    # Backing file y formato
    local BACKING_LINE BACKING_FMT BACKING_NAME
    BACKING_LINE="$(grep -E '^backing file:' "$TMP_LOG" || true)"

    if [[ -z "$BACKING_LINE" ]]; then
        rm -f "$TMP_LOG"
        error 34 "El disco $DISK_PATH no parece ser una copia COW (no tiene 'backing file')."
    fi

    BACKING_FMT="$(grep -E '^backing file format:' "$TMP_LOG" | awk '{print $4}')"
    if [[ "$BACKING_FMT" != "qcow2" ]]; then
        rm -f "$TMP_LOG"
        error 34 "El disco $DISK_PATH no parece una copia COW de otra imagen qcow2 (backing file format: $BACKING_FMT)."
    fi

    # Extraer solo el nombre base del backing file, sin "(actual path: ...)"
    BACKING_NAME="$(echo "$BACKING_LINE" | sed 's/^backing file: //; s/ (actual path: .*//')"

    if [[ "$BACKING_NAME" != "$(basename "$BASE_IMG")" ]]; then
        rm -f "$TMP_LOG"
        error 35 "El disco $DISK_PATH no está haciendo COW sobre $(basename "$BASE_IMG").
Backing actual: $BACKING_NAME
Esperado: $(basename "$BASE_IMG")

Vuelve a crear el disco con:
  qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 NOMBRE.qcow2 40G"
    fi

    # Comprobación de disco reutilizado (disk size)
    local DISK_SIZE_LINE SIZE_NUM SIZE_UNIT SIZE_KIB
    DISK_SIZE_LINE="$(grep -E '^disk size:' "$TMP_LOG" | sed 's/\r//')"
    SIZE_NUM="$(echo "$DISK_SIZE_LINE" | awk '{print $3}')"
    SIZE_UNIT="$(echo "$DISK_SIZE_LINE" | awk '{print $4}')"

    SIZE_KIB=0
    case "$SIZE_UNIT" in
        KiB)
            SIZE_KIB="${SIZE_NUM%.*}"
            ;;
        MiB)
            SIZE_KIB=$(printf "%.0f" "$(echo "$SIZE_NUM * 1024" | bc -l)")
            ;;
        GiB)
            SIZE_KIB=$(printf "%.0f" "$(echo "$SIZE_NUM * 1024 * 1024" | bc -l)")
            ;;
        *)
            SIZE_KIB=0
            ;;
    esac

    if (( SIZE_KIB > DISK_REUSE_MAX_KIB )); then
        rm -f "$TMP_LOG"
        error 36 "El disco $DISK_PATH parece reutilizado: su 'disk size' es mayor de 1 MiB.
Línea de 'disk size' actual:
  $DISK_SIZE_LINE

Crea un disco nuevo con:
  qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 NOMBRE.qcow2 40G"
    fi

    rm -f "$TMP_LOG"

    # Red existente
    if ! virsh net-info "$NET_NAME" &>/dev/null; then
        error 40 "La red '$NET_NAME' no existe."
    fi

    # Validación básica de IP y rango DHCP si se especifica IP estática
    if [[ -n "$IP" ]]; then
        if ! [[ "$IP" =~ ^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            error 41 "La IP '$IP' no es válida. Debe ser del tipo 192.168.XXX.YYY."
        fi

        local OCT3 OCT4
        OCT3="$(echo "$IP" | awk -F. '{print $3}')"
        OCT4="$(echo "$IP" | awk -F. '{print $4}')"

        # Rango DHCP configurado: 128–254 → no se permite en IP fija
        if (( OCT4 >= 128 && OCT4 <= 254 )); then
            error 42 "La IP '$IP' está en el rango DHCP (128–254). Usa una IP fija fuera de ese rango."
        fi
    fi

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

    USER_DATA="$WORKDIR/cip-user.yaml"
    META_DATA="$WORKDIR/cip-meta.yaml"

    # meta-data
    cat > "$META_DATA" <<EOF
instance-id: ${vm}
local-hostname: ${host}
EOF

    # Construcción de lista de contraseñas
    local chpass_list=""
    local ssh_pwauth=false

    if [[ -n "$USER_PASS" ]]; then
        chpass_list+="administrador:${USER_PASS}"$'\n'
        ssh_pwauth=true
    fi

    if $ENABLE_ROOT; then
        chpass_list+="root:s1st3mas"$'\n'
    fi

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
            # Sólo habilitamos glusterd para arranque automático,
            # sin arrancarlo en este primer boot.
            echo "  - systemctl enable glusterd || true"
            echo "  - truncate -s 0 /etc/machine-id"
        fi
    } > "$USER_DATA"

    # IP estática
    if [[ -n "$IP" ]]; then
        NETWORK_DATA="$WORKDIR/cip-net.yaml"
        local gw
        gw="$(echo "$IP" | awk -F. '{print $1"."$2"."$3".1"}')"

        cat > "$NETWORK_DATA" <<EOF
version: 2
ethernets:
  enp1s0:
    addresses:
      - ${IP}/24
    gateway4: ${gw}
    nameservers:
      addresses:
        - 150.214.186.69
        - 150.214.130.15
EOF
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
echo "Esperando arranque de la máquina (${SLEEP_SECS}s)…"
sleep "$SLEEP_SECS"

print_summary