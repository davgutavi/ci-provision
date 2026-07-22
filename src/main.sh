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

# Modo simulación: valida y genera ficheros, pero no crea nada
DRY_RUN=false

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

# Comando virt-install, construido como array para poder ejecutarlo y también
# mostrarlo tal cual en modo simulación
VIRT_INSTALL_CMD=()

########################################
# Registro de lo creado, para poder deshacerlo si algo falla a medias
########################################
DOMINIO_CREADO=false
DISCOS_CREADOS=()

# Distingue una salida con código de error propio (validaciones) de un fallo
# inesperado del script
SALIDA_CONTROLADA=false

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
    SALIDA_CONTROLADA=true
    echo "ERROR [$code] $*" >&2
    exit "$code"
}

########################################
# Deshacer lo creado si la ejecución se interrumpe a medias
#
# Solo se eliminan los elementos creados por ESTA ejecución. El disco
# principal del alumno y cualquier fichero preexistente no se tocan nunca.
########################################
revertir_cambios() {
    if ! $DOMINIO_CREADO && (( ${#DISCOS_CREADOS[@]} == 0 )); then
        return 0
    fi

    echo >&2
    echo "Deshaciendo lo que se había creado en esta ejecución:" >&2

    if $DOMINIO_CREADO; then
        virsh destroy  "$VM_NAME" >/dev/null 2>&1 || true
        virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
        echo "  - dominio '$VM_NAME' eliminado" >&2
    fi

    local disco
    for disco in ${DISCOS_CREADOS[@]+"${DISCOS_CREADOS[@]}"}; do
        if rm -f "$disco"; then
            echo "  - disco extra '$disco' eliminado" >&2
        fi
    done

    if [[ -n "$DISK_PATH" ]]; then
        echo "  (tu disco principal '$DISK_PATH' NO se ha tocado)" >&2
    fi
}

al_salir() {
    local code=$?

    if (( code == 0 )); then
        return 0
    fi

    if ! $SALIDA_CONTROLADA; then
        echo >&2
        echo "ERROR: el script ha terminado de forma inesperada (código $code)." >&2
        echo "       Si el problema persiste, avisa a tu profesor indicando el comando usado." >&2
    fi

    revertir_cambios
}

trap al_salir EXIT

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
  --dry-run            Comprueba los datos y muestra lo que se haría, SIN crear nada
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
            --dry-run)
                DRY_RUN=true
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

    # RAM y vCPUs deben ser números; si no, virt-install falla con un error
    # críptico mucho más adelante
    if ! [[ "$RAM_MB" =~ ^[0-9]+$ ]] || (( RAM_MB < 512 )); then
        error 13 "La memoria RAM '$RAM_MB' no es válida. Debe ser un número de MB igual o mayor que 512 (por defecto 2048)."
    fi

    if ! [[ "$VCPUS" =~ ^[0-9]+$ ]] || (( VCPUS < 1 )); then
        error 13 "El número de vCPUs '$VCPUS' no es válido. Debe ser un número igual o mayor que 1 (por defecto 2)."
    fi

    # La contraseña se teclea en la consola de la máquina virtual, cuyo teclado
    # no tiene por qué corresponderse con el del alumno. El manual ya advierte
    # de no usar tildes ni caracteres del alfabeto español.
    if [[ -n "$USER_PASS" ]] && grep -q '[^ -~]' <<< "$USER_PASS"; then
        error 14 "La contraseña contiene caracteres no ASCII (tildes, ñ, etc.).
No podrías teclearla en la consola de la máquina virtual.
Usa solo letras sin tilde, números y signos básicos."
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
# Aviso de known_hosts
#
# El DHCP reutiliza direcciones, así que es muy habitual que la IP de una
# máquina nueva ya figure en known_hosts con la clave de una máquina anterior.
# El resultado es el aviso alarmante del apartado B.2 del manual. Aquí solo se
# avisa y se da el comando: no se toca el known_hosts del usuario.
########################################
avisar_known_hosts() {
    local ip="$1"
    local kh="$HOME/.ssh/known_hosts"

    if [[ -z "$ip" || ! -f "$kh" ]]; then
        return 0
    fi

    if ssh-keygen -F "$ip" -f "$kh" >/dev/null 2>&1; then
        echo
        echo "AVISO: la IP $ip ya figura en tu known_hosts con la clave de otra máquina."
        echo "       Al conectar por SSH verás un aviso de seguridad. Para resolverlo:"
        echo "         ssh-keygen -f \"$kh\" -R \"$ip\""
    fi
}

########################################
# Construcción del comando virt-install
########################################
construir_comando() {
    VIRT_INSTALL_CMD=(
        virt-install
        --name "$VM_NAME"
        --ram "$RAM_MB"
        --vcpus "$VCPUS"
        --import
        --disk "path=$DISK_PATH,format=qcow2"
        --os-variant debian12
        --network "network=$NET_NAME"
        --cloud-init "user-data=$USER_DATA,meta-data=$META_DATA${NETWORK_DATA:+,network-config=$NETWORK_DATA}"
    )

    if $ENABLE_GRAPHICS; then
        VIRT_INSTALL_CMD+=( --graphics spice )
    else
        VIRT_INSTALL_CMD+=( --graphics none )
    fi

    VIRT_INSTALL_CMD+=( --noautoconsole )
}

# Muestra el comando de forma legible, una opción por línea
imprimir_comando() {
    local i=1 n=${#VIRT_INSTALL_CMD[@]} arg siguiente

    printf '  virt-install \\\n'
    while (( i < n )); do
        arg="${VIRT_INSTALL_CMD[$i]}"
        siguiente="${VIRT_INSTALL_CMD[$(( i + 1 ))]:-}"

        if [[ "$arg" == --* && -n "$siguiente" && "$siguiente" != --* ]]; then
            printf '    %s %s' "$arg" "$siguiente"
            i=$(( i + 2 ))
        else
            printf '    %s' "$arg"
            i=$(( i + 1 ))
        fi

        if (( i < n )); then printf ' \\\n'; else printf '\n'; fi
    done
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
    construir_comando

    ########################################
    # Modo simulación: nada de lo de abajo se ejecuta
    ########################################
    if $DRY_RUN; then
        echo "→ MODO SIMULACIÓN (--dry-run): no se creará ninguna máquina."
        echo
        echo "✔ Validaciones superadas."
        echo "    Red '$NET_NAME': pasarela $NET_GATEWAY, prefijo /$NET_PREFIX"
        if [[ -n "$IP" ]]; then
            echo "    IP $IP disponible para asignación fija."
        else
            echo "    La máquina obtendría su IP por DHCP."
        fi
        echo
        echo "✔ Ficheros cloud-init generados en $WORKDIR/"
        echo
        echo "Comando que se ejecutaría:"
        echo
        imprimir_comando
        echo

        if $EXTRA_DISKS; then
            local maquina="${VM_NAME#*-}"
            echo "Después se crearían y engancharían 6 discos extra de 40G en $SILO_DIR:"
            echo "    ${maquina}-vdb.qcow2 … ${maquina}-vdg.qcow2"
            echo
        fi

        echo "No se ha creado ni modificado ninguna máquina, disco ni red."
        return 0
    fi

    echo "→ Creando VM '$VM_NAME' con cloud-init…"

    "${VIRT_INSTALL_CMD[@]}"
    DOMINIO_CREADO=true

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
    avisar_known_hosts "${IP:-$VM_IP}"
}

main "$@"