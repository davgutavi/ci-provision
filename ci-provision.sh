#!/bin/bash
set -euo pipefail

########################################
# Configuración general
########################################
SILO_DIR="$HOME/imagenesMV"
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"
BASE_IMG="$SILO_DIR/debian12.qcow2"
QEMU_LOG="/tmp/ci-provision-qemu-img.log"

########################################
# Variables de opciones (por defecto)
########################################
USER_PASS=""
ENABLE_ROOT=false
ENABLE_GRAPHICS=false
EXTRA_DISKS=false

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
# Función de error con códigos
########################################
error() {
    local code="$1"
    shift
    echo "ERROR [$code] $*" >&2
    exit "$code"
}

########################################
# Ayuda
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
# Parseo de opciones y parámetros
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
                error 11 "Opción desconocida '$1'"
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # 10 – Mínimos obligatorios
    if (( ${#args[@]} < 4 )); then
        error 10 "Faltan parámetros obligatorios."
    fi

    VM_NAME="${args[0]}"
    DISK_ARG="${args[1]}"
    HOSTNAME="${args[2]}"
    NET_NAME="${args[3]}"

    # DISK debe parecer .qcow2 (check básico de orden)
    if [[ "$DISK_ARG" != *.qcow2 ]]; then
        error 12 "El parámetro DISCO ('$DISK_ARG') no termina en .qcow2. Revisa el orden de los argumentos."
    fi

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
}

########################################
# Pre-check de discos extra
########################################
precheck_extra_disks() {
    local dominio="$1"
    local maquina="${dominio#*-}"

    for unidad in vdb vdc vdd vde vdf vdg; do
        local nombre_img="${maquina}-${unidad}.qcow2"
        local ruta_img="${SILO_DIR}/${nombre_img}"

        if [[ -f "$ruta_img" ]]; then
            error 60 "El disco extra '$ruta_img' ya existe. Elimínalo o usa otro nombre de dominio."
        fi
    done
}

########################################
# Validaciones generales
########################################
validate_environment() {

    ########################################
    # 2.1 Formato del dominio
    ########################################
    if ! [[ "$VM_NAME" =~ ^[^-]+-[^-]+$ ]]; then
        error 20 "El nombre de dominio '$VM_NAME' no es válido. Formato esperado: usuario-nombre_maquina (p.ej. alu345-server1)."
    fi

    ########################################
    # 2.2 Dominio ya existente
    ########################################
    if virsh list --all | awk '{print $2}' | grep -qx "$VM_NAME"; then
        error 21 "Ya existe un dominio llamado '$VM_NAME' en libvirt."
    fi

    ########################################
    # 3.1 Silo existente
    ########################################
    if [[ ! -d "$SILO_DIR" ]]; then
        error 30 "No existe el silo en: $SILO_DIR"
    fi

    ########################################
    # 4.1 Clave pública existente
    ########################################
    if [[ ! -f "$PUBKEY_PATH" ]]; then
        error 70 "No existe la clave pública en $PUBKEY_PATH. Genera una con: ssh-keygen"
    fi

    ########################################
    # 3.3 Disco en silo y existencia
    ########################################
    if [[ "$DISK_ARG" = /* ]]; then
        DISK_PATH="$DISK_ARG"
    else
        DISK_PATH="$SILO_DIR/$DISK_ARG"
    fi

    if [[ ! -f "$DISK_PATH" ]]; then
        error 31 "El disco no existe: $DISK_PATH"
    fi

    case "$DISK_PATH" in
        "$SILO_DIR"/*) ;;
        *)
            error 32 "El disco debe estar dentro del silo: $SILO_DIR"
            ;;
    esac

    ########################################
    # 3.4 Formato qcow2
    ########################################
    if ! qemu-img info "$DISK_PATH" &>"$QEMU_LOG"; then
        error 33 "No se ha podido ejecutar 'qemu-img info' sobre $DISK_PATH"
    fi

    if ! grep -q "^file format: qcow2" "$QEMU_LOG"; then
        error 33 "El disco $DISK_PATH no es qcow2."
    fi

    ########################################
    # 3.5 Copia COW sobre debian12.qcow2
    ########################################
    if [[ ! -f "$BASE_IMG" ]]; then
        error 37 "No se encuentra la imagen base '$BASE_IMG'. Debe existir debian12.qcow2 en el silo."
    fi

    local BACKING_FILE_LINE BACKING_FMT_LINE BACKING_FILE BACKING_FMT

    BACKING_FILE_LINE=$(grep -E '^backing file:' "$QEMU_LOG" || true)
    BACKING_FMT_LINE=$(grep -E '^backing file format:' "$QEMU_LOG" || true)

    if [[ -n "$BACKING_FILE_LINE" ]]; then
        # Ejemplos:
        # backing file: debian12.qcow2
        # backing file: debian12.qcow2 (actual path: imagenesMV/debian12.qcow2)
        BACKING_FILE=${BACKING_FILE_LINE#*: }   # quita "backing file: "
        BACKING_FILE=${BACKING_FILE%% (*}      # quita " (actual path: ...)" si existe
    else
        BACKING_FILE=""
    fi

    if [[ -n "$BACKING_FMT_LINE" ]]; then
        # "backing file format: qcow2" → campo 4 = qcow2
        BACKING_FMT=$(echo "$BACKING_FMT_LINE" | awk '{print $4}' | tr -d '[:space:]')
    else
        BACKING_FMT=""
    fi

    # 34 – Debe ser COW de otra qcow2
    if [[ -z "$BACKING_FILE" || -z "$BACKING_FMT" ]]; then
        error 34 "El disco $DISK_PATH no parece ser una copia COW (no tiene backing file válido)."
    fi

    if [[ "$BACKING_FMT" != "qcow2" ]]; then
        error 34 "El disco $DISK_PATH no es COW de otra imagen qcow2 (backing file format != qcow2)."
    fi

    # 35 – Backing debe ser debian12.qcow2 (por nombre)
    if [[ "$(basename "$BACKING_FILE")" != "$(basename "$BASE_IMG")" ]]; then
        error 35 "El disco $DISK_PATH no está haciendo COW sobre debian12.qcow2 (backing actual: $BACKING_FILE)."
    fi

    ########################################
    # 4.1 Red existente
    ########################################
    if ! virsh net-info "$NET_NAME" &>/dev/null; then
        error 40 "La red '$NET_NAME' no existe."
    fi

    ########################################
    # 4.2 Validación de IP estática (si se proporciona)
    ########################################
    if [[ -n "$IP" ]]; then
        # IP debe tener formato 4 octetos
        if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            error 41 "La IP '$IP' no tiene un formato IPv4 válido."
        fi

        # Obtener dirección y rango DHCP de la red
        local NET_XML NET_ADDR NET_MASK DHCP_START DHCP_END
        NET_XML=$(virsh net-dumpxml "$NET_NAME")

        NET_ADDR=$(echo "$NET_XML" | awk -F"'" '/<ip address=/{print $2; exit}')
        NET_MASK=$(echo "$NET_XML" | awk -F"'" '/<ip address=/{print $4; exit}')
        DHCP_START=$(echo "$NET_XML" | awk -F"'" '/<range start=/{print $2; exit}')
        DHCP_END=$(echo "$NET_XML" | awk -F"'" '/<range start=/{print $4; exit}')

        # Asumimos /24 (255.255.255.0) como en la asignatura
        if [[ "$NET_MASK" != "255.255.255.0" ]]; then
            echo "AVISO: La máscara de la red $NET_NAME no es 255.255.255.0. Las validaciones de IP pueden no ser exactas." >&2
        fi

        # Red del alumno = primeros 3 octetos de NET_ADDR
        local NET_PREFIX IP_PREFIX
        NET_PREFIX=$(echo "$NET_ADDR" | awk -F. '{print $1"."$2"."$3}')
        IP_PREFIX=$(echo "$IP"       | awk -F. '{print $1"."$2"."$3}')

        if [[ "$NET_PREFIX" != "$IP_PREFIX" ]]; then
            error 41 "La IP '$IP' no pertenece al rango de la red '$NET_NAME' (prefijo esperado: $NET_PREFIX.x)."
        fi

        # 4.3 IP no puede estar dentro del rango DHCP (asumimos 128–254 salvo que el XML diga otra cosa)
        local IP_LAST OCT_DHCP_START OCT_DHCP_END
        IP_LAST=$(echo "$IP" | awk -F. '{print $4}')

        if [[ -n "$DHCP_START" && -n "$DHCP_END" ]]; then
            OCT_DHCP_START=$(echo "$DHCP_START" | awk -F. '{print $4}')
            OCT_DHCP_END=$(echo "$DHCP_END"     | awk -F. '{print $4}')
        else
            # Por defecto, como se ha configurado en la asignatura: 128–254
            OCT_DHCP_START=128
            OCT_DHCP_END=254
        fi

        if (( IP_LAST >= OCT_DHCP_START && IP_LAST <= OCT_DHCP_END )); then
            error 42 "La IP '$IP' está dentro del rango DHCP ($OCT_DHCP_START–$OCT_DHCP_END) de la red '$NET_NAME'. Debes usar una IP fija fuera de ese rango."
        fi
    fi

    ########################################
    # 5.1 virt-viewer requiere contraseña o root
    ########################################
    if $ENABLE_GRAPHICS; then
        if [[ -z "$USER_PASS" && $ENABLE_ROOT = false ]]; then
            error 50 "Para usar --virt-viewer debes habilitar un acceso interactivo. Usa al menos una de estas opciones:
  --user-pass PASSWORD
  --enable-root"
        fi
    fi

    ########################################
    # 5.2 Pre-check de discos extra
    ########################################
    if $EXTRA_DISKS; then
        precheck_extra_disks "$VM_NAME"
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

    # Acumulador de contraseñas
    local chpass_list=""
    local ssh_pwauth=false

    if [[ -n "$USER_PASS" ]]; then
        chpass_list+="administrador:${USER_PASS}"$'\n'
        ssh_pwauth=true
    fi

    if $ENABLE_ROOT; then
        chpass_list+="root:s1st3mas"$'\n'
    fi

    # user-data
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

        echo "runcmd:"
        echo "  - timedatectl set-timezone Europe/Madrid"
        echo "  - systemctl start qemu-guest-agent"
    } > "$USER_DATA"

    # network-config sólo si hay IP fija
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

if $EXTRA_DISKS; then
    attach_extra_disks "$VM_NAME"
fi

echo "-------------------------------------------"
echo "Esperando arranque de la máquina (40s)…"
sleep 40

print_summary