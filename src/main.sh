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
# De dónde se descarga si no está en el silo (la misma URL del manual)
BASE_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"

# Usuario del servidor: de él salen los nombres de los dominios y el de la red
USUARIO="$(id -un)"

# Contraseña de consola de 'administrador' y de 'root' (la misma que usa el
# manual de laboratorio). Por SSH se entra siempre con clave; solo con
# --ssh-pass se admite contraseña, y entonces la elige el alumno.
PASS_CONSOLA="s1st3mas"

# Discos
TAM_DISCO_DEFECTO="40G"
TAM_DISCO_EXTRA="40G"
UNIDADES_EXTRA=(vdb vdc vdd vde vdf vdg)          # --extra-disks (apartado A.3.1 del manual)
UNIDADES_CLUSTER=(vdb vdc vdd vde vdf vdg vdh)    # nodos del clúster (apartado A.3.2)

# Clúster GlusterFS (apartado A.3.2 del manual)
CLUSTER_BASE="glusterbase"
CLUSTER_NODOS=(server1 server2 server3 server4)
CLUSTER_IP_INICIAL=10                             # server1 = .10, server2 = .11, ...
CLUSTER_RAM_MB=1024                               # recursos por nodo: los mismos que
CLUSTER_VCPUS=1                                   # usa crea-entorno.sh
CLUSTER_MONTAJES=(/gluster1 /gluster2 /gluster3)  # vdb, vdc y vdd, formateados en xfs

# Recursos por defecto de una máquina suelta
RAM_MB_DEFECTO=2048
VCPUS_DEFECTO=2
RAM_MB_MINIMO=512

# Espera a que cloud-init termine (segundos). Se pueden ajustar desde el
# entorno; los tests lo usan para no esperar de verdad.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"          # máximo antes de rendirse
POLL_SECS="${POLL_SECS:-3}"                  # cada cuánto se consulta
GRACE_SECS="${GRACE_SECS:-5}"                # margen si no se puede consultar cloud-init
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-120}"  # apagado limpio de la base del clúster

########################################
# Opciones (valores por defecto)
########################################
EXTRA_DISKS=false
GLUSTERFS=false
CLUSTER=false
LIMPIAR=false
DRY_RUN=false
NO_WAIT=false

RED_OPT=""
DISCO_OPT=""
TAM_DISCO="$TAM_DISCO_DEFECTO"
RAM_OPT=""
VCPUS_OPT=""
SSH_PASS=""

MAQUINA=""
IP=""

# Derivados
VM_NAME=""
HOST_NAME=""
DISCO_MAIN=""
NET_NAME=""
RAM_MB=""
VCPUS=""

# Ficheros cloud-init de la máquina que se está generando
WORKDIR=""
USER_DATA=""
META_DATA=""
NETWORK_DATA=""

# Comando virt-install, como array para poder ejecutarlo y mostrarlo tal cual
VIRT_INSTALL_CMD=()

# En --dry-run: la imagen base no está y habría que descargarla
BASE_IMG_FALTA=false

########################################
# Registro de lo creado, para poder deshacerlo si algo falla a medias
########################################
DOMINIOS_CREADOS=()
DISCOS_CREADOS=()
CREACION_COMPLETA=false   # true cuando ya solo queda esperar: a partir de ahí no se deshace nada
SALIDA_CONTROLADA=false   # true si se sale por un error propio (validaciones)
INTERRUMPIDO=false        # true si el usuario pulsa Ctrl-C

