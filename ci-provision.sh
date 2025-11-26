#!/bin/bash
set -euo pipefail

#############################################
# VARIABLES GLOBALES
#############################################

ENABLE_ROOT=false
ENABLE_VIRT_VIEWER=false
ENABLE_EXTRA_DISKS=false
USER_PASS=""
PUBKEY=""
WORKDIR=""
USER_DATA=""
META_DATA=""
NETWORK_DATA=""
NOMBRE_VM=""
DISCO=""
HOSTNAME=""
RED=""
IP=""
RAM=""
VCPUS=""
SILO_DIR="$HOME/imagenesMV"

#############################################
# AYUDA
#############################################

print_help() {
cat <<EOF
Uso:
  $0 [OPCIONES] NOMBRE_VM DISCO HOSTNAME RED [IP] [RAM_MB] [CORES]

Descripción:
  Provisiona una máquina virtual Debian 12 con cloud-init.
  Usuario principal: administrador (clave pública obligatoria).
  Contraseña opcional con --user-pass.
  Root opcional SOLO por consola con --enable-root.
  Consola gráfica opcional para virt-viewer con --virt-viewer.
  Discos extra opcionales vdb..vdg en el silo con --extra-disks.

Parámetros:
  NOMBRE_VM   Nombre de la máquina virtual (dominio libvirt).
  DISCO       Ruta (relativa o absoluta) al disco qcow2 dentro de \$HOME/imagenesMV.
  HOSTNAME    Nombre interno de la máquina.
  RED         Nombre de la red virtual existente (virsh net-list).
  IP          (opcional) IP estática. Si se omite, se usa DHCP.
  RAM_MB      (opcional) Memoria RAM en MB. Por defecto 2048.
  CORES       (opcional) Número de vCPUs. Por defecto 2.

Opciones:
  --user-pass PASS     Establece contraseña para el usuario 'administrador'.
                       (Sigue pudiendo entrar por SSH con clave pública).
  --enable-root        Habilita usuario root SOLO por consola
                       con contraseña 's1st3mas' usando cloud-init.
                       El acceso SSH de root sigue deshabilitado.
  --virt-viewer        Crea la VM con dispositivo gráfico SPICE,
                       permitiendo acceso con virt-viewer / virt-manager.
                       Si no se indica, se usará '--graphics none'.
  --extra-disks        Crea discos extra vdb..vdg en el silo (\$HOME/imagenesMV)
                       y los adjunta a la VM.
  -h, --help           Muestra esta ayuda.

Ejemplos:
  $0 alu345-server1 server1.qcow2 server1 alu345-red
  $0 --enable-root alu345-server2 server2.qcow2 server2 alu345-red
  $0 --virt-viewer alu345-server3 server3.qcow2 server3 alu345-red
  $0 --extra-disks alu345-server4 server4.qcow2 server4 alu345-red 192.168.2.40
EOF
}

#############################################
# VALIDACIONES
#############################################

