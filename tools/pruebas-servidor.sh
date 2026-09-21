#!/bin/bash
# Batería de pruebas de ci-provision.sh en un servidor de la asignatura.
# Ejecuta el script de verdad contra libvirt y comprueba el resultado, también
# por dentro de las máquinas (por SSH, con tu clave).
#
# Uso, desde cualquier directorio:
#   bash tools/pruebas-servidor.sh a        Fase A: validaciones. NO crea nada.
#   bash tools/pruebas-servidor.sh b        Fase B: máquinas sueltas (pruebas1, pruebasgluster)
#   bash tools/pruebas-servidor.sh c        Fase C: clúster GlusterFS (glusterbase, server1..4)
#   bash tools/pruebas-servidor.sh todas
#
# Variables opcionales:
#   LIMPIAR=1        En la fase C, pasa --limpiar al script si ya existen
#                    server1..4 o glusterbase (el propio script enumera qué borra).
#   CONSERVAR=1      No eliminar las máquinas de prueba al terminar cada fase.
#
# Antes de las fases B y C carga tu clave en el agente SSH:  ssh-add

set -uo pipefail
export LC_ALL=C

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$AQUI/../ci-provision.sh"
SILO="$HOME/imagenesMV"
USUARIO="$(id -un)"
FASE="${1:-a}"

OK=0
KO=0
LOG="$SILO/pruebas-servidor-$(date +%Y%m%d-%H%M%S).log"

########################################
# Utilidades
########################################
titulo() { echo; echo "═══ $* ═══"; }
ok()     { OK=$(( OK + 1 )); printf '  \033[32m✔\033[0m %s\n' "$*"; }
ko()     { KO=$(( KO + 1 )); printf '  \033[31m✘\033[0m %s\n' "$*"; }
info()   { printf '  · %s\n' "$*"; }

# comprueba DESCRIPCION COMANDO...   (éxito = ok)
comprueba() {
    local desc="$1"; shift
    if "$@" >>"$LOG" 2>&1; then ok "$desc"; else ko "$desc"; fi
}

# espera_codigo CODIGO DESCRIPCION ARGS...   ejecuta el script y compara el código
espera_codigo() {
    local esperado="$1" desc="$2"; shift 2
    local salida rc
    salida="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    printf '\n$ ci-provision.sh %s\n%s\n' "$*" "$salida" >> "$LOG"
    if [[ "$rc" == "$esperado" ]]; then
        ok "[$rc] $desc"
    else
        ko "$desc → esperaba $esperado, obtuve $rc"
        echo "$salida" | head -5 | sed 's/^/       | /'
    fi
}

# ssh a una máquina de prueba con un known_hosts desechable (la IP puede
# haberla tenido otra máquina, y no queremos tocar el known_hosts real)
en_vm() {
    local ip="$1"; shift
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "administrador@$ip" "$@"
}

# en_vm_es IP DESCRIPCION VALOR_ESPERADO COMANDO
en_vm_es() {
    local ip="$1" desc="$2" esperado="$3"; shift 3
    local obtenido
    obtenido="$(en_vm "$ip" "$@" 2>>"$LOG" | tr -d '\r' | head -1)"
    if [[ "$obtenido" == "$esperado" ]]; then
        ok "$desc"
    else
        ko "$desc → esperaba '$esperado', obtuve '$obtenido'"
    fi
}

# Extrae "IP           : X" del resumen del script
ip_del_resumen() {
    sed -n 's/^IP           : \([0-9.]*\).*/\1/p' <<< "$1" | head -1
}

# Elimina una máquina de prueba y sus discos (solo por nombre exacto)
elimina_maquina() {
    local maq="$1" u
    virsh destroy  "${USUARIO}-${maq}" >/dev/null 2>&1
    virsh undefine "${USUARIO}-${maq}" --snapshots-metadata >/dev/null 2>&1
    rm -f "$SILO/${maq}.qcow2"
    for u in vdb vdc vdd vde vdf vdg vdh; do rm -f "$SILO/${maq}-${u}.qcow2"; done
    rm -rf "$SILO/cloudinit-${USUARIO}-${maq}" "$SILO/cloudinit-${USUARIO}-${maq}.dry-run"
}

