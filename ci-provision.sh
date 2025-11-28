#!/bin/bash
set -euo pipefail

########################################
# Configuración general
########################################
SILO_DIR="$HOME/imagenesMV"
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"
BASE_IMG="$SILO_DIR/debian12.qcow2"

########################################
# Sistema de errores
# Códigos:
# 10–19: mínimos / argumentos
# 20–29: dominio
# 30–39: disco / silo / backing
# 40–49: red / IP
# 50–59: opciones (virt-viewer, etc.)
# 60–69: discos extra
########################################
error() {
    local code="$1"
    shift
    echo "ERROR [$code] $*" >&2
    exit "$code"
}

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
# Parseo de opciones y parámetros
########################################
parse_args() {
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user-pass)
                USER_PASS="${2-}"
                if [[ -z "$USER_PASS" ]]; then
                    error 10 "La opción --user-pass requiere un argumento (la contraseña)."
                fi
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
                error 10 "Opción desconocida '$1'. Usa -h para ver la ayuda."
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # 10 – Mínimo de parámetros obligatorios
    if (( ${#args[@]} < 4 )); then
        error 10 "Faltan parámetros obligatorios. Uso: $0 [opciones] NOMBRE_VM DISCO HOSTNAME RED [IP] [RAM_MB] [VCPUS]"
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

    # 11 – Clave pública obligatoria
    if [[ ! -f "$PUBKEY_PATH" ]]; then
        error 11 "No existe la clave pública en $PUBKEY_PATH. Genera una con: ssh-keygen"
    fi

    # 12 – Validación básica del disco (.qcow2)
    if [[ "$DISK_ARG" != *.qcow2 ]]; then
        error 12 "El parámetro DISCO ('$DISK_ARG') no termina en .qcow2. Revisa el orden de los parámetros."
    fi
}

########################################
# Validaciones generales
########################################
validate_environment() {

    ########################################
    # 2. Dominio
    ########################################

    # 20 – Formato de dominio: usuario-nombre
    if ! [[ "$VM_NAME" =~ ^[^-]+-[^-]+$ ]]; then
        error 20 "El nombre de dominio '$VM_NAME' no es válido. Debe ser usuario-nombre (exactamente un '-')."
    fi

    # 21 – Dominio ya existente
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        error 21 "Ya existe un dominio llamado '$VM_NAME' en libvirt."
    fi

    ########################################
    # 3. Disco
    ########################################

    # 30 – Silo existente
    if [[ ! -d "$SILO_DIR" ]]; then
        error 30 "No existe el silo en: $SILO_DIR"
    fi

    # Resolver ruta del disco
    if [[ "$DISK_ARG" = /* ]]; then
        DISK_PATH="$DISK_ARG"
    else
        DISK_PATH="$SILO_DIR/$DISK_ARG"
    fi

    # 31 – El disco debe existir
    if [[ ! -f "$DISK_PATH" ]]; then
        error 31 "El disco no existe: $DISK_PATH"
    fi

    # 32 – El disco debe estar dentro del silo
    case "$DISK_PATH" in
        "$SILO_DIR"/*) ;;
        *)
            error 32 "El disco debe estar dentro del silo: $SILO_DIR"
            ;;
    esac

    # Ejecutar qemu-img info y guardar salida
    local QEMU_LOG="/tmp/ci-provision-qemu-img.log"
    if ! qemu-img info "$DISK_PATH" &>"$QEMU_LOG"; then
        error 33 "No se ha podido ejecutar 'qemu-img info' sobre $DISK_PATH"
    fi

    # 33 – Comprobar formato qcow2
    if ! grep -q "file format: qcow2" "$QEMU_LOG"; then
        error 33 "El disco $DISK_PATH no es qcow2."
    fi

    # Extraer backing file y formato
    local BACKING_FILE BACKING_FMT
    BACKING_FILE=$(grep -E 'backing file:' "$QEMU_LOG" | sed 's/.*: //') || true
    BACKING_FMT=$(grep -E 'backing file format:' "$QEMU_LOG" | sed 's/.*: //') || true

    # 34 – Debe ser COW de otra qcow2 (backing file + formato)
    if [[ -z "$BACKING_FILE" || -z "$BACKING_FMT" ]]; then
        error 34 "El disco $DISK_PATH no parece ser una copia COW (no tiene backing file válido)."
    fi

    if [[ "$BACKING_FMT" != "qcow2" ]]; then
        error 34 "El disco $DISK_PATH no es COW de otra imagen qcow2 (backing file format != qcow2)."
    fi

    # 35 – Backing debe ser debian12.qcow2
    if [[ "$(basename "$BACKING_FILE")" != "$(basename "$BASE_IMG")" ]]; then
        error 35 "El disco $DISK_PATH no está haciendo COW sobre debian12.qcow2 (backing actual: $BACKING_FILE)."
    fi

    # 36 – Disco reutilizado (tamaño 'grande' >100MB)
    local DISK_SIZE_BYTES THRESHOLD
    DISK_SIZE_BYTES=$(stat -c '%s' "$DISK_PATH")
    THRESHOLD=$((100 * 1024 * 1024)) # 100MB
    if (( DISK_SIZE_BYTES > THRESHOLD )); then
        error 36 "El disco $DISK_PATH ya tiene más de 100MB de datos. Probablemente ya ha sido usado en otra VM. Crea un disco nuevo COW."
    fi

    ########################################
    # 4. Red
    ########################################

    # 40 – Red existente
    if ! virsh net-info "$NET_NAME" &>/dev/null; then
        error 40 "La red '$NET_NAME' no existe."
    fi

    # Validación de IP estática si se ha proporcionado
    if [[ -n "$IP" ]]; then
        local NET_XML NET_ADDR NET_MASK NET_PREFIX IP_PREFIX IP_LAST
        NET_XML=$(virsh net-dumpxml "$NET_NAME" 2>/dev/null || true)
        NET_ADDR=$(grep -E "<ip address=" <<< "$NET_XML" | sed -E "s/.*address='([^']+)'.*/\1/") || true
        NET_MASK=$(grep -E "<ip address=" <<< "$NET_XML" | sed -E "s/.*netmask='([^']+)'.*/\1/") || true

        if [[ -z "$NET_ADDR" || -z "$NET_MASK" ]]; then
            error 41 "No se ha podido obtener la IP/netmask de la red '$NET_NAME' para validar la IP estática $IP."
        fi

        NET_PREFIX=${NET_ADDR%.*}   # 192.168.XXX
        IP_PREFIX=${IP%.*}
        IP_LAST=${IP##*.}

        # 41 – IP debe pertenecer al prefijo de la red /24
        if [[ "$NET_MASK" == "255.255.255.0" && "$NET_PREFIX" != "$IP_PREFIX" ]]; then
            error 41 "La IP $IP no pertenece al rango de la red $NET_NAME (${NET_PREFIX}.0/24)."
        fi

        # 42 – IP no debe estar en el rango DHCP (128–254)
        if [[ "$IP_LAST" =~ ^[0-9]+$ ]]; then
            if (( IP_LAST >= 128 && IP_LAST <= 254 )); then
                error 42 "La IP $IP está dentro del rango DHCP (128–254). Elige una IP fija fuera de ese rango."
            fi
        else
            error 41 "La IP estática $IP no tiene un último octeto numérico válido."
        fi
    fi

    ########################################
    # 5. Opciones generales
    ########################################

    # 50 – virt-viewer requiere user-pass o root
    if $ENABLE_GRAPHICS; then
        if [[ -z "$USER_PASS" && $ENABLE_ROOT = false ]]; then
            error 50 "Para usar --virt-viewer debes habilitar acceso con --user-pass o --enable-root."
        fi
    fi

    ########################################
    # 6. Discos extra
    ########################################
    if $EXTRA_DISKS; then
        local maquina="${VM_NAME#*-}"

        for unidad in vdb vdc vdd vde vdf vdg; do
            local nombre_img="${maquina}-${unidad}.qcow2"
            local ruta_img="${SILO_DIR}/${nombre_img}"

            if [[ -e "$ruta_img" ]]; then
                error 60 "El disco extra $ruta_img ya existe. No se crearán discos extra para evitar sobrescribir datos."
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