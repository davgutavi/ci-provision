#!/bin/bash
# Batería de pruebas de ci-provision.sh en un servidor de la asignatura.
# Ejecuta el script de verdad contra libvirt y comprueba el resultado, también
# por dentro de las máquinas (por SSH, con tu clave).
#
# Uso, desde cualquier directorio:
#   bash tools/pruebas-servidor.sh a        Fase A: validaciones. NO crea nada.
#   bash tools/pruebas-servidor.sh b        Fase B: máquinas sueltas (pruebas1, pruebasgluster, pruebasnoble)
#   bash tools/pruebas-servidor.sh c        Fase C: clúster GlusterFS (gluster-base, server1..4)
#   bash tools/pruebas-servidor.sh todas
#
# Variables opcionales:
#   LIMPIAR=1        En la fase C, pasa --limpiar al script si ya existen
#                    server1..4 o gluster-base (el propio script enumera qué borra).
#   CONSERVAR=1      No eliminar las máquinas de prueba ni el clúster al terminar
#                    (como la clave de pruebas se borra, solo se podrá entrar en
#                    ellas por consola). Sin ella, no queda nada en marcha.
#   SIN_MYSQL=1      En la fase C, omitir la prueba de MySQL en Podman (unos 3 min).
#   PREFIJO=xxx      En la fase C, crear el clúster como xxx-server1..4 (con
#                    --prefijo), para no chocar con tus máquinas server1..4.
#
# Para entrar en las máquinas de prueba la batería usa una clave de usar y
# tirar: la genera al empezar (sin frase de paso, en un directorio propio de
# tu home), se la pone a las máquinas con CI_PROVISION_PUBKEY y la borra al
# terminar. Tus claves no intervienen y no hace falta ningún agente SSH. Si se
# filtrara, solo abriría las máquinas de prueba, que también se eliminan.

set -uo pipefail
export LC_ALL=C
# Por SSH sin terminal (ssh servidor 'bash tools/...') virsh no lee la
# configuración de la sesión y se conectaría a qemu:///session
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
NOBLE="noble-server-cloudimg-amd64.img"

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
# Colores solo si la salida es un terminal: así se puede filtrar con
#   ... | grep -E '^(═|  [✔✘·])'
if [[ -t 1 ]]; then V=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'; else V=""; R=""; N=""; fi

titulo() { echo; echo "═══ $* ═══"; }
ok()     { OK=$(( OK + 1 )); printf '  %s✔%s %s\n' "$V" "$N" "$*"; }
ko()     { KO=$(( KO + 1 )); printf '  %s✘%s %s\n' "$R" "$N" "$*"; }
info()   { printf '  · %s\n' "$*"; }

# comprueba DESCRIPCION COMANDO...   (éxito = ok)
comprueba() {
    local desc="$1"; shift
    if "$@" >>"$LOG" 2>&1; then ok "$desc"; else ko "$desc"; fi
}

# Ejecuta el script sin teclado, para que ninguna orden pueda quedarse
# esperando, y con --si: las confirmaciones de --limpiar y --eliminar las da la
# batería (sin terminal y sin --si, el script se negaría con el error 23)
ejecutar_script() {
    bash "$SCRIPT" --si "$@" </dev/null
}