# Pasarela de la red del usuario y una IP libre para las pruebas
descubrir_red() {
    # --limpiar en un --dry-run solo enumera: así no estorban los restos de
    # una ejecución anterior (error 21)
    local salida
    salida="$(bash "$SCRIPT" --dry-run --limpiar pruebas1 2>&1)" || {
        echo "No puedo ni hacer un --dry-run. Salida:"; echo "$salida"; exit 1; }
    RED="$(sed -n 's/^    Red     : \([^ ]*\).*/\1/p' <<< "$salida" | head -1)"
    GW="$(sed -n 's/.*pasarela \([0-9.]*\),.*/\1/p' <<< "$salida" | head -1)"

    # Pedimos una IP que no puede ser de ninguna red (203.0.113.0/24 está
    # reservada para documentación): falla con 41 y enumera los bloques libres
    salida="$(bash "$SCRIPT" --dry-run pruebas1 203.0.113.9 2>&1)"
    local bloque ini fin
    bloque="$(sed -n '/IPs libres/{n;p;}' <<< "$salida" | head -1)"
    ini="$(awk '{print $1}' <<< "$bloque")"
    fin="$(awk '{print $3}' <<< "$bloque")"
    if [[ -z "$ini" || "$ini" == "(ninguna)" ]]; then
        IP_LIBRE=""
    else
        # Unas cuantas por encima del inicio, sin salirnos del bloque
        local o_ini="${ini##*.}" o_fin="${fin##*.}" o
        o=$(( o_ini + 48 ))
        (( o > o_fin )) && o="$o_ini"
        IP_LIBRE="${ini%.*}.${o}"
    fi
}

########################################
# Fase A: validaciones (no crea nada)
########################################
fase_a() {
    titulo "Fase A: validaciones (no se crea nada)"
    descubrir_red
    info "Red detectada: $RED (pasarela $GW). IP libre para pruebas: ${IP_LIBRE:-ninguna}"

    espera_codigo 0  "ayuda"                                   -h
    espera_codigo 10 "sin parámetros"
    espera_codigo 10 "sintaxis antigua (4 posicionales)"       u-s1 s1.qcow2 s1 red
    espera_codigo 12 "opción antigua --enable-root"            --enable-root pruebas1
    espera_codigo 12 "opción antigua --user-pass"              --user-pass x pruebas1
    espera_codigo 12 "opción desconocida"                      --noexiste pruebas1
    espera_codigo 11 "opción sin valor"                        pruebas1 --ram
    espera_codigo 20 "nombre de máquina inválido"              "a b"
    espera_codigo 13 "RAM no numérica"                         --dry-run --ram abc pruebas1
    espera_codigo 15 "tamaño de disco inválido"                --dry-run --tam 40 pruebas1
    espera_codigo 16 "nombre de disco con ruta"                --dry-run --disco ../x.qcow2 pruebas1
    espera_codigo 14 "contraseña con tilde"                    --dry-run --ssh-pass "contraseñá" pruebas1
    espera_codigo 40 "--red inexistente"                       --dry-run --red red-que-no-existe-xyz pruebas1
    espera_codigo 41 "IP que es la pasarela"                   --dry-run pruebas1 "$GW"
    espera_codigo 41 "IP de otra subred"                       --dry-run pruebas1 10.9.9.9
    espera_codigo 41 "IP mal formada"                          --dry-run pruebas1 192.168.1.999
    espera_codigo 42 "IP dentro del rango DHCP"                --dry-run pruebas1 "${GW%.*}.200"
    espera_codigo 10 "--gluster-cluster con MAQUINA"           --dry-run --gluster-cluster pruebas1
    if [[ -n "$IP_LIBRE" ]]; then
        espera_codigo 0 "--dry-run con IP libre y discos extra" --dry-run --limpiar --extra-disks pruebas1 "$IP_LIBRE"
    fi
    espera_codigo 0  "--dry-run --limpiar --gluster-cluster (solo enumera)" --dry-run --limpiar --gluster-cluster

    comprueba "el --dry-run no ha creado ningún disco" bash -c "[ ! -e '$SILO/pruebas1.qcow2' ] && [ ! -e '$SILO/pruebas1-vdb.qcow2' ]"
    comprueba "el --dry-run no ha creado ningún dominio" bash -c "! virsh dominfo '${USUARIO}-pruebas1' >/dev/null 2>&1"
    comprueba "el --dry-run escribe en un directorio .dry-run con permisos 700" \
        bash -c "[ \"\$(stat -c %a '$SILO/cloudinit-${USUARIO}-pruebas1.dry-run')\" = 700 ]"
    rm -rf "$SILO"/cloudinit-"${USUARIO}"-*.dry-run

    echo
    echo "  Revisa a mano estos dos mensajes (deben citar la pasarela y las IPs libres de TU red):"
    bash "$SCRIPT" --dry-run pruebas1 "${GW%.*}.200" 2>&1 | sed 's/^/    | /'
    echo
    bash "$SCRIPT" --dry-run --limpiar --gluster-cluster 2>&1 | sed -n '1,/^$/p' | sed 's/^/    | /'
}

