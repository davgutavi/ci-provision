#!/bin/bash
set -euo pipefail

########################################
# Configuración general
########################################
SILO_DIR="$HOME/imagenesMV"
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"

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
# Función de ayuda
########################################
print_help() {
    cat <<EOF
Uso:
  $0 [opciones] NOMBRE_VM DISCO HOSTNAME RED [IP] [RAM_MB] [VCPUS]

Opciones:
  --user-pass PASS     Establece contraseña para el usuario 'administrador'
  --enable-root        Habilita root SOLO por consola (contraseña: s1st3mas)
  --virt-viewer        Habilita gráficos SPICE (virt-viewer)
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
# Parseo de opciones
########################################
parse_args() {
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user-pass)
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
                echo "ERROR: opción desconocida '$1'"
                exit 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # Mínimo 4 argumentos obligatorios
    if (( ${#args[@]} < 4 )); then
        echo "ERROR: faltan parámetros obligatorios."
        print_help
        exit 1
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
}

########################################
# Validaciones generales
########################################
validate_environment() {

    # Silo existente
    if [[ ! -d "$SILO_DIR" ]]; then
        echo "ERROR: no existe el silo en: $SILO_DIR"
        exit 1
    fi

    # Clave pública existente
    if [[ ! -f "$PUBKEY_PATH" ]]; then
        echo "ERROR: no existe la clave pública en $PUBKEY_PATH"
        echo "Genera una con: ssh-keygen"
        exit 1
    fi

    # Disco en silo
    if [[ "$DISK_ARG" = /* ]]; then
        DISK_PATH="$DISK_ARG"
    else
        DISK_PATH="$SILO_DIR/$DISK_ARG"
    fi

    if [[ ! -f "$DISK_PATH" ]]; then
        echo "ERROR: el disco no existe: $DISK_PATH"
        exit 1
    fi

    case "$DISK_PATH" in
        "$SILO_DIR"/*) ;;
        *)
            echo "ERROR: el disco debe estar dentro del silo: $SILO_DIR"
            exit 1
            ;;
    esac

    # Formato qcow2
    if ! qemu-img info "$DISK_PATH" | grep -q "file format: qcow2"; then
        echo "ERROR: el disco no es qcow2: $DISK_PATH"
        exit 1
    fi

    # Red existente
    if ! virsh net-info "$NET_NAME" &>/dev/null; then
        echo "ERROR: la red '$NET_NAME' no existe."
        exit 1
    fi

    ########################################
    # VALIDACIÓN LÓGICA: virt-viewer requiere contraseña
    ########################################
    if $ENABLE_GRAPHICS; then
        if [[ -z "$USER_PASS" && $ENABLE_ROOT = false ]]; then
            echo "ERROR: Para usar --virt-viewer debes habilitar acceso por consola."
            echo "Debes usar al menos una de estas opciones:"
            echo "  --user-pass PASSWORD"
            echo "  --enable-root"
            exit 1
        fi
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

    # Esto almacenará cambios de contraseña
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

########################################
# Creación de la VM
########################################
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

########################################
# Añadir discos extra si procede
########################################
if $EXTRA_DISKS; then
    attach_extra_disks "$VM_NAME"
fi

########################################
# Esperar al arranque de la máquina
########################################
echo "-------------------------------------------"
echo "Esperando arranque de la máquina (40s)…"
sleep 40

########################################
# Resumen final
########################################
print_summary