########################################
# Carga de librerías
########################################
# Ajusta las rutas si tu estructura es distinta
source "$(dirname "${BASH_SOURCE[0]}")/../lib/validations.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/limpieza.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/cloudinit.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/discos.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/espera.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster.sh"

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
# Solo se eliminan los elementos creados por ESTA ejecución: los dominios y
# los discos que el propio script acaba de crear. Nada preexistente se toca.
########################################
revertir_cambios() {
    if (( ${#DOMINIOS_CREADOS[@]} == 0 && ${#DISCOS_CREADOS[@]} == 0 )); then
        return 0
    fi

    echo >&2
    echo "Deshaciendo lo que se había creado en esta ejecución:" >&2

    local dominio disco
    for dominio in ${DOMINIOS_CREADOS[@]+"${DOMINIOS_CREADOS[@]}"}; do
        virsh destroy  "$dominio" >/dev/null 2>&1 || true
        virsh undefine "$dominio" --snapshots-metadata >/dev/null 2>&1 || true
        echo "  - dominio '$dominio' eliminado" >&2
    done

    for disco in ${DISCOS_CREADOS[@]+"${DISCOS_CREADOS[@]}"}; do
        if rm -f "$disco"; then
            echo "  - disco '$disco' eliminado" >&2
        fi
    done

    echo "  (nada que existiera antes de ejecutar el script se ha tocado)" >&2
}

al_salir() {
    local code=$?

    if (( code == 0 )); then
        return 0
    fi

    if $INTERRUMPIDO; then
        echo >&2
        echo "Interrumpido por el usuario." >&2
    elif ! $SALIDA_CONTROLADA; then
        echo >&2
        echo "ERROR: el script ha terminado de forma inesperada (código $code)." >&2
        echo "       Si el problema persiste, avisa a tu profesor indicando el comando usado." >&2
    fi

    if $CREACION_COMPLETA; then
        echo "Las máquinas ya estaban creadas: no se deshace nada. Comprueba su estado con:" >&2
        echo "  virsh list --all" >&2
    else
        revertir_cambios
    fi
}

trap al_salir EXIT
trap 'INTERRUMPIDO=true; exit 130' INT TERM

########################################
# Función de ayuda
########################################
print_help() {
    cat <<EOF
Uso:
  $0 [opciones] MAQUINA [IP]
  $0 [opciones] --gluster-cluster

Crea una máquina virtual Debian 12 con cloud-init en tu silo ($SILO_DIR).
De MAQUINA salen el nombre del dominio (${USUARIO}-MAQUINA), el nombre de
host (MAQUINA) y el disco (MAQUINA.qcow2), que el script crea como copia COW
de debian12.qcow2 (si no está en el silo, la descarga). La red virtual se
busca por tu nombre de usuario.

Parámetros:
  MAQUINA              Nombre corto de la máquina (server1, server2, glusterbase, ...)
  IP                   (Opcional) IP fija dentro de tu red virtual. Sin ella, DHCP.

Opciones:
  --extra-disks        Crea y conecta 6 discos extra de ${TAM_DISCO_EXTRA} (vdb..vdg)
  --glusterfs          Prepara la máquina como nodo GlusterFS (glusterfs-server
                       instalado, glusterd habilitado, machine-id reseteado)
  --gluster-cluster    Construye la infraestructura completa del apartado A.3.2
                       del manual: una base GlusterFS y ${#CLUSTER_NODOS[@]} nodos
                       (${CLUSTER_NODOS[*]}) con IP fija, /etc/hosts, ${#UNIDADES_CLUSTER[@]} discos
                       cada uno y ${CLUSTER_MONTAJES[*]} en xfs. No lleva MAQUINA.
  --limpiar            Si ya existen los dominios o discos que el script va a
                       crear, los elimina antes (solo esos; nada más)
  --red NOMBRE         Red virtual a usar (por defecto se busca ${USUARIO}-red)
  --disco NOMBRE       Nombre del disco principal (por defecto MAQUINA.qcow2)
  --tam TAMAÑO         Tamaño del disco principal (por defecto ${TAM_DISCO_DEFECTO})
  --ram MB             Memoria (por defecto ${RAM_MB_DEFECTO}; en el clúster, ${CLUSTER_RAM_MB} por nodo)
  --vcpus N            vCPUs (por defecto ${VCPUS_DEFECTO}; en el clúster, ${CLUSTER_VCPUS} por nodo)
  --ssh-pass CONTRASEÑA
                       Permite entrar por SSH con contraseña, además de con clave.
                       La contraseña la eliges tú (solo caracteres ASCII).
  --dry-run            Comprueba los datos y muestra lo que se haría, SIN crear nada
  --no-wait            No esperar a que cloud-init termine de configurar la máquina
  -h, --help           Muestra esta ayuda

En todas las máquinas:
  - Usuario 'administrador' con tu clave pública ($PUBKEY_PATH),
    sudo sin contraseña y contraseña de consola '${PASS_CONSOLA}'.
  - Usuario 'root' habilitado solo por consola, contraseña '${PASS_CONSOLA}'.
  - Consola gráfica activa (virt-viewer).
  - Por SSH se entra con clave; con contraseña solo si usas --ssh-pass.

Ejemplos:
  $0 server1                              # DHCP
  $0 --extra-disks server1 192.168.XXX.2  # SERVER1 del apartado A.3.1
  $0 --glusterfs glusterbase              # un nodo GlusterFS suelto
  $0 --gluster-cluster                    # infraestructura del apartado A.3.2
  $0 --dry-run --extra-disks server1 192.168.XXX.2   # solo comprobar
EOF
}

########################################
# Parseo de opciones
########################################
parse_args() {
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --extra-disks)     EXTRA_DISKS=true; shift ;;
            --glusterfs)       GLUSTERFS=true;   shift ;;
            --gluster-cluster) CLUSTER=true;     shift ;;
            --limpiar)         LIMPIAR=true;     shift ;;
            --dry-run)         DRY_RUN=true;     shift ;;
            --no-wait)         NO_WAIT=true;     shift ;;
            --red|--disco|--tam|--ram|--vcpus|--ssh-pass)
                if [[ $# -lt 2 ]]; then
                    error 11 "Falta el valor de la opción $1"
                fi
                case "$1" in
                    --red)      RED_OPT="$2"   ;;
                    --disco)    DISCO_OPT="$2" ;;
                    --tam)      TAM_DISCO="$2" ;;
                    --ram)      RAM_OPT="$2"   ;;
                    --vcpus)    VCPUS_OPT="$2" ;;
                    --ssh-pass) SSH_PASS="$2"  ;;
                esac
                shift 2
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            # Opciones de la versión anterior: se explica qué ha cambiado
            --enable-root)
                error 12 "La opción --enable-root ya no existe: root está siempre habilitado por consola (contraseña ${PASS_CONSOLA})."
                ;;
            --virt-viewer)
                error 12 "La opción --virt-viewer ya no existe: la consola gráfica está siempre activa."
                ;;
            --user-pass)
                error 12 "La opción --user-pass ha sido sustituida por --ssh-pass CONTRASEÑA.