# espera_codigo CODIGO DESCRIPCION ARGS...   ejecuta el script y compara el código
espera_codigo() {
    local esperado="$1" desc="$2"; shift 2
    local salida rc
    salida="$(ejecutar_script "$@" 2>&1)"; rc=$?
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
# -n: la orden remota no recibe el teclado. Si algo pidiera confirmación,
# fallaría en vez de quedarse esperando sin que se vea la pregunta.
en_vm() {
    local ip="$1"; shift
    ssh -n -i "$CLAVE_DIR/clave" -o IdentitiesOnly=yes -o IdentityAgent=none \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "administrador@$ip" "$@"
}

# en_vm_es IP DESCRIPCION VALOR_ESPERADO COMANDO
en_vm_es() {
    local ip="$1" desc="$2" esperado="$3"; shift 3
    local obtenido
    # Se recorta el espacio final: 'ip route', por ejemplo, termina sus líneas con uno
    obtenido="$(en_vm "$ip" "$@" 2>>"$LOG" | tr -d '\r' | head -1 | sed 's/[[:space:]]*$//')"
    if [[ "$obtenido" == "$esperado" ]]; then
        ok "$desc"
    else
        ko "$desc → esperaba '$esperado', obtuve '$obtenido'"
    fi
}

# Errores y avisos de la ejecución de cloud-init que configuró la máquina.
# Tras el reinicio en frío del script, 'cloud-init status' dice "disabled" (ya no
# está su CD-ROM), pero el resultado de aquella ejecución queda en result.json.
CI_SIN_ERRORES='sudo python3 -c "import json; r = json.load(open(\"/var/lib/cloud/data/result.json\"))[\"v1\"]; print(len(r.get(\"errors\") or []) + len(r.get(\"recoverable_errors\") or {}))"'

# Comprueba que la contraseña de root es s1st3mas (sin mostrar nada de shadow)
ROOT_ES_S1ST3MAS="perl -e '\$h=(getpwnam(q(root)))[1]; print crypt(q(s1st3mas),\$h) eq \$h ? qq(si) : qq(no)'"

# on_reboot de la definición con la que se ejecuta la máquina: tiene que ser
# 'restart' (si fuera 'destroy', el primer reboot desde dentro la apagaría)
reinicia_bien() {   # DOMINIO
    # Sin tubería hacia 'grep -q': con pipefail, su SIGPIPE haría fallar la prueba
    local xml
    xml="$(virsh dumpxml "$1" 2>/dev/null)"
    grep -q '<on_reboot>restart</on_reboot>' <<< "$xml"
}

# 'sudo systemctl reboot' dentro de la máquina; éxito si vuelve a estar en
# marcha y a responder en su IP (y no se queda apagada)
reinicia_desde_dentro() {   # IP DOMINIO
    local ip="$1" d="$2" i
    en_vm "$ip" "sudo systemctl reboot" >/dev/null 2>&1
    sleep 10
    for i in $(seq 60); do
        if [[ "$(virsh domstate "$d" 2>/dev/null)" == "shut off" ]]; then
            return 1
        fi
        if virsh domifaddr "$d" --source agent 2>/dev/null | grep -q " $ip/"; then
            return 0
        fi
        sleep 3
    done
    return 1
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
    salida="$(ejecutar_script --dry-run --limpiar pruebas1 2>&1)" || {
        echo "No puedo ni hacer un --dry-run. Salida:"; echo "$salida"; exit 1; }
    RED="$(sed -n 's/^    Red     : \([^ ]*\).*/\1/p' <<< "$salida" | head -1)"
    GW="$(sed -n 's/.*pasarela \([0-9.]*\),.*/\1/p' <<< "$salida" | head -1)"

    # Una IP dentro del rango DHCP de la red real (la primera del primer rango)
    IP_DHCP="$(virsh net-dumpxml "$RED" 2>/dev/null | sed -n "s/.*<range start='\([0-9.]*\)'.*/\1/p" | head -1)"
    [[ -n "$IP_DHCP" ]] || IP_DHCP="${GW%.*}.200"

    # Pedimos una IP que no puede ser de ninguna red (203.0.113.0/24 está
    # reservada para documentación): falla con 41 y enumera los bloques libres
    salida="$(ejecutar_script --dry-run pruebas1 203.0.113.9 2>&1)"
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
    local salida
    titulo "Fase A: validaciones (no se crea nada)"
    descubrir_red
    info "Red detectada: $RED (pasarela $GW). IP libre para pruebas: ${IP_LIBRE:-ninguna}"

    espera_codigo 0  "ayuda"                                   -h
    espera_codigo 10 "sin parámetros"
    espera_codigo 10 "sintaxis antigua (4 posicionales)"       u-s1 s1.qcow2 s1 red
    espera_codigo 12 "opción antigua --enable-root"            --enable-root pruebas1
    espera_codigo 12 "opción antigua --user-pass"              --user-pass x pruebas1
    espera_codigo 12 "opción antigua --virt-viewer"            --virt-viewer pruebas1
    espera_codigo 12 "opción con = en vez de espacio"          --dry-run --ram=2048 pruebas1
    espera_codigo 11 "--ssh-pass seguido de otra opción"       --dry-run --ssh-pass --extra-disks pruebas1
    espera_codigo 10 "--glusterfs con --extra-disks"           --dry-run --glusterfs --extra-disks pruebasgluster
    espera_codigo 20 "nombre con el usuario delante"           --dry-run "${USUARIO}-pruebas1"
    espera_codigo 10 "--menu con MAQUINA"                      --menu pruebas1
    espera_codigo 12 "opción desconocida"                      --noexiste pruebas1
    espera_codigo 11 "opción sin valor"                        pruebas1 --ram
    espera_codigo 20 "nombre de máquina inválido"              "a b"
    espera_codigo 13 "RAM no numérica"                         --dry-run --ram abc pruebas1
    espera_codigo 15 "tamaño de disco inválido"                --dry-run --tam 40 pruebas1
    espera_codigo 16 "nombre de disco con ruta"                --dry-run --disco ../x.qcow2 pruebas1
    espera_codigo 16 "--base con ruta"                         --dry-run --base ../x.qcow2 pruebas1
    espera_codigo 39 "--base inexistente"                      --dry-run --limpiar --base no-existe-xyz.qcow2 pruebas1
    espera_codigo 14 "contraseña con tilde"                    --dry-run --ssh-pass "contraseñá" pruebas1
    espera_codigo 40 "--red inexistente"                       --dry-run --red red-que-no-existe-xyz pruebas1
    espera_codigo 41 "IP que es la pasarela"                   --dry-run pruebas1 "$GW"
    espera_codigo 41 "IP de otra subred"                       --dry-run pruebas1 10.9.9.9
    espera_codigo 41 "IP mal formada"                          --dry-run pruebas1 192.168.1.999
    espera_codigo 42 "IP dentro del rango DHCP"                --dry-run pruebas1 "$IP_DHCP"
    espera_codigo 10 "--gluster-cluster con MAQUINA"           --dry-run --gluster-cluster pruebas1
    espera_codigo 10 "--imagen desconocida"                    --dry-run --imagen fedora pruebas1
    espera_codigo 10 "--imagen ubuntu-base en una máquina suelta" --dry-run --imagen ubuntu-base pruebas1
    espera_codigo 10 "--imagen desconocida con --base"         --dry-run --imagen fedora --base debian12.qcow2 pruebas1
    espera_codigo 10 "--discos-nodo sin --gluster-cluster"     --dry-run --discos-nodo 7 pruebas1
    espera_codigo 13 "--discos-nodo fuera de rango"            --dry-run --gluster-cluster --discos-nodo 8
    espera_codigo 10 "máquina llamada como una imagen cloud"   --dry-run --limpiar debian12
    if [[ -n "$IP_LIBRE" ]]; then
        espera_codigo 0 "--dry-run con IP libre y discos extra" --dry-run --limpiar --extra-disks pruebas1 "$IP_LIBRE"
    fi
    espera_codigo 0  "--dry-run --limpiar --gluster-cluster (solo enumera)" --dry-run --limpiar --gluster-cluster
    salida="$(ejecutar_script --dry-run --limpiar --no-virt-viewer pruebas1 2>&1)"
    grep -q -- '--graphics none' <<< "$salida" && ok "--dry-run --no-virt-viewer: el comando lleva --graphics none" || ko "--no-virt-viewer no cambia --graphics"
    salida="$(ejecutar_script --dry-run --prefijo demo pruebas1 2>&1)"
    grep -q -- '--name demo-pruebas1' <<< "$salida" && grep -q 'demo-pruebas1.qcow2' <<< "$salida" && ok "--dry-run --prefijo demo: dominio y disco con prefijo" || ko "--prefijo no se aplica a dominio y disco"
    grep -q -- '--os-variant ubuntu24.04' <<< "$salida" && grep -q "copia COW de $NOBLE" <<< "$salida" && ok "--dry-run: por defecto, Ubuntu 24.04 ($NOBLE)" || ko "la imagen por defecto no es Noble"
    salida="$(ejecutar_script --dry-run --prefijo demo --imagen debian12 pruebas1 2>&1)"
    grep -q -- '--os-variant debian12' <<< "$salida" && grep -q "copia COW de debian12.qcow2" <<< "$salida" && ok "--dry-run --imagen debian12: Debian 12" || ko "--imagen debian12 no cambia la imagen"
    salida="$(ejecutar_script --dry-run --prefijo demo --gluster-cluster 2>&1)"
    grep -q "copia COW de $NOBLE, 40G" <<< "$salida" && ok "--dry-run --gluster-cluster: base COW de $NOBLE" || ko "la base del clúster no sale de la imagen de Ubuntu"
    salida="$(ejecutar_script --dry-run --prefijo demo --gluster-cluster --imagen ubuntu-base 2>&1)"
    grep -q "copia completa de /home/ssoo-shared/ubuntu-base.qcow2, 64G" <<< "$salida" && ok "--dry-run --gluster-cluster --imagen ubuntu-base: copia completa (64G)" || ko "--imagen ubuntu-base no copia ubuntu-base"

    comprueba "el --dry-run no ha creado ningún disco" bash -c "[ ! -e '$SILO/pruebas1.qcow2' ] && [ ! -e '$SILO/pruebas1-vdb.qcow2' ]"
    comprueba "el --dry-run no ha creado ningún dominio" bash -c "! virsh dominfo '${USUARIO}-pruebas1' >/dev/null 2>&1"
    comprueba "el --dry-run escribe en un directorio .dry-run con permisos 700" \
        bash -c "[ \"\$(stat -c %a '$SILO/cloudinit-${USUARIO}-pruebas1.dry-run')\" = 700 ]"
    rm -rf "$SILO"/cloudinit-"${USUARIO}"-*.dry-run "$SILO"/cloudinit-demo-*.dry-run "$SILO"/cloudinit-otro-*.dry-run

    echo
    echo "  Revisa a mano estos dos mensajes (deben citar la pasarela y las IPs libres de TU red):"
    ejecutar_script --dry-run pruebas1 "$IP_DHCP" 2>&1 | sed 's/^/    | /'
    echo
    ejecutar_script --dry-run --limpiar --gluster-cluster 2>&1 | sed -n '1,/^$/p' | sed 's/^/    | /'
    # Los --dry-run dejan sus ficheros en cloudinit-*.dry-run: fuera
    rm -rf "$SILO"/cloudinit-"${USUARIO}"-*.dry-run "$SILO"/cloudinit-demo-*.dry-run "$SILO"/cloudinit-otro-*.dry-run
}

########################################
# Fase B: máquinas sueltas
########################################
fase_b() {
    titulo "Fase B: máquinas sueltas"
    descubrir_red
    elimina_maquina pruebas1
    elimina_maquina pruebasgluster
    elimina_maquina pruebasub
    local salida ip inicio

    # ---------- B1: DHCP ----------
    titulo "B1: pruebas1 con DHCP (Ubuntu 24.04, la imagen por defecto)"
    inicio=$SECONDS
    salida="$(ejecutar_script pruebas1 2>&1)"; rc=$?
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
    grep -q "pruebas1 reiniciada" <<< "$salida" && ok "reiniciada en frío al terminar" || ko "no se reinició en frío"
    comprueba "on_reboot=restart en la definición en ejecución" reinicia_bien "${USUARIO}-pruebas1"

    comprueba "el dominio está en ejecución" bash -c "[ \"\$(virsh domstate ${USUARIO}-pruebas1)\" = running ]"
    comprueba "gráficos SPICE en la definición" bash -c "virsh dumpxml ${USUARIO}-pruebas1 | grep -q \"graphics type='spice'\""
    comprueba "sin ISO de cloud-init (activa)"   bash -c "! virsh domblklist ${USUARIO}-pruebas1 | grep -q cloudinit"
    comprueba "sin ISO de cloud-init (persistente)" bash -c "! virsh domblklist ${USUARIO}-pruebas1 --inactive | grep -q cloudinit"
    comprueba "disco COW de $NOBLE" bash -c "[ \"\$(qemu-img info -U --output=json '$SILO/pruebas1.qcow2' | jq -r '.\"backing-filename\"')\" = $NOBLE ]"
    comprueba "variante de SO ubuntu24.04" bash -c "virsh dumpxml ${USUARIO}-pruebas1 | grep -q 'ubuntu.com/ubuntu/24.04'"
    comprueba "directorio cloud-init 700" bash -c "[ \"\$(stat -c %a '$SILO/cloudinit-${USUARIO}-pruebas1')\" = 700 ]"
    comprueba "cip-user.yaml 600" bash -c "[ \"\$(stat -c %a '$SILO/cloudinit-${USUARIO}-pruebas1/cip-user.yaml')\" = 600 ]"

    if [[ -n "$ip" ]]; then
        en_vm_es "$ip" "hostname"                        "pruebas1"      hostname
        en_vm_es "$ip" "cloud-init terminó (boot-finished)" "si"         "test -f /var/lib/cloud/instance/boot-finished && echo si"
        en_vm_es "$ip" "cloud-init sin errores ni avisos" "0"            "$CI_SIN_ERRORES"
        en_vm_es "$ip" "Ubuntu 24.04"                    "24.04"         ". /etc/os-release; echo \$VERSION_ID"
        en_vm_es "$ip" "interfaz enp1s0"                 "enp1s0"        "ip -br link | awk '\$1 != \"lo\" {print \$1}'"
        en_vm_es "$ip" "qemu-guest-agent activo"         "active"        systemctl is-active qemu-guest-agent
        en_vm_es "$ip" "zona horaria Europe/Madrid"      "Europe/Madrid" timedatectl show -p Timezone --value
        en_vm_es "$ip" "sshd: SSH por contraseña desactivado" "passwordauthentication no" "sudo sshd -T | grep -i '^passwordauthentication'"
        en_vm_es "$ip" "administrador sin contraseña propia" "sin-contraseña" "sudo passwd -S administrador | awk '{print (\$2==\"P\")?\"con-contraseña\":\"sin-contraseña\"}'"
        en_vm_es "$ip" "root tiene contraseña de consola"    "P"              "sudo passwd -S root | awk '{print \$2}'"
        en_vm_es "$ip" "la contraseña de root es s1st3mas"   "si"             "sudo $ROOT_ES_S1ST3MAS"
        en_vm_es "$ip" "sudo sin contraseña"             "root"          sudo id -un
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
        salida="$(ejecutar_script --limpiar --extra-disks pruebas1 "$IP_LIBRE" 2>&1)"; rc=$?
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
        en_vm_es "$IP_LIBRE" "netplan renderizado con routes"   "1" "sudo grep -c 'to: \"\\?default' /etc/netplan/50-cloud-init.yaml"
        en_vm_es "$IP_LIBRE" "apt instala lvm2 (boletín 2, 2.2 a)" "0" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lvm2 >/dev/null 2>&1; echo \$?"
        comprueba "on_reboot=restart en la definición en ejecución" reinicia_bien "${USUARIO}-pruebas1"
        comprueba "'sudo systemctl reboot' desde dentro: vuelve a arrancar (no se apaga)" reinicia_desde_dentro "$IP_LIBRE" "${USUARIO}-pruebas1"

        # Instantáneas internas como en los epígrafes 2.1 e) y o)-s) del boletín:
        # en caliente con los seis discos, en frío, detach-disk de vdb y reversión
        local d="${USUARIO}-pruebas1"
        comprueba "sin CD-ROM con medio (nada que impida instantáneas internas)" bash -c "! virsh domblklist $d | awk 'NR>2 && NF && \$2 != \"-\"' | grep -qv '\.qcow2\$'"
        comprueba "instantánea 'inicio' en caliente con 7 discos (--atomic)" virsh snapshot-create-as "$d" --name inicio --atomic
        comprueba "la instantánea 'inicio' guarda on_reboot=restart" bash -c "virsh snapshot-dumpxml $d inicio | grep -q '<on_reboot>restart</on_reboot>'"
        comprueba "apagado limpio" bash -c "virsh shutdown $d >/dev/null; for i in \$(seq 60); do [ \"\$(virsh domstate $d)\" = 'shut off' ] && exit 0; sleep 2; done; exit 1"
        comprueba "instantánea 'antesdeliarla' en frío (--atomic)" virsh snapshot-create-as "$d" --name antesdeliarla --atomic
        comprueba "detach-disk de \$PWD/pruebas1-vdb.qcow2, como en el boletín" bash -c "cd '$SILO' && virsh detach-disk $d \$PWD/pruebas1-vdb.qcow2 --persistent"
        comprueba "revertir 'antesdeliarla' recupera vdb (7 discos)" bash -c "virsh snapshot-revert $d antesdeliarla && [ \"\$(virsh domblklist $d | grep -c '^ vd')\" = 7 ]"
        comprueba "revertir 'inicio' deja la máquina en marcha" bash -c "virsh snapshot-revert $d inicio && [ \"\$(virsh domstate $d)\" = running ]"
        comprueba "tras revertir 'inicio', on_reboot sigue siendo restart" reinicia_bien "$d"
        comprueba "tras revertir 'inicio', un reboot desde dentro no la apaga" reinicia_desde_dentro "$IP_LIBRE" "$d"
        virsh snapshot-delete "$d" antesdeliarla >/dev/null 2>&1
        virsh snapshot-delete "$d" inicio >/dev/null 2>&1
    fi

    # ---------- B3: --ssh-pass, --no-root y --no-virt-viewer ----------
    titulo "B3: pruebas1 con Debian 12 (--imagen debian12), --ssh-pass, --no-root y --no-virt-viewer (con --limpiar)"
    salida="$(ejecutar_script --limpiar --imagen debian12 --no-root --no-virt-viewer --ssh-pass Prueba123 pruebas1 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    [[ $rc == 0 ]] && ok "termina con código 0" || ko "código $rc"
    comprueba "sin consola gráfica (--no-virt-viewer)" bash -c "! virsh dumpxml ${USUARIO}-pruebas1 | grep -q \"graphics type='spice'\""
    comprueba "disco COW de debian12.qcow2" bash -c "[ \"\$(qemu-img info -U --output=json '$SILO/pruebas1.qcow2' | jq -r '.\"backing-filename\"')\" = debian12.qcow2 ]"
    comprueba "variante de SO debian12" bash -c "virsh dumpxml ${USUARIO}-pruebas1 | grep -q 'debian.org/debian/12'"
    ip="$(ip_del_resumen "$salida")"
    if [[ -n "$ip" ]]; then
        en_vm_es "$ip" "Debian 12"                          "12"             ". /etc/os-release; echo \$VERSION_ID"
        en_vm_es "$ip" "cloud-init sin errores (sintaxis nueva de chpasswd en Debian)" "0" "$CI_SIN_ERRORES"
        en_vm_es "$ip" "sshd: SSH por contraseña activado" "passwordauthentication yes" "sudo sshd -T | grep -i '^passwordauthentication'"
        en_vm_es "$ip" "administrador con contraseña"      "con-contraseña" "sudo passwd -S administrador | awk '{print (\$2==\"P\")?\"con-contraseña\":\"sin-contraseña\"}'"
        en_vm_es "$ip" "root sin contraseña (--no-root)"   "sin-contraseña" "sudo passwd -S root | awk '{print (\$2==\"P\")?\"con-contraseña\":\"sin-contraseña\"}'"
        IP_B3="$ip"
    fi

    # ---------- B4: --glusterfs (imagen base: al final solo queda el disco) ----------
    titulo "B4: pruebasgluster con --glusterfs (desde la imagen de Ubuntu)"
    inicio=$SECONDS
    salida="$(ejecutar_script --glusterfs pruebasgluster 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    info "tiempo total: $(( SECONDS - inicio ))s"
    [[ $rc == 0 ]] && ok "termina con código 0" || { ko "código $rc"; echo "$salida" | tail -8 | sed 's/^/    | /'; }
    grep -q "operativa tras" <<< "$salida" && ok "espera a que cloud-init termine" || ko "no esperó"
    grep -q "Imagen base GlusterFS lista" <<< "$salida" && ok "resumen de imagen base" || ko "sin resumen de base"
    comprueba "el dominio se ha eliminado" bash -c "! virsh dominfo ${USUARIO}-pruebasgluster >/dev/null 2>&1"
    comprueba "el disco base se conserva, COW de $NOBLE" bash -c "[ \"\$(qemu-img info -U --output=json '$SILO/pruebasgluster.qcow2' | jq -r '.\"backing-filename\"')\" = $NOBLE ]"
    info "el contenido de la base (glusterd, xfsprogs, machine-id) se comprueba en la fase C, dentro de los nodos"

    # ---------- B4b: --glusterfs --imagen ubuntu-base (como la construcción manual) ----------
    titulo "B4b: pruebasub con --glusterfs --imagen ubuntu-base"
    inicio=$SECONDS
    salida="$(ejecutar_script --glusterfs --imagen ubuntu-base pruebasub 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    info "tiempo total: $(( SECONDS - inicio ))s"
    [[ $rc == 0 ]] && ok "termina con código 0" || { ko "código $rc"; echo "$salida" | tail -8 | sed 's/^/    | /'; }
    comprueba "el dominio se ha eliminado" bash -c "! virsh dominfo ${USUARIO}-pruebasub >/dev/null 2>&1"
    comprueba "pruebasub.qcow2 es una copia completa (sin respaldo)" bash -c "[ \"\$(qemu-img info -U --output=json '$SILO/pruebasub.qcow2' | jq -r '.\"backing-filename\" // \"ninguno\"')\" = ninguno ]"
    comprueba "con el tamaño de ubuntu-base (64 GiB)" bash -c "[ \"\$(qemu-img info -U --output=json '$SILO/pruebasub.qcow2' | jq -r '.\"virtual-size\"')\" = 68719476736 ]"
    comprueba "ubuntu-base.qcow2 original intacta" bash -c "[ \"\$(stat -c %Y /home/ssoo-shared/ubuntu-base.qcow2)\" -lt \"\$(stat -c %Y '$SILO/pruebasub.qcow2')\" ]"

    # ---------- B5: --listar y --eliminar ----------
    titulo "B5: --listar, --dry-run --eliminar-todo y --eliminar"
    salida="$(ejecutar_script --listar 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    [[ $rc == 0 ]] && ok "--listar termina con código 0" || ko "--listar: código $rc"
    grep -q "${USUARIO}-pruebas1 .*en ejecución" <<< "$salida" && ok "--listar muestra pruebas1 en ejecución" || ko "--listar no muestra pruebas1"
    grep -q "pruebasgluster.qcow2 .*copia de $NOBLE" <<< "$salida" && ok "--listar muestra pruebasgluster.qcow2 como disco sin máquina" || ko "--listar no muestra pruebasgluster.qcow2"
    grep -q "$NOBLE .*imagen cloud de Ubuntu" <<< "$salida" && ok "--listar muestra la imagen de Ubuntu como imagen cloud" || ko "--listar no muestra $NOBLE"
    echo "$salida" | sed 's/^/    | /'
    salida="$(ejecutar_script --dry-run --eliminar-todo 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    [[ $rc == 0 ]] && ok "--dry-run --eliminar-todo termina con código 0" || ko "--dry-run --eliminar-todo: código $rc"
    comprueba "y no ha eliminado pruebas1" virsh dominfo "${USUARIO}-pruebas1"
    if [[ -z "${CONSERVAR:-}" ]]; then
        salida="$(ejecutar_script --eliminar pruebas1 pruebasgluster pruebasub 2>&1)"; rc=$?
        echo "$salida" >> "$LOG"
        [[ $rc == 0 ]] && ok "--eliminar pruebas1 pruebasgluster pruebasub termina con código 0" || ko "--eliminar: código $rc"
        comprueba "pruebas1 eliminada" bash -c "! virsh dominfo ${USUARIO}-pruebas1 >/dev/null 2>&1"
        comprueba "sus discos, pruebasgluster.qcow2 y pruebasub.qcow2 eliminados" bash -c "! ls $SILO/pruebas1*.qcow2 $SILO/pruebasgluster.qcow2 $SILO/pruebasub.qcow2 >/dev/null 2>&1"
        comprueba "las imágenes cloud siguen ahí" bash -c "[ -f '$SILO/$NOBLE' ] && [ -f '$SILO/debian12.qcow2' ]"
        comprueba "sus ficheros cloud-init eliminados" bash -c "[ ! -d $SILO/cloudinit-${USUARIO}-pruebas1 ]"
    fi

    if [[ -z "${CONSERVAR:-}" ]]; then
        elimina_maquina pruebas1
        elimina_maquina pruebasgluster
        elimina_maquina pruebasub
        info "máquinas de prueba eliminadas (CONSERVAR=1 para mantenerlas)"
    else
        echo
        info "Queda ${USUARIO}-pruebas1 tal como la dejó B3 (Debian, --ssh-pass Prueba123, --no-root, --no-virt-viewer). A mano:"
        info "  ssh -o PubkeyAuthentication=no administrador@${IP_B3:-IP}   debe pedir la contraseña Prueba123 y entrar"
        info "  virsh console ${USUARIO}-pruebas1                          root NO debe poder entrar (--no-root)"
        info "  root / s1st3mas por consola: créala sin --no-root, p. ej. $SCRIPT --limpiar pruebas1"
    fi
}

########################################
# Fase C: clúster GlusterFS
########################################
fase_c() {
    # Con PREFIJO=xxx, el clúster de prueba es xxx-server1..4 y xxx-gluster-base,
    # para no chocar con un clúster o un SERVER1 que tengas con los nombres normales
    local PD="${PREFIJO:-$USUARIO}" PF="${PREFIJO:+$PREFIJO-}"
    local -a PO=()
    if [[ -n "${PREFIJO:-}" ]]; then PO=( --prefijo "$PREFIJO" ); fi
    titulo "Fase C: clúster GlusterFS${PREFIJO:+ (prefijo $PREFIJO)}"
    descubrir_red

    local -a extra=()
    local salida rc inicio
    salida="$(ejecutar_script ${PO[@]+"${PO[@]}"} --dry-run --gluster-cluster 2>&1)"; rc=$?
    if [[ $rc == 21 ]]; then
        if [[ -z "${LIMPIAR:-}" ]]; then
            echo "  Ya existen elementos que el clúster tendría que crear:"
            echo "$salida" | sed -n '/Ya existen/,/^$/p' | sed 's/^/    | /'
            echo
            echo "  Si quieres que el script los elimine (solo esos), repite con:"
            echo "    LIMPIAR=1 bash $0 c      (o, para no tocarlos: PREFIJO=prueba bash $0 c)"
            exit 1
        fi
        extra=( --limpiar )
        info "se usará --limpiar; el script enumerará lo que elimina"
    elif [[ $rc != 0 ]]; then
        ko "el --dry-run del clúster falla con código $rc"
        echo "$salida" | head -10 | sed 's/^/    | /'
        exit 1
    fi

    # ---------- C1: el clúster por defecto (base Noble, 3 discos por nodo) ----------
    titulo "C1: --gluster-cluster (base desde la imagen de Ubuntu, 3 discos por nodo)"
    inicio=$SECONDS
    salida="$(ejecutar_script ${PO[@]+"${PO[@]}"} ${extra[@]+"${extra[@]}"} --gluster-cluster 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    info "tiempo total: $(( SECONDS - inicio ))s"
    [[ $rc == 0 ]] && ok "termina con código 0" || { ko "código $rc"; echo "$salida" | tail -20 | sed 's/^/    | /'; }
    echo "$salida" | grep -E "operativa tras|Base lista|Deshaciendo|AVISO|ERROR" | sed 's/^/    | /'

    comprueba "la base ya no existe como dominio" bash -c "! virsh dominfo ${PD}-gluster-base >/dev/null 2>&1"
    comprueba "gluster-base.qcow2 se conserva, COW de $NOBLE" bash -c "[ \"\$(qemu-img info -U --output=json '$SILO/${PF}gluster-base.qcow2' | jq -r '.\"backing-filename\"')\" = $NOBLE ]"

    local i j h ip esperado mids=() hks=()
    for i in 0 1 2 3; do
        h="server$(( i + 1 ))"
        ip="${GW%.*}.$(( 10 + i ))"
        titulo "Nodo $h ($ip)"
        comprueba "dominio en ejecución" bash -c "[ \"\$(virsh domstate ${PD}-$h)\" = running ]"
        comprueba "4 discos virtio conectados (vda + vdb..vdd)" bash -c "[ \"\$(virsh domblklist ${PD}-$h | grep -c '^ vd')\" = 4 ]"
        comprueba "COW de gluster-base.qcow2" bash -c "[ \"\$(qemu-img info -U --output=json '$SILO/${PF}$h.qcow2' | jq -r '.\"backing-filename\"')\" = ${PF}gluster-base.qcow2 ]"
        comprueba "variante de SO ubuntu24.04" bash -c "virsh dumpxml ${PD}-$h | grep -q 'ubuntu.com/ubuntu/24.04'"
        comprueba "sin ISO de cloud-init" bash -c "! virsh domblklist ${PD}-$h | grep -q cloudinit"
        comprueba "on_reboot=restart en la definición en ejecución" reinicia_bien "${PD}-$h"
        comprueba "el agente reporta la IP $ip" bash -c "virsh domifaddr ${PD}-$h --source agent | grep -q ' $ip/'"

        en_vm_es "$ip" "hostname"                    "$h"           hostname
        en_vm_es "$ip" "cloud-init terminó (boot-finished)" "si"     "test -f /var/lib/cloud/instance/boot-finished && echo si"
        en_vm_es "$ip" "cloud-init sin errores ni avisos" "0"        "$CI_SIN_ERRORES"
        en_vm_es "$ip" "3 montajes xfs en /gluster*" "3"            "mount -t xfs | grep -c ' /gluster[123] '"
        en_vm_es "$ip" "fstab con las líneas de crea-entorno.sh" "3" "grep -c '^/dev/vd[bcd] /gluster[123] xfs auto,async,nofail 0 0$' /etc/fstab"
        en_vm_es "$ip" "xfsprogs instalado"          "install ok installed" "dpkg-query -W -f='\${Status}' xfsprogs"
        en_vm_es "$ip" "4 discos dentro de la máquina" "4"          "lsblk -dn -o NAME | grep -c '^vd'"
        # Cada nombre resuelve a su IP; el propio, a 127.0.1.1 (como con crea-entorno.sh)
        esperado=""
        for j in 0 1 2 3; do
            if (( j == i )); then esperado+="127.0.1.1 "; else esperado+="${GW%.*}.$(( 10 + j )) "; fi
        done
        en_vm_es "$ip" "/etc/hosts: server1..4 resuelven a sus IPs" "${esperado% }" \
            "for n in server1 server2 server3 server4; do getent hosts \$n | awk 'NR==1 {print \$1}'; done | tr '\n' ' ' | sed 's/ \$//'"
        en_vm_es "$ip" "glusterd habilitado"         "enabled"      systemctl is-enabled glusterd
        en_vm_es "$ip" "glusterd en ejecución"       "active"       systemctl is-active glusterd
        en_vm_es "$ip" "cliente de Gluster (mount.glusterfs)" "si"  "test -x /sbin/mount.glusterfs && echo si"
        en_vm_es "$ip" "1 vCPU"                      "1"            nproc
        en_vm_es "$ip" "zona horaria Europe/Madrid"  "Europe/Madrid" timedatectl show -p Timezone --value
        en_vm_es "$ip" "hora sincronizada por NTP activada" "yes"   timedatectl show -p NTP --value
        en_vm_es "$ip" "sudo sin contraseña (como SERVER1)" "root"  sudo -n id -un
        en_vm_es "$ip" "la contraseña de root es s1st3mas" "si"     "sudo $ROOT_ES_S1ST3MAS"
        mids+=( "$(en_vm "$ip" cat /etc/machine-id 2>/dev/null)" )
        hks+=( "$(en_vm "$ip" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null)" )
    done

    titulo "Entre nodos"
    comprueba "los 4 machine-id son distintos" bash -c "[ \"\$(printf '%s\n' \"\$@\" | sort -u | grep -c .)\" = 4 ]" _ "${mids[@]}"
    comprueba "las 4 claves SSH de host son distintas" bash -c "[ \"\$(printf '%s\n' \"\$@\" | sort -u | grep -c .)\" = 4 ]" _ "${hks[@]}"
    local ip1="${GW%.*}.10" ip4="${GW%.*}.13"
    en_vm_es "$ip1" "server1 hace ping a server2 por nombre" "0" "ping -c2 -W2 server2 >/dev/null 2>&1; echo \$?"
    en_vm_es "$ip1" "gluster peer probe server2"     "peer probe: success" "sudo gluster peer probe server2"
    en_vm_es "$ip1" "gluster peer probe server3"     "peer probe: success" "sudo gluster peer probe server3"
    en_vm_es "$ip1" "gluster peer probe server4"     "peer probe: success" "sudo gluster peer probe server4"
    sleep 3
    en_vm_es "$ip1" "3 peers conectados"             "3" "sudo gluster peer status | grep -c 'State: Peer in Cluster (Connected)'"
    comprueba "'sudo systemctl reboot' en server2: vuelve a arrancar (no se apaga)" reinicia_desde_dentro "${GW%.*}.11" "${PD}-server2"
    en_vm_es "${GW%.*}.11" "server2 tras el reinicio: 3 montajes xfs" "3" "mount -t xfs | grep -c ' /gluster[123] '"

    # ---------- C1b: el epígrafe 2.9 e)-h): MySQL en Podman sobre vDisperso, en server4 ----------
    if [[ -n "${SIN_MYSQL:-}" ]]; then
        info "SIN_MYSQL=1: se omite la prueba de MySQL en server4"
    else
        titulo "C1b: vDisperso montado en server4 y MySQL en Podman encima (boletín 2, 2.9 e-h; 1 GB de RAM)"
        for i in 0 1 2; do en_vm "${GW%.*}.$(( 10 + i ))" sudo mkdir -p /gluster3/brick >>"$LOG" 2>&1; done
        en_vm_es "$ip1" "volumen vDisperso creado (disperse 3, redundancy 1)" "volume create: vDisperso: success: please start the volume to access data" \
            "sudo gluster --mode=script volume create vDisperso disperse 3 redundancy 1 server1:/gluster3/brick server2:/gluster3/brick server3:/gluster3/brick"
        en_vm_es "$ip1" "vDisperso iniciado"             "volume start: vDisperso: success" "sudo gluster volume start vDisperso"
        en_vm_es "$ip4" "server4 monta vDisperso en /disperso" "0" "sudo mkdir -p /disperso && sudo mount -t glusterfs server1:/vDisperso /disperso; echo \$?"
        inicio=$SECONDS
        en_vm_es "$ip4" "apt instala podman"             "0" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman >/dev/null 2>&1; echo \$?"
        en_vm_es "$ip4" "contenedor mysql:latest con /var/lib/mysql en /disperso" "0" \
            "sudo podman run -d --name glusterSQL -e MYSQL_ROOT_PASSWORD=pruebas -v /disperso:/var/lib/mysql docker.io/library/mysql:latest >/dev/null 2>&1; echo \$?"
        sleep 90
        en_vm_es "$ip4" "MySQL sigue en marcha a los 90 s" "running" "sudo podman inspect -f '{{.State.Status}}' glusterSQL"
        # La línea del servidor ('port: 3306  MySQL Community Server'), no la del X Plugin (33060)
        en_vm_es "$ip4" "MySQL acepta conexiones"        "1" "sudo podman logs glusterSQL 2>&1 | grep -c 'ready for connections.* port: 3306 '"
        en_vm_es "$ip4" "sin OOM killer"                 "0" "sudo dmesg | grep -ci 'out of memory'"
        info "memoria de server4 con MySQL: $(en_vm "$ip4" "free -m | awk '/^Mem:/ {print \$2\" MB en total, \"\$7\" MB disponibles\"}'" 2>/dev/null); contenedor: $(en_vm "$ip4" "sudo podman stats --no-stream --format '{{.MemUsage}}' glusterSQL" 2>/dev/null)"
        info "tiempo de C1b: $(( SECONDS - inicio ))s"
    fi

    # ---------- C2: rehacer los nodos reutilizando la base, con los 7 discos de crea-entorno.sh ----------
    titulo "C2: los 4 nodos de nuevo a partir de gluster-base.qcow2 (--limpiar --base) con --discos-nodo 7"
    inicio=$SECONDS
    salida="$(ejecutar_script ${PO[@]+"${PO[@]}"} --limpiar --gluster-cluster --base ${PF}gluster-base.qcow2 --discos-nodo 7 2>&1)"; rc=$?
    echo "$salida" >> "$LOG"
    info "tiempo total: $(( SECONDS - inicio ))s"
    [[ $rc == 0 ]] && ok "termina con código 0" || { ko "código $rc"; echo "$salida" | tail -12 | sed 's/^/    | /'; }
    grep -q "Fase 1 de 2: se omite" <<< "$salida" && ok "se omite la fase 1" || ko "no omitió la fase 1"
    comprueba "gluster-base.qcow2 sigue existiendo (--limpiar no lo ha tocado)" test -f "$SILO/${PF}gluster-base.qcow2"
    comprueba "los 4 nodos en ejecución" bash -c "[ \"\$(virsh list --name | grep -c '^${PD}-server[1-4]$')\" = 4 ]"
    comprueba "server3 es COW de gluster-base.qcow2" bash -c "[ \"\$(qemu-img info -U --output=json '$SILO/${PF}server3.qcow2' | jq -r '.\"backing-filename\"')\" = ${PF}gluster-base.qcow2 ]"
    comprueba "server3 con 8 discos virtio (vda + vdb..vdh)" bash -c "[ \"\$(virsh domblklist ${PD}-server3 | grep -c '^ vd')\" = 8 ]"
    ip="${GW%.*}.12"
    en_vm_es "$ip" "server3: hostname"                    "server3"      hostname
    en_vm_es "$ip" "server3: cloud-init sin errores ni avisos" "0"     "$CI_SIN_ERRORES"
    en_vm_es "$ip" "server3: 3 montajes xfs en /gluster*" "3"            "mount -t xfs | grep -c ' /gluster[123] '"
    en_vm_es "$ip" "server3: vde..vdh sin formatear"      ""             "lsblk -no FSTYPE /dev/vde /dev/vdf /dev/vdg /dev/vdh | tr -d '\n '"
    en_vm_es "$ip" "server3: glusterd en ejecución"       "active"       systemctl is-active glusterd

    # ---------- Limpieza ----------
    echo
    if [[ -n "${CONSERVAR:-}" ]]; then
        info "CONSERVAR=1: el clúster se conserva. Para eliminarlo:"
        echo "      $SCRIPT ${PREFIJO:+--prefijo $PREFIJO }--eliminar server1 server2 server3 server4 gluster-base"
        info "OJO: la clave de pruebas se borra al terminar; solo podrás entrar por consola (root / s1st3mas)"
    else
        salida="$(ejecutar_script ${PO[@]+"${PO[@]}"} --eliminar server1 server2 server3 server4 gluster-base 2>&1)"; rc=$?
        echo "$salida" >> "$LOG"
        [[ $rc == 0 ]] && ok "clúster eliminado con --eliminar" || ko "--eliminar del clúster: código $rc"
        comprueba "no queda ningún nodo ni la base" bash -c "! virsh list --all --name | grep -qE '^${PD}-(server[1-4]|gluster-base)$' && [ ! -e '$SILO/${PF}gluster-base.qcow2' ]"
        info "clúster eliminado (CONSERVAR=1 para mantenerlo)"
    fi
}

########################################
# Main
########################################
[[ -f "$SCRIPT" ]] || { echo "No encuentro $SCRIPT"; exit 1; }

# Clave de usar y tirar para entrar en las máquinas de prueba (fases B y C).
# Se borra al salir, pase lo que pase (también con Ctrl+C).
CLAVE_DIR=""
if [[ "$FASE" != a ]]; then
    CLAVE_DIR="$(mktemp -d "$HOME/.ci-provision-pruebas.XXXXXX")" || { echo "No puedo crear el directorio de la clave de pruebas"; exit 1; }
    trap 'rm -rf "$CLAVE_DIR"' EXIT
    trap 'exit 130' INT TERM HUP
    chmod 700 "$CLAVE_DIR"
    ssh-keygen -q -t ed25519 -N '' -C "ci-provision-pruebas (desechable)" -f "$CLAVE_DIR/clave" || { echo "No puedo generar la clave de pruebas"; exit 1; }
    export CI_PROVISION_PUBKEY="$CLAVE_DIR/clave.pub"
fi

echo "Script : $SCRIPT"
echo "Silo   : $SILO"
echo "Usuario: $USUARIO"
echo "Log    : $LOG"
if [[ -n "$CLAVE_DIR" ]]; then
    echo "Clave  : de usar y tirar, en $CLAVE_DIR (se borra al terminar)"
fi

case "$FASE" in
    a)     fase_a ;;
    b)     fase_b ;;
    c)     fase_c ;;
    todas) fase_a; fase_b; fase_c ;;
    *)     echo "Fase desconocida '$FASE'. Usa: a | b | c | todas"; exit 1 ;;
esac

# El --dry-run con el que se descubre la red deja sus ficheros: fuera
rm -rf "$SILO/cloudinit-${USUARIO}-pruebas1.dry-run"

echo
echo "═══ Resultado: $OK correctas, $KO fallidas. Detalle en $LOG ═══"
exit $(( KO > 0 ))