validate_disk() {
    local input="$1"
    local real
    real="$(readlink -f "$input" 2>/dev/null || true)"

    if [[ -z "$real" || ! -f "$real" ]]; then
        echo "ERROR: No existe el disco: $input"
        exit 1
    fi

    local silo_real
    silo_real="$(readlink -f "$SILO_DIR")"

    case "$real" in
        "$silo_real"/*) ;;
        *)
            echo "ERROR: El disco debe estar dentro de: $silo_real"
            echo "Ruta detectada: $real"
            exit 1
            ;;
    esac

    if ! qemu-img info "$real" | grep -q "file format: qcow2"; then
        echo "ERROR: El disco no es qcow2."
        exit 1
    fi

    if ! qemu-img info "$real" | grep -q "backing file: .*debian12.qcow2"; then
        echo "ERROR: El disco NO es copia COW de debian12.qcow2."
        exit 1
    fi

    DISCO="$real"
}

validate_network() {
    if ! virsh net-info "$1" >/dev/null 2>&1; then
        echo "ERROR: La red '$1' no existe."
        exit 1
    fi
}

load_public_key() {
    local key="$HOME/.ssh/id_rsa.pub"
    if [[ ! -f "$key" ]]; then
        echo "ERROR: No se encontró $key"
        echo "Genera una clave con:"
        echo "  ssh-keygen"
        exit 1
    fi
    PUBKEY="$(cat "$key")"
}

#############################################
# GENERACIÓN DE FICHEROS CLOUD-INIT
#############################################

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
        echo "      - ${PUBKEY}"

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

        # Acciones al primer arranque
        echo "runcmd:"
        echo "  - timedatectl set-timezone Europe/Madrid"
        echo "  - apt update"
        echo "  - apt install -y qemu-guest-agent"
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

#############################################
# CREACIÓN DE LA VM
#############################################

create_vm_cloudinit() {
    echo "→ Creando VM '${NOMBRE_VM}' con cloud-init…"

    # Configuración gráfica según --virt-viewer
    local graphics_args=()
    if $ENABLE_VIRT_VIEWER; then
        graphics_args=(--graphics spice)
    else
        graphics_args=(--graphics none)
    fi

    if [[ -n "$NETWORK_DATA" ]]; then
        virt-install --name "$NOMBRE_VM" \
            --ram "$RAM" --vcpus "$VCPUS" \
            --import \
            --disk path="$DISCO" \
            --os-variant=debian12 \
            --network network="$RED" \
            --cloud-init user-data="$USER_DATA",meta-data="$META_DATA",network-config="$NETWORK_DATA" \
            "${graphics_args[@]}" \
            --noautoconsole
    else
        virt-install --name "$NOMBRE_VM" \
            --ram "$RAM" --vcpus "$VCPUS" \
            --import \
            --disk path="$DISCO" \
            --os-variant=debian12 \
            --network network="$RED" \
            --cloud-init user-data="$USER_DATA",meta-data="$META_DATA" \
            "${graphics_args[@]}" \
            --noautoconsole
    fi
}

#############################################
# DISCOS EXTRA vdb..vdg
#############################################

attach_extra_disks() {
    local dominio="$1"
    local maquina="${dominio#*-}"

    echo "Añadiendo discos extra al dominio: $dominio"
    echo "Prefijo de las imágenes (parte derecha del dominio): $maquina"
    echo "Las imágenes se crearán en: $SILO_DIR"
    echo

    for unidad in vdb vdc vdd vde vdf vdg
    do
        local nombre_img="${maquina}-${unidad}.qcow2"
        local ruta_img="${SILO_DIR}/${nombre_img}"

        echo "→ Creando: $ruta_img"
        qemu-img create "$ruta_img" -f qcow2 40G

        echo "→ Adjuntando $ruta_img como $unidad"
        virsh attach-disk "$dominio" "$ruta_img" "$unidad" \
            --driver qemu --subdriver qcow2 --targetbus virtio \
            --persistent --live
        echo
    done

    echo "✔ Discos extra añadidos correctamente al dominio '$dominio'."
}

#############################################
# RESUMEN
#############################################

summary() {
    echo "-------------------------------------------"
    echo "VM            : $NOMBRE_VM"
    echo "Disco         : $DISCO"
    echo "Hostname      : $HOSTNAME"
    echo "Red           : $RED"
    echo "IP            : ${IP:-DHCP}"
    echo "RAM           : $RAM MB"
    echo "vCPUs         : $VCPUS"
    echo "Gráficos      : $( $ENABLE_VIRT_VIEWER && echo 'SPICE (virt-viewer habilitado)' || echo 'none (solo consola/SSH)' )"
    echo "Extra disks   : $( $ENABLE_EXTRA_DISKS && echo 'vdb..vdg en silo' || echo 'no' )"

    echo
    echo "Usuario 'administrador':"
    echo "  - Clave pública: ~/.ssh/id_rsa.pub"
    if [[ -n "$USER_PASS" ]]; then
        echo "  - Contraseña activada: $USER_PASS"
    else
        echo "  - SIN contraseña (solo clave SSH)"
    fi

    echo
    if $ENABLE_ROOT; then
        echo "Root:"
        echo "  - Habilitado SOLO consola"
        echo "  - Contraseña: s1st3mas"
        echo "  - SSH root sigue DESHABILITADO (config por defecto de la imagen cloud)"
    else
        echo "Root:"
        echo "  - No habilitado explícitamente (se mantiene configuración por defecto de la imagen)"
    fi

    if $ENABLE_EXTRA_DISKS; then
        echo
        echo "Discos extra:"
        echo "  - Se han creado y adjuntado vdb..vdg en $SILO_DIR"
        echo "  - Puedes verlos con:"
        echo "      virsh domblklist '$NOMBRE_VM'"
    fi

    echo "-------------------------------------------"
}

#############################################
# PARSEO DE OPCIONES
#############################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --enable-root)
            ENABLE_ROOT=true
            shift
            ;;
        --virt-viewer)
            ENABLE_VIRT_VIEWER=true
            shift
            ;;
        --extra-disks)
            ENABLE_EXTRA_DISKS=true
            shift
            ;;
        --user-pass)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --user-pass requiere una contraseña"
                exit 1
            fi
            USER_PASS="$2"
            shift 2
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "ERROR: Opción desconocida: $1"
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

#############################################
# ARGUMENTOS POSICIONALES
#############################################

if [[ $# -lt 4 || $# -gt 7 ]]; then
    echo "ERROR: Número incorrecto de parámetros."
    echo "Use -h para ver la ayuda."
    exit 1
fi

NOMBRE_VM="$1"
DISCO_INPUT="$2"
HOSTNAME="$3"
RED="$4"
IP="${5:-}"
RAM="${6:-2048}"
VCPUS="${7:-2}"

#############################################
# CHEQUEOS GLOBALES: SILO Y FORMATO NOMBRE
#############################################

# Comprobar que el silo existe
if [[ ! -d "$SILO_DIR" ]]; then
    echo "ERROR: no existe el silo en: $SILO_DIR"
    echo "Asegúrate de haber creado y montado $HOME/imagenesMV."
    exit 1
fi

# Comprobar formato del nombre de la VM: usuario-maquina (exactamente un '-')
if ! [[ "$NOMBRE_VM" =~ ^[^-]+-[^-]+$ ]]; then
    echo "ERROR: el nombre de la VM '$NOMBRE_VM' no es válido."
    echo "El formato debe ser:"
    echo "  nombre_de_usuario_en_el_servidor-nombre_de_la_máquina"
    echo "Ejemplos válidos:"
    echo "  alu345-server1"
    echo "  alu123-server2"
    exit 1
fi

#############################################
# MAIN
#############################################

validate_disk "$DISCO_INPUT"
validate_network "$RED"
load_public_key
generate_cloudinit_files "$NOMBRE_VM" "$HOSTNAME"
create_vm_cloudinit
summary

if $ENABLE_EXTRA_DISKS; then
    attach_extra_disks "$NOMBRE_VM"
fi