Sin ella, 'administrador' ya tiene contraseña de consola (${PASS_CONSOLA}) y por SSH se entra con clave."
                ;;
            --)
                shift
                args+=("$@")
                break
                ;;
            -*)
                error 12 "Opción desconocida '$1'. Consulta la ayuda con -h."
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    ########################################
    # Parámetros posicionales
    ########################################
    if $CLUSTER; then
        if (( ${#args[@]} > 0 )); then
            error 10 "Con --gluster-cluster no se indica MAQUINA ni IP: los nombres (${CLUSTER_BASE}, ${CLUSTER_NODOS[*]}) y las IPs (.${CLUSTER_IP_INICIAL} en adelante) son fijos."
        fi
        if [[ -n "$DISCO_OPT" ]]; then
            error 10 "La opción --disco no se aplica a --gluster-cluster: los discos se llaman como los nodos."
        fi
    else
        if (( ${#args[@]} == 0 )); then
            error 10 "Falta el nombre de la máquina.
Uso: $0 [opciones] MAQUINA [IP]      (p.ej. $0 server1)
Consulta la ayuda con -h."
        fi
        if (( ${#args[@]} > 2 )); then
            error 10 "Sobran parámetros: '${args[*]}'.
Parece la sintaxis de la versión anterior. Ahora solo se indica el nombre corto
de la máquina y, opcionalmente, la IP; el disco y la red se deducen de tu usuario:
  $0 [opciones] MAQUINA [IP]      (p.ej. $0 --extra-disks server1 192.168.XXX.2)
Consulta la ayuda con -h."
        fi
        MAQUINA="${args[0]}"
        IP="${args[1]:-}"

        # De MAQUINA sale el hostname, así que solo se admiten caracteres válidos
        # en un nombre de host
        if ! [[ "$MAQUINA" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || (( ${#MAQUINA} > 63 )); then
            error 20 "El nombre de máquina '$MAQUINA' no es válido.
Solo letras, números y guiones, empezando por letra o número (p.ej. server1, gluster-base)."
        fi
    fi

    ########################################
    # Recursos: por defecto según el modo
    ########################################
    if $CLUSTER; then
        RAM_MB="${RAM_OPT:-$CLUSTER_RAM_MB}"
        VCPUS="${VCPUS_OPT:-$CLUSTER_VCPUS}"
    else
        RAM_MB="${RAM_OPT:-$RAM_MB_DEFECTO}"
        VCPUS="${VCPUS_OPT:-$VCPUS_DEFECTO}"
    fi

    if ! [[ "$RAM_MB" =~ ^[0-9]+$ ]] || (( RAM_MB < RAM_MB_MINIMO )); then
        error 13 "La memoria RAM '$RAM_MB' no es válida. Debe ser un número de MB igual o mayor que ${RAM_MB_MINIMO}."
    fi

    if ! [[ "$VCPUS" =~ ^[0-9]+$ ]] || (( VCPUS < 1 )); then
        error 13 "El número de vCPUs '$VCPUS' no es válido. Debe ser un número igual o mayor que 1."
    fi

    if ! [[ "$TAM_DISCO" =~ ^[0-9]+[MGT]$ ]]; then
        error 15 "El tamaño de disco '$TAM_DISCO' no es válido. Indícalo como 40G, 20G, 512M..."
    fi

    if [[ -n "$DISCO_OPT" ]] && ! [[ "$DISCO_OPT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        error 16 "El nombre de disco '$DISCO_OPT' no es válido. Indica solo el nombre del fichero (sin rutas), p.ej. server1.qcow2."
    fi

    # La contraseña se teclea en la consola de la máquina virtual, cuyo teclado
    # no tiene por qué corresponderse con el del alumno. El manual ya advierte
    # de no usar tildes ni caracteres del alfabeto español.
    if [[ -n "$SSH_PASS" ]] && grep -q '[^ -~]' <<< "$SSH_PASS"; then
        error 14 "La contraseña contiene caracteres no ASCII (tildes, ñ, etc.).
No podrías teclearla en la consola de la máquina virtual.
Usa solo letras sin tilde, números y signos básicos."
    fi

    ########################################
    # Derivados
    ########################################
    if ! $CLUSTER; then
        VM_NAME="${USUARIO}-${MAQUINA}"
        HOST_NAME="$MAQUINA"
        DISCO_MAIN="${SILO_DIR}/${DISCO_OPT:-${MAQUINA}.qcow2}"
    fi
}

########################################
# Aviso de known_hosts
#
# El DHCP reutiliza direcciones, así que es habitual que la IP de una máquina
# nueva ya figure en known_hosts con la clave de una máquina anterior. El
# resultado es el aviso alarmante del apartado B.2 del manual. Aquí solo se
# avisa y se da el comando: no se toca el known_hosts del usuario.
########################################
avisar_known_hosts() {
    local kh="$HOME/.ssh/known_hosts"
    local ip avisado=false

    if [[ ! -f "$kh" ]] || ! command -v ssh-keygen >/dev/null 2>&1; then
        return 0
    fi

    for ip in "$@"; do
        [[ -z "$ip" ]] && continue
        if ssh-keygen -F "$ip" -f "$kh" >/dev/null 2>&1; then
            if ! $avisado; then
                echo
                echo "AVISO: estas IPs ya figuran en tu known_hosts con la clave de otra máquina."
                echo "       Al conectar por SSH verás un aviso de seguridad. Para resolverlo:"
                avisado=true
            fi
            echo "         ssh-keygen -f \"$kh\" -R \"$ip\""
        fi
    done
}

########################################
# Construcción del comando virt-install
#   construir_comando NOMBRE RAM VCPUS DISCO_PRINCIPAL [DISCOS_EXTRA...]
# Usa los ficheros cloud-init generados justo antes (USER_DATA, META_DATA,
# NETWORK_DATA). Los discos se conectan en el orden dado: el primero es vda.
########################################
construir_comando() {
    local nombre="$1" ram="$2" vcpus="$3"
    shift 3
    local disco

    VIRT_INSTALL_CMD=(
        virt-install
        --quiet
        --name "$nombre"
        --ram "$ram"
        --vcpus "$vcpus"
        --import
    )

    for disco in "$@"; do
        VIRT_INSTALL_CMD+=( --disk "path=${disco},format=qcow2,bus=virtio" )
    done

    VIRT_INSTALL_CMD+=(
        --os-variant debian12
        --network "network=$NET_NAME"
        --cloud-init "user-data=$USER_DATA,meta-data=$META_DATA${NETWORK_DATA:+,network-config=$NETWORK_DATA}"
        --graphics spice
        --noautoconsole
    )
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

# Ejecuta virt-install y registra el dominio para poder deshacerlo
crear_dominio() {
    local nombre="$1"
    "${VIRT_INSTALL_CMD[@]}"
    DOMINIOS_CREADOS+=( "$nombre" )
}

# En --dry-run, si la imagen base no está en el silo
avisar_imagen_falta() {
    if $BASE_IMG_FALTA; then
        echo "    Imagen  : $(basename "$BASE_IMG") no está en el silo; se descargará de"
        echo "              $BASE_IMG_URL"
    fi
}

servidor_fqdn() {
    local h
    h="$(hostname 2>/dev/null || echo SERVIDOR)"
    if [[ "$h" != *.* ]]; then
        h="${h}.lsi.us.es"
    fi
    printf '%s' "$h"
}

########################################
# Resumen final de una máquina suelta
########################################
print_summary() {
    local vm_ip="${IPS_DETECTADAS[$VM_NAME]:-}"
    local ip_mostrar

    if [[ -n "$IP" ]]; then
        ip_mostrar="$IP (fija)"
    elif [[ -n "$vm_ip" ]]; then
        ip_mostrar="$vm_ip (DHCP)"
    else
        ip_mostrar="(DHCP; consúltala con: virsh domifaddr $VM_NAME --source agent)"
    fi

    echo "-------------------------------------------"
    echo "Máquina      : $VM_NAME  (hostname: $HOST_NAME)"
    echo "Disco        : $DISCO_MAIN ($TAM_DISCO)"
    echo "Red          : $NET_NAME"
    echo "IP           : $ip_mostrar"
    echo "RAM / vCPUs  : ${RAM_MB} MB / ${VCPUS}"

    if $EXTRA_DISKS; then
        echo "Discos extra : ${UNIDADES_EXTRA[0]}..${UNIDADES_EXTRA[-1]} (${#UNIDADES_EXTRA[@]} × ${TAM_DISCO_EXTRA}), ver: virsh domblklist $VM_NAME"
    else
        echo "Discos extra : NO"
    fi

    if $GLUSTERFS; then
        echo "GlusterFS    : glusterfs-server instalado, glusterd habilitado, machine-id reseteado"
    else
        echo "GlusterFS    : NO"
    fi

    echo
    echo "Acceso:"
    echo "  ssh administrador@${IP:-${vm_ip:-IP}}        con tu clave pública"
    if [[ -n "$SSH_PASS" ]]; then
        echo "                                        (o con la contraseña: $SSH_PASS)"
    fi
    echo "  virsh console $VM_NAME"
    echo "      administrador o root, contraseña: $PASS_CONSOLA"
    echo "  virt-viewer --connect qemu+ssh://${USUARIO}@$(servidor_fqdn)/system $VM_NAME"
    echo "-------------------------------------------"
}

########################################
# Una máquina suelta
########################################
ejecutar_maquina() {
    local modo="normal"
    local -a extras=()
    local unidad disco

    if $GLUSTERFS; then
        modo="gluster"
    fi

    if $EXTRA_DISKS; then
        for unidad in "${UNIDADES_EXTRA[@]}"; do
            extras+=( "${SILO_DIR}/${MAQUINA}-${unidad}.qcow2" )
        done
    fi

    # Conflictos con lo que ya exista (y --limpiar, si se pidió)
    OBJ_DOMINIOS=( "$VM_NAME" )
    OBJ_FICHEROS=( "$DISCO_MAIN" ${extras[@]+"${extras[@]}"} )
    comprobar_conflictos

    generar_cloudinit "$VM_NAME" "$HOST_NAME" "$IP" "$modo"
    construir_comando "$VM_NAME" "$RAM_MB" "$VCPUS" "$DISCO_MAIN" ${extras[@]+"${extras[@]}"}

    ########################################
    # Modo simulación: nada de lo de abajo se ejecuta
    ########################################
    if $DRY_RUN; then
        echo "→ MODO SIMULACIÓN (--dry-run): no se creará ninguna máquina."
        echo
        echo "✔ Validaciones superadas."
        echo "    Usuario : $USUARIO"
        echo "    Red     : $NET_NAME (pasarela $NET_GATEWAY, prefijo /$NET_PREFIX)"
        if [[ -n "$IP" ]]; then
            echo "    IP      : $IP, disponible para asignación fija"
        else
            echo "    IP      : por DHCP"
        fi
        avisar_imagen_falta
        echo
        echo "✔ Ficheros cloud-init generados en $WORKDIR/"
        echo
        echo "Discos que se crearían en $SILO_DIR:"
        echo "    $(basename "$DISCO_MAIN")  (copia COW de $(basename "$BASE_IMG"), $TAM_DISCO)"
        for disco in ${extras[@]+"${extras[@]}"}; do
            echo "    $(basename "$disco")  ($TAM_DISCO_EXTRA)"
        done
        echo
        echo "Comando que se ejecutaría:"
        echo
        imprimir_comando
        echo
        echo "No se ha creado ni modificado ninguna máquina, disco ni red."
        return 0
    fi

    echo "→ Creando el disco $(basename "$DISCO_MAIN") (copia COW de $(basename "$BASE_IMG"), $TAM_DISCO)…"
    crear_disco_cow "$DISCO_MAIN" "$BASE_IMG" "$TAM_DISCO"

    for disco in ${extras[@]+"${extras[@]}"}; do
        echo "→ Creando el disco extra $(basename "$disco") ($TAM_DISCO_EXTRA)…"
        crear_disco_vacio "$disco" "$TAM_DISCO_EXTRA"
    done

    echo "→ Creando la máquina '$VM_NAME' con cloud-init…"
    crear_dominio "$VM_NAME"
    CREACION_COMPLETA=true
    echo "✔ Máquina creada y arrancada."
    echo "-------------------------------------------"

    if [[ -n "$IP" ]]; then
        IP_ESPERADA[$VM_NAME]="$IP"
    fi

    if $NO_WAIT; then
        echo "Omitiendo la espera (--no-wait activo)."
        echo "NOTA: la máquina sigue configurándose por dentro. No se expulsa el medio de"
        echo "      cloud-init; si vas a tomar instantáneas, apágala antes (apartado B.6 del manual)."
    else
        # Solo se expulsa el medio de cloud-init si consta que la máquina ya
        # terminó de configurarse: hacerlo antes podría interrumpir a cloud-init.
        if esperar_maquinas "$VM_NAME"; then
            eject_cloudinit_media "$VM_NAME"
        fi
    fi

    print_summary
    avisar_known_hosts "${IP:-${IPS_DETECTADAS[$VM_NAME]:-}}"
}

########################################
# MAIN
########################################
main() {
    parse_args "$@"
    validar_entorno

    if $CLUSTER; then
        ejecutar_cluster
    else
        ejecutar_maquina
    fi
}

main "$@"