########################################
# Fase B: máquinas sueltas
########################################
fase_b() {
    titulo "Fase B: máquinas sueltas"
    descubrir_red
    if ! ssh-add -l >/dev/null 2>&1; then
        ko "tu clave SSH no está cargada en el agente; las comprobaciones por SSH no funcionarían"
        echo "  · Ejecuta antes, en esta misma sesión:  eval \"\$(ssh-agent -s)\" && ssh-add"
        exit 1
    fi
    elimina_maquina pruebas1
    elimina_maquina pruebasgluster
    local salida ip inicio

    # ---------- B1: DHCP ----------
    titulo "B1: pruebas1 con DHCP"
    inicio=$SECONDS
    salida="$(bash "$SCRIPT" pruebas1 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    info "tiempo total: $(( SECONDS - inicio ))s"
    [[ $rc == 0 ]] && ok "termina con código 0" || { ko "código $rc"; echo "$salida" | tail -15 | sed 's/^/    | /'; }
    ip="$(ip_del_resumen "$salida")"
    info "IP: ${ip:-no encontrada en el resumen}"
    grep -q "operativa tras" <<< "$salida" && ok "espera activa: 'operativa tras'" || ko "no aparece 'operativa tras'"
    grep -q "no se ha podido consultar el estado de cloud-init" <<< "$salida" \
        && ko "el agente NO ha permitido consultar cloud-init (revisar qemu-agent-command)" \
        || ok "el estado de cloud-init se ha consultado a través del agente"
    grep -q "Medio de cloud-init expulsado" <<< "$salida" && ok "medio de cloud-init expulsado" || ko "no se expulsó el medio"

    comprueba "el dominio está en ejecución" bash -c "[ \"\$(virsh domstate ${USUARIO}-pruebas1)\" = running ]"
    comprueba "gráficos SPICE en la definición" bash -c "virsh dumpxml ${USUARIO}-pruebas1 | grep -q \"graphics type='spice'\""
    comprueba "sin ISO de cloud-init (activa)"   bash -c "! virsh domblklist ${USUARIO}-pruebas1 | grep -q cloudinit"
    comprueba "sin ISO de cloud-init (persistente)" bash -c "! virsh domblklist ${USUARIO}-pruebas1 --inactive | grep -q cloudinit"
    comprueba "disco COW de debian12.qcow2" bash -c "[ \"\$(qemu-img info --output=json '$SILO/pruebas1.qcow2' | jq -r '.\"backing-filename\"')\" = debian12.qcow2 ]"
    comprueba "directorio cloud-init 700" bash -c "[ \"\$(stat -c %a '$SILO/cloudinit-${USUARIO}-pruebas1')\" = 700 ]"
    comprueba "cip-user.yaml 600" bash -c "[ \"\$(stat -c %a '$SILO/cloudinit-${USUARIO}-pruebas1/cip-user.yaml')\" = 600 ]"

    if [[ -n "$ip" ]]; then
        en_vm_es "$ip" "hostname"                        "pruebas1"      hostname
        en_vm_es "$ip" "cloud-init terminado"            "status: done"  cloud-init status
        en_vm_es "$ip" "qemu-guest-agent activo"         "active"        systemctl is-active qemu-guest-agent
        en_vm_es "$ip" "zona horaria Europe/Madrid"      "Europe/Madrid" timedatectl show -p Timezone --value
        en_vm_es "$ip" "sshd: SSH por contraseña desactivado" "passwordauthentication no" "sudo sshd -T | grep -i '^passwordauthentication'"
        en_vm_es "$ip" "administrador tiene contraseña de consola" "P" "sudo passwd -S administrador | awk '{print \$2}'"
        en_vm_es "$ip" "root tiene contraseña de consola"          "P" "sudo passwd -S root | awk '{print \$2}'"
        en_vm_es "$ip" "sudo sin contraseña"             "root"          sudo id -un
        info "Comprobación manual pendiente: 'virsh console ${USUARIO}-pruebas1' y entrar como root / s1st3mas"
    fi

    # Instantánea en caliente: es el caso del apartado B.6 del manual
    comprueba "instantánea en caliente creada"  virsh snapshot-create-as "${USUARIO}-pruebas1" --atomic --name prueba-b6
    comprueba "instantánea revertida sin error" virsh snapshot-revert "${USUARIO}-pruebas1" prueba-b6
    virsh snapshot-delete "${USUARIO}-pruebas1" prueba-b6 >/dev/null 2>&1

    # ---------- B2: IP fija + discos extra, rehaciendo con --limpiar ----------
    if [[ -z "$IP_LIBRE" ]]; then
        info "No hay IPs libres en tu red: se omite B2"
    else
        titulo "B2: pruebas1 con IP fija $IP_LIBRE y --extra-disks (con --limpiar)"
        inicio=$SECONDS
        salida="$(bash "$SCRIPT" --limpiar --extra-disks pruebas1 "$IP_LIBRE" 2>&1)"; rc=$?
        echo "$salida" >> "$LOG"
        info "tiempo total: $(( SECONDS - inicio ))s"
        [[ $rc == 0 ]] && ok "termina con código 0" || { ko "código $rc"; echo "$salida" | tail -15 | sed 's/^/    | /'; }
        grep -q "^--limpiar: se van a eliminar" <<< "$salida" && ok "--limpiar ha eliminado la máquina anterior" || ko "--limpiar no actuó"
        comprueba "7 discos virtio conectados" bash -c "[ \"\$(virsh domblklist ${USUARIO}-pruebas1 | grep -c '^ vd')\" = 7 ]"
        comprueba "network-config con 'routes:'" grep -q "routes:" "$SILO/cloudinit-${USUARIO}-pruebas1/cip-net.yaml"
        comprueba "el agente reporta la IP fija" bash -c "virsh domifaddr ${USUARIO}-pruebas1 --source agent | grep -q ' $IP_LIBRE/'"

        en_vm_es "$IP_LIBRE" "ruta por defecto hacia la pasarela" "default via $GW dev enp1s0 proto static" "ip route | head -1"
        en_vm_es "$IP_LIBRE" "ping a la pasarela"              "0"  "ping -c2 -W2 $GW >/dev/null 2>&1; echo \$?"
        en_vm_es "$IP_LIBRE" "7 discos virtio dentro de la máquina" "7" "lsblk -dn -o NAME | grep -c '^vd'"
        en_vm_es "$IP_LIBRE" "apt update (DNS y salida a Internet)" "0" "sudo apt-get update >/dev/null 2>&1; echo \$?"
        en_vm_es "$IP_LIBRE" "netplan renderizado con routes"   "1" "sudo grep -c 'to: default' /etc/netplan/50-cloud-init.yaml"
    fi

    # ---------- B3: --ssh-pass ----------
    titulo "B3: pruebas1 con --ssh-pass (con --limpiar)"
    salida="$(bash "$SCRIPT" --limpiar --ssh-pass Prueba123 pruebas1 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    [[ $rc == 0 ]] && ok "termina con código 0" || ko "código $rc"
    ip="$(ip_del_resumen "$salida")"
    if [[ -n "$ip" ]]; then
        en_vm_es "$ip" "sshd: SSH por contraseña activado" "passwordauthentication yes" "sudo sshd -T | grep -i '^passwordauthentication'"
        info "Comprobación manual pendiente: 'ssh -o PubkeyAuthentication=no administrador@$ip' con la contraseña Prueba123"
    fi

    # ---------- B4: --glusterfs ----------
    titulo "B4: pruebasgluster con --glusterfs"
    inicio=$SECONDS
    salida="$(bash "$SCRIPT" --glusterfs pruebasgluster 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    info "tiempo total: $(( SECONDS - inicio ))s"
    [[ $rc == 0 ]] && ok "termina con código 0" || ko "código $rc"
    ip="$(ip_del_resumen "$salida")"
    if [[ -n "$ip" ]]; then
        en_vm_es "$ip" "glusterd habilitado"   "enabled"  systemctl is-enabled glusterd
        en_vm_es "$ip" "glusterd no arrancado" "inactive" systemctl is-active glusterd
        en_vm_es "$ip" "xfsprogs instalado"    "0"        "command -v mkfs.xfs >/dev/null; echo \$?"
        en_vm_es "$ip" "machine-id vacío"      "0"        "wc -c < /etc/machine-id"
        en_vm_es "$ip" "cloud-init terminado"  "status: done" cloud-init status
    fi

    if [[ -z "${CONSERVAR:-}" ]]; then
        elimina_maquina pruebas1
        elimina_maquina pruebasgluster
        info "máquinas de prueba eliminadas (CONSERVAR=1 para mantenerlas)"
    fi
}

