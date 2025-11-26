#!/bin/bash
set -euo pipefail

########################################
# Configuración
########################################
SILO_DIR="$HOME/imagenesMV"
BASE_IMG_NAME="debian12.qcow2"
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"

########################################
# Variables de opciones (por defecto)
########################################
USER_PASS=""
ENABLE_ROOT=false
ENABLE_GRAPHICS=false      # controlado por --virt-viewer
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
  NOMBRE_VM            Nombre del dominio en libvirt (p.ej. alu345-server1)
  DISCO                Ruta al .qcow2 (debe estar dentro de $SILO_DIR)
  HOSTNAME             Nombre interno de la máquina (hostname)
  RED                  Nombre de la red virtual de libvirt
  IP                   (Opcional) IP estática. Si se omite, se usa DHCP
  RAM_MB               (Opcional) Memoria en MB. Por defecto: 2048
  VCPUS                (Opcional) Núcleos de CPU. Por defecto: 2
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
                if [[ $# -lt 2 ]]; then
                    echo "ERROR: --user-pass requiere un argumento." >&2
                    exit 1
                fi
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
                while [[ $# -gt 0 ]]; do
                    args+=("$1")
                    shift
                done
                break
                ;;
            -*)
                echo "ERROR: opción desconocida: $1" >&2
                exit 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # Posicionales
    if (( ${#args[@]} < 4 )); then
        echo "ERROR: faltan parámetros obligatorios." >&2
        print_help
        exit 1
    fi

    VM_NAME="${args[0]}"
    DISK_ARG="${args[1]}"
    HOSTNAME="${args[2]}"
    NET_NAME="${args[3]}"

    if (( ${#args[@]} >= 5 )); then
        IP="${args[4]}"
    fi
    if (( ${#args[@]} >= 6 )); then
        RAM_MB="${args[5]}"
    fi
    if (( ${#args[@]} >= 7 )); then
        VCPUS="${args[6]}"
    fi
}

########################################
# Validaciones generales
########################################
validate_environment() {
    # Silo
    if [[ ! -d "$SILO_DIR" ]]; then
        echo "ERROR: no existe el silo en: $SILO_DIR" >&2
        echo "Asegúrate de haber creado y montado $HOME/imagenesMV." >&2
        exit 1
    fi

    # Clave pública
    if [[ ! -f "$PUBKEY_PATH" ]]; then
        echo "ERROR: no se encontró la clave pública en: $PUBKEY_PATH" >&2
        echo "Genera una con: ssh-keygen" >&2
        exit 1
    fi

    # Disco: convertir a ruta absoluta
    if [[ "$DISK_ARG" = /* ]]; then
        DISK_PATH="$DISK_ARG"
    else
        DISK_PATH="$SILO_DIR/$DISK_ARG"
    fi

    if [[ ! -f "$DISK_PATH" ]]; then
        echo "ERROR: el disco '$DISK_PATH' no existe." >&2
        exit 1
    fi

    # El disco debe estar dentro del silo
    case "$DISK_PATH" in
        "$SILO_DIR"/*) ;;
        *)
            echo "ERROR: el disco debe estar ubicado dentro del silo: $SILO_DIR" >&2
            echo "Ruta actual del disco: $DISK_PATH" >&2
            exit 1
            ;;
    esac

    # Comprobar que es qcow2
    if ! qemu-img info "$DISK_PATH" | grep -q "file format: qcow2"; then
        echo "ERROR: el disco '$DISK_PATH' no es de tipo qcow2." >&2
        exit 1
    fi

    # Comprobar que la red existe
    if ! virsh net-info "$NET_NAME" &>/dev/null; then
        echo "ERROR: la red '$NET_NAME' no existe en libvirt." >&2
        exit 1
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

    # user-data
    local chpass_list=""
    local ssh_pwauth=false

    # Contraseña del usuario administrador (opcional)
    if [[ -n "$USER_PASS" ]]; then
        chpass_list+="administrador:${USER_PASS}"$'\n'
        ssh_pwauth=true
    fi

    # Contraseña de root (solo si se habilita)
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

        # Instalación del guest agent en la fase de paquetes
        echo "package_update: true"
        echo "packages:"
        echo "  - qemu-guest-agent"

        # Acciones al primer arranque
        echo "runcmd:"
        echo "  - timedatectl set-timezone Europe/Madrid"
        echo "  - systemctl start qemu-guest-agent"
    } > "$USER_DATA"

    # network-config (solo si IP estática)
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

    # parte derecha del dominio: nombre de la máquina
    local maquina="${dominio#*-}"

    echo "Añadiendo discos extra al dominio: $dominio"
    echo "Prefijo de las imágenes (parte derecha del dominio): $maquina"
    echo "Las imágenes se crearán en: $SILO_DIR"
    echo

    for unidad in vdb vdc vdd vde vdf vdg; do
        local nombre_img="${maquina}-${unidad}.qcow2"
        local ruta_img="${SILO_DIR}/${nombre_img}"

        echo "→ Creando: $ruta_img"
        qemu-img create "$ruta_img" -f qcow2 40G

        echo "→ Adjuntando $ruta_img como $unidad"
        virsh attach-disk "$dominio" "$ruta_img" "$unidad" \
            --driver qemu --subdriver qcow2 --targetbus virtio \
            --persistent --live
        echo "Disk attached successfully"
        echo
    done

    echo "✔ Discos extra añadidos correctamente al dominio '$dominio'."
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
# Creación de la VM con virt-install
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
# Discos extra (si se ha pedido)
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