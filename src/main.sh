#!/bin/bash
set -euo pipefail

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

# Espera activa a que cloud-init termine (en segundos)
# Se sustituyó una espera de duración fija (50 s, u 80 s con --glusterfs) por
# la consulta periódica al guest agent: las medidas en los tres servidores
# mostraron que la espera fija se quedaba corta en la mayoría de los casos.
WAIT_TIMEOUT=300         # tiempo máximo antes de rendirse
POLL_SECS=3              # cada cuánto se pregunta al agente
GRACE_SECS=3             # margen tras la respuesta del agente

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

# IP que reporta el guest agent una vez arrancada la máquina
VM_IP=""

WORKDIR=""
USER_DATA=""
META_DATA=""
NETWORK_DATA=""

########################################
# Carga de librerías
########################################
# Ajusta las rutas si tu estructura es distinta
source "$(dirname "${BASH_SOURCE[0]}")/../lib/validations.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/cloudinit.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/extra_disks.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/espera.sh"

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

    if [[ -n "$IP" ]]; then
        echo "IP           : $IP (fija)"
    elif [[ -n "$VM_IP" ]]; then
        echo "IP           : $VM_IP (DHCP)"
    else
        echo "IP           : (DHCP, consúltala con 'virsh domifaddr $VM_NAME --source agent')"
    fi

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

    if $NO_WAIT; then
        echo "Omitiendo la espera (--no-wait activo)."
        echo "NOTA: no se expulsa el medio de cloud-init, porque la máquina puede"
        echo "      seguir configurándose. Si vas a tomar instantáneas, revisa antes"
        echo "      el apartado B.6 del manual."
    else
        # Solo se expulsa el medio de cloud-init si consta que la máquina ya
        # terminó de configurarse: hacerlo antes podría interrumpir a cloud-init.
        if esperar_maquina "$VM_NAME"; then
            eject_cloudinit_media "$VM_NAME"
        fi
    fi

    print_summary
}

main "$@"