########################################
# Fase C: clúster GlusterFS
########################################
fase_c() {
    titulo "Fase C: clúster GlusterFS"
    descubrir_red
    if ! ssh-add -l >/dev/null 2>&1; then
        ko "tu clave SSH no está cargada en el agente; las comprobaciones por SSH no funcionarían"
        echo "  · Ejecuta antes, en esta misma sesión:  eval \"\$(ssh-agent -s)\" && ssh-add"
        exit 1
    fi

    local -a extra=()
    local salida rc inicio
    salida="$(bash "$SCRIPT" --dry-run --gluster-cluster 2>&1)"; rc=$?
    if [[ $rc == 21 ]]; then
        if [[ -z "${LIMPIAR:-}" ]]; then
            echo "  Ya existen elementos que el clúster tendría que crear:"
            echo "$salida" | sed -n '/Ya existen/,/^$/p' | sed 's/^/    | /'
            echo
            echo "  Si quieres que el script los elimine (solo esos), repite con:"
            echo "    LIMPIAR=1 bash $0 c"
            exit 1
        fi
        extra=( --limpiar )
        info "se usará --limpiar; el script enumerará lo que elimina"
    elif [[ $rc != 0 ]]; then
        ko "el --dry-run del clúster falla con código $rc"
        echo "$salida" | head -10 | sed 's/^/    | /'
        exit 1
    fi

    inicio=$SECONDS
    salida="$(bash "$SCRIPT" ${extra[@]+"${extra[@]}"} --gluster-cluster 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    info "tiempo total: $(( SECONDS - inicio ))s"
    [[ $rc == 0 ]] && ok "termina con código 0" || { ko "código $rc"; echo "$salida" | tail -20 | sed 's/^/    | /'; }
    echo "$salida" | grep -E "operativa tras|Base lista|Deshaciendo|AVISO|ERROR" | sed 's/^/    | /'

    comprueba "la base ya no existe como dominio" bash -c "! virsh dominfo ${USUARIO}-glusterbase >/dev/null 2>&1"
    comprueba "glusterbase.qcow2 se conserva" test -f "$SILO/glusterbase.qcow2"

    local i h ip mids=() hks=()
    for i in 0 1 2 3; do
        h="server$(( i + 1 ))"
        ip="${GW%.*}.$(( 10 + i ))"
        titulo "Nodo $h ($ip)"
        comprueba "dominio en ejecución" bash -c "[ \"\$(virsh domstate ${USUARIO}-$h)\" = running ]"
        comprueba "8 discos virtio conectados" bash -c "[ \"\$(virsh domblklist ${USUARIO}-$h | grep -c '^ vd')\" = 8 ]"
        comprueba "COW de glusterbase.qcow2" bash -c "[ \"\$(qemu-img info --output=json '$SILO/$h.qcow2' | jq -r '.\"backing-filename\"')\" = glusterbase.qcow2 ]"
        comprueba "sin ISO de cloud-init" bash -c "! virsh domblklist ${USUARIO}-$h | grep -q cloudinit"
        comprueba "el agente reporta la IP $ip" bash -c "virsh domifaddr ${USUARIO}-$h --source agent | grep -q ' $ip/'"

        en_vm_es "$ip" "hostname"                    "$h"           hostname
        en_vm_es "$ip" "cloud-init terminado"        "status: done" cloud-init status
        en_vm_es "$ip" "3 montajes xfs en /gluster*" "3"            "mount -t xfs | grep -c ' /gluster[123] '"
        en_vm_es "$ip" "8 discos dentro de la máquina" "8"          "lsblk -dn -o NAME | grep -c '^vd'"
        en_vm_es "$ip" "vde sin formatear"           ""             "lsblk -no FSTYPE /dev/vde"
        en_vm_es "$ip" "resuelve server1..4 por /etc/hosts" "4"     "getent hosts server1 server2 server3 server4 | wc -l"
        en_vm_es "$ip" "glusterd habilitado"         "enabled"      systemctl is-enabled glusterd
        en_vm_es "$ip" "glusterd en ejecución"       "active"       systemctl is-active glusterd
        en_vm_es "$ip" "1 vCPU"                      "1"            nproc
        en_vm_es "$ip" "zona horaria Europe/Madrid"  "Europe/Madrid" timedatectl show -p Timezone --value
        mids+=( "$(en_vm "$ip" cat /etc/machine-id 2>/dev/null)" )
        hks+=( "$(en_vm "$ip" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null)" )
    done

    titulo "Entre nodos"
    comprueba "los 4 machine-id son distintos" bash -c "[ \"\$(printf '%s\n' \"\$@\" | sort -u | wc -l)\" = 4 ]" _ "${mids[@]}"
    comprueba "las 4 claves SSH de host son distintas" bash -c "[ \"\$(printf '%s\n' \"\$@\" | sort -u | wc -l)\" = 4 ]" _ "${hks[@]}"
    local ip1="${GW%.*}.10"
    en_vm_es "$ip1" "server1 hace ping a server2 por nombre" "0" "ping -c2 -W2 server2 >/dev/null 2>&1; echo \$?"
    en_vm_es "$ip1" "gluster peer probe server2"     "peer probe: success" "sudo gluster peer probe server2"
    sleep 3
    en_vm_es "$ip1" "server2 aparece como peer"      "1" "sudo gluster peer status | grep -c '^Hostname: server2'"
    en_vm "$ip1" "sudo gluster peer detach server2" >>"$LOG" 2>&1

    echo
    if [[ -z "${CONSERVAR:-}" ]]; then
        info "El clúster se conserva para que puedas inspeccionarlo. Para eliminarlo:"
    else
        info "Para eliminar el clúster:"
    fi
    echo "      for m in server1 server2 server3 server4; do virsh destroy ${USUARIO}-\$m; virsh undefine ${USUARIO}-\$m --snapshots-metadata; done"
    echo "      cd $SILO && rm -f glusterbase.qcow2 server[1-4].qcow2 server[1-4]-vd?.qcow2 && rm -rf cloudinit-${USUARIO}-*"
}

########################################
# Main
########################################
[[ -f "$SCRIPT" ]] || { echo "No encuentro $SCRIPT"; exit 1; }
echo "Script : $SCRIPT"
echo "Silo   : $SILO"
echo "Usuario: $USUARIO"
echo "Log    : $LOG"

case "$FASE" in
    a)     fase_a ;;
    b)     fase_b ;;
    c)     fase_c ;;
    todas) fase_a; fase_b; fase_c ;;
    *)     echo "Fase desconocida '$FASE'. Usa: a | b | c | todas"; exit 1 ;;
esac

echo
echo "═══ Resultado: $OK correctas, $KO fallidas. Detalle en $LOG ═══"
exit $(( KO > 0 ))
