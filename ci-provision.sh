#!/bin/bash
set -euo pipefail

#############################################
# VARIABLES GLOBALES
#############################################

ENABLE_ROOT=false
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
# FUNCIONES
#############################################

print_help() {
cat <<EOF
Uso:
  ci-provision [OPCIONES] NOMBRE_VM DISCO HOSTNAME RED [IP] [RAM_MB] [CORES]

Descripción:
  Provisiona una máquina virtual Debian 12 con cloud-init.
  Usuario principal: administrador (clave pública obligatoria).
  Contraseña opcional con --user-pass.
  Root solo por consola si se usa --enable-root.

Reglas:
  * DISCO puede ser ruta absoluta o relativa.
  * El disco debe estar en \$HOME/imagenesMV.
  * Debe ser qcow2 con backing file debian12.qcow2.

Opciones:
  --enable-root        Habilita root solo para consola (s1st3mas)
  --user-pass PASS     Habilita contraseña para administrador
  -h, --help           Mostrar ayuda
EOF
}

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

generate_cloudinit_files() {
    local vm="$1"
    local host="$2"

    WORKDIR="./cloudinit-${vm}"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    USER_DATA="$WORKDIR/cip-user.yaml"
    META_DATA="$WORKDIR/cip-meta.yaml"

    cat > "$META_DATA" <<EOF
instance-id: ${vm}
local-hostname: ${host}
EOF

cat > "$USER_DATA" <<EOF
#cloud-config
users:
  - name: administrador
    groups: [sudo]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh-authorized-keys:
      - $PUBKEY
EOF

    if [[ -n "$USER_PASS" ]]; then
cat >> "$USER_DATA" <<EOF

ssh_pwauth: true
chpasswd:
  list: |
    administrador:${USER_PASS}
  expire: false
EOF
    fi

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

create_vm_cloudinit() {
    echo "→ Creando VM…"
    if [[ -n "$NETWORK_DATA" ]]; then
        virt-install --name "$NOMBRE_VM" \
            --ram "$RAM" --vcpus "$VCPUS" \
            --import \
            --disk path="$DISCO" \
            --os-variant=debian12 \
            --network network="$RED" \
            --cloud-init user-data="$USER_DATA",meta-data="$META_DATA",network-config="$NETWORK_DATA" \
            --graphics none \
            --noautoconsole
    else
        virt-install --name "$NOMBRE_VM" \
            --ram "$RAM" --vcpus "$VCPUS" \
            --import \
            --disk path="$DISCO" \
            --os-variant=debian12 \
            --network network="$RED" \
            --cloud-init user-data="$USER_DATA",meta-data="$META_DATA" \
            --graphics none \
            --noautoconsole
    fi
}

wait_cloudinit_boot() {
    echo "→ Esperando a que cloud-init termine el primer arranque (45s)…"
    sleep 45
}

shutdown_vm() {
    echo "→ Solicitando apagado de la VM…"
    virsh shutdown "$NOMBRE_VM" >/dev/null 2>&1 || true

    # Espera hasta 60 segundos
    for i in {1..60}; do
        state="$(virsh domstate "$NOMBRE_VM" 2>/dev/null || true)"
        if [[ "$state" == "shut off" ]]; then
            echo "→ VM apagada correctamente."
            return
        fi
        sleep 1
    done

    echo "⚠ Timeout: la VM no respondió a ACPI."
    echo "→ Forzando apagado inmediato (destroy)…"
    virsh destroy "$NOMBRE_VM" >/dev/null 2>&1 || true
}

apply_root_password() {
    echo "→ Estableciendo contraseña de root con virt-customize…"
    virt-customize -a "$DISCO" --root-password password:s1st3mas
}

start_vm() {
    echo "→ Iniciando VM…"
    virsh start "$NOMBRE_VM" >/dev/null
}

summary() {
    echo "-------------------------------------------"
    echo "VM            : $NOMBRE_VM"
    echo "Disco         : $DISCO"
    echo "Hostname      : $HOSTNAME"
    echo "Red           : $RED"
    echo "IP            : ${IP:-DHCP}"
    echo "RAM           : $RAM MB"
    echo "vCPUs         : $VCPUS"

    echo
    echo "Usuario 'administrador':"
    echo "  - Clave pública obligatoria"
    if [[ -n "$USER_PASS" ]]; then
        echo "  - Contraseña activada: $USER_PASS"
    else
        echo "  - SIN contraseña"
    fi

    echo
    if $ENABLE_ROOT; then
        echo "Root:"
        echo "  - Habilitado SOLO consola"
        echo "  - Contraseña: s1st3mas"
    else
        echo "Root:"
        echo "  - No habilitado"
    fi
    echo "-------------------------------------------"
}

#############################################
# PARSEO DE OPCIONES
#############################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --enable-root)
            ENABLE_ROOT=true; shift ;;
        --user-pass)
            USER_PASS="$2"; shift 2 ;;
        -h|--help)
            print_help; exit 0 ;;
        --)
            shift; break ;;
        -*)
            echo "ERROR: Opción desconocida: $1"; exit 1 ;;
        *)
            break ;;
    esac
done

#############################################
# ARGUMENTOS POSICIONALES
#############################################

if [[ $# -lt 4 || $# -gt 7 ]]; then
    echo "ERROR: Número incorrecto de parámetros"
    echo "Use --help para más info"
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
# MAIN
#############################################

validate_disk "$DISCO_INPUT"
validate_network "$RED"
load_public_key
generate_cloudinit_files "$NOMBRE_VM" "$HOSTNAME"

create_vm_cloudinit
wait_cloudinit_boot

if $ENABLE_ROOT; then
    shutdown_vm
    apply_root_password
    start_vm
else
    echo "→ Root NO habilitado: no se apaga la VM."
fi

summary