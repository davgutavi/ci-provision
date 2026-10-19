#!/usr/bin/env bats
# Tests locales de ci-provision.sh. No necesitan libvirt: virsh y virt-install
# están simulados (test/mocks) y el HOME es de mentira. Sí usan qemu-img real.
#
# Ejecutar desde la raíz del repositorio:
#   test_helper/bats-core/bin/bats test/

setup() {
    load 'helpers'
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    preparar_entorno
}

# Info JSON de un qcow2 (campo dado)
qinfo() {
    qemu-img info --output=json "$1" | jq -r "$2"
}

#############################################
# Sincronización del script distribuible
#############################################

@test "ci-provision.sh está al día respecto a src/ y lib/" {
    bash "$REPO_DIR/tools/build.sh" "$BATS_TEST_TMPDIR/build.sh" >/dev/null
    run diff -q "$BATS_TEST_TMPDIR/build.sh" "$SCRIPT"
    assert_success
}

#############################################
# Ayuda y parseo de opciones
#############################################

@test "muestra la ayuda con -h y con --help" {
    run bash "$SCRIPT" -h
    assert_success
    assert_output --partial "Uso:"
    run bash "$SCRIPT" --help
    assert_success
    assert_output --partial "--gluster-cluster"
}

@test "sin parámetros: error 10 con la sintaxis" {
    run bash "$SCRIPT"
    assert_failure 10
    assert_output --partial "MAQUINA [IP]"
}

@test "la sintaxis antigua (4 posicionales) da error 10 y lo explica" {
    run bash "$SCRIPT" usuario-server1 server1.qcow2 server1 usuario-red
    assert_failure 10
    assert_output --partial "versión anterior"
}

@test "las opciones antiguas dan error 12 y explican el cambio" {
    run bash "$SCRIPT" --enable-root server1
    assert_failure 12
    assert_output --partial "--no-root"

    run bash "$SCRIPT" --virt-viewer server1
    assert_failure 12

    run bash "$SCRIPT" --user-pass x server1
    assert_failure 12
    assert_output --partial "--ssh-pass"
}

@test "opción desconocida: error 12" {
    run bash "$SCRIPT" --noexiste server1
    assert_failure 12
}

@test "opción sin valor: error 11" {
    run bash "$SCRIPT" server1 --ram
    assert_failure 11
}

@test "nombre de máquina inválido: error 20" {
    run bash "$SCRIPT" "a b"
    assert_failure 20
    run bash "$SCRIPT" "server_1"
    assert_failure 20
    run bash "$SCRIPT" "-server1"
    assert_failure 12
}

@test "RAM y vCPUs no válidas: error 13" {
    run bash "$SCRIPT" --dry-run --ram abc server1
    assert_failure 13
    run bash "$SCRIPT" --dry-run --ram 128 server1
    assert_failure 13
    run bash "$SCRIPT" --dry-run --vcpus 0 server1
    assert_failure 13
}

@test "tamaño de disco no válido: error 15" {
    run bash "$SCRIPT" --dry-run --tam 40 server1
    assert_failure 15
}

@test "nombre de disco con ruta: error 16" {
    run bash "$SCRIPT" --dry-run --disco ../fuera.qcow2 server1
    assert_failure 16
}

@test "contraseña con caracteres no ASCII: error 14" {
    run bash "$SCRIPT" --dry-run --ssh-pass "contraseñá" server1
    assert_failure 14
}

@test "--gluster-cluster no admite MAQUINA ni --disco" {
    run bash "$SCRIPT" --dry-run --gluster-cluster server1
    assert_failure 10
    run bash "$SCRIPT" --dry-run --gluster-cluster --disco x.qcow2
    assert_failure 10
}

#############################################
# Entorno
#############################################

@test "sin conexión con libvirt: error 38" {
    MOCK_SIN_LIBVIRT=1 run bash "$SCRIPT" --dry-run server1
    assert_failure 38
}

@test "sin silo: error 30" {
    rm -rf "$SILO"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 30
}

@test "sin imagen base: la descarga y continúa" {
    rm -f "$SILO/noble-server-cloudimg-amd64.img"
    run bash "$SCRIPT" --no-wait server1
    assert_success
    assert_output --partial "Se descarga de:"
    assert_output --partial "Imagen base lista"
    assert_output --partial "Suma SHA-256 comprobada"
    [ "$(llamadas '^wget .*cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img$')" -eq 1 ]
    [ "$(llamadas '^wget .*cloud-images.ubuntu.com/noble/current/SHA256SUMS')" -eq 1 ]
    [ "$(qinfo "$SILO/noble-server-cloudimg-amd64.img" '.format')" = "qcow2" ]
    [ ! -e "$SILO/noble-server-cloudimg-amd64.img.descargando" ]
    [ "$(qinfo "$SILO/server1.qcow2" '."backing-filename"')" = "noble-server-cloudimg-amd64.img" ]
    [ "$(qinfo "$SILO/server1.qcow2" '."backing-filename-format"')" = "qcow2" ]
}

@test "--imagen debian12: descarga la imagen de Debian si falta y declara la variante debian12" {
    rm -f "$SILO/debian12.qcow2"
    run bash "$SCRIPT" --no-wait --imagen debian12 server1
    assert_success
    assert_output --partial "Debian 12"
    [ "$(llamadas '^wget .*debian-12-generic-amd64.qcow2')" -eq 1 ]
    [ "$(qinfo "$SILO/server1.qcow2" '."backing-filename"')" = "debian12.qcow2" ]
    grep -q -- '--os-variant debian12' "$MOCK_STATE/log"
}

@test "sin imagen base y --dry-run: avisa de que la descargaría, sin descargar" {
    rm -f "$SILO/noble-server-cloudimg-amd64.img"
    run bash "$SCRIPT" --dry-run server1
    assert_success
    assert_output --partial "se descargará de"
    [ "$(llamadas '^wget')" -eq 0 ]
    [ ! -e "$SILO/noble-server-cloudimg-amd64.img" ]
}

@test "la descarga se hace después de las demás validaciones" {
    rm -f "$SILO/noble-server-cloudimg-amd64.img"
    run bash "$SCRIPT" server1 192.168.7.200
    assert_failure 42
    [ "$(llamadas '^wget')" -eq 0 ]
}

@test "descarga fallida: error 37 con el comando manual y sin restos" {
    rm -f "$SILO/noble-server-cloudimg-amd64.img"
    MOCK_WGET_FALLA=1 run bash "$SCRIPT" server1
    assert_failure 37
    assert_output --partial "wget https://cloud-images.ubuntu.com"
    [ ! -e "$SILO/noble-server-cloudimg-amd64.img" ]
    [ ! -e "$SILO/noble-server-cloudimg-amd64.img.descargando" ]
    refute_output --partial "Deshaciendo"
}

@test "descarga corrupta (portal cautivo): error 37 y se elimina lo descargado" {
    rm -f "$SILO/noble-server-cloudimg-amd64.img"
    MOCK_WGET_CORRUPTO=1 run bash "$SCRIPT" server1
    assert_failure 37
    assert_output --partial "se ha eliminado"
    [ ! -e "$SILO/noble-server-cloudimg-amd64.img" ]
}

@test "imagen base existente que no es un qcow2: error 37 y NO se toca" {
    echo "<html>404</html>" > "$SILO/noble-server-cloudimg-amd64.img"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 37
    assert_output --partial "rm $SILO/noble-server-cloudimg-amd64.img"
    [ -e "$SILO/noble-server-cloudimg-amd64.img" ]
}

@test "sin clave pública: error 31" {
    rm -f "$HOME/.ssh/id_rsa.pub"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 31
}

#############################################
# Elección de la red virtual
#############################################

@test "elige USUARIO-red por defecto" {
    run bash "$SCRIPT" --dry-run server1
    assert_success
    assert_output --partial "Red     : ${USUARIO}-red"
}

@test "si la única red del usuario tiene otro sufijo, la usa" {
    quitar_red "${USUARIO}-red"
    definir_red "${USUARIO}-net" 192.168.8.1 255.255.255.0 192.168.8.128 192.168.8.254
    run bash "$SCRIPT" --dry-run server1
    assert_success
    assert_output --partial "Red     : ${USUARIO}-net"
}

@test "una red llamada exactamente como el usuario también vale" {
    quitar_red "${USUARIO}-red"
    definir_red "${USUARIO}" 192.168.8.1 255.255.255.0 192.168.8.128 192.168.8.254
    run bash "$SCRIPT" --dry-run server1
    assert_success
    assert_output --partial "Red     : ${USUARIO}"
}

@test "la búsqueda no distingue mayúsculas" {
    quitar_red "${USUARIO}-red"
    definir_red "${USUARIO^^}-network" 192.168.8.1 255.255.255.0 192.168.8.128 192.168.8.254
    run bash "$SCRIPT" --dry-run server1
    assert_success
    assert_output --partial "Red     : ${USUARIO^^}-network"
}

@test "con varias redes del usuario, prefiere USUARIO-red" {
    definir_red "${USUARIO}" 192.168.8.1 255.255.255.0 192.168.8.128 192.168.8.254
    run bash "$SCRIPT" --dry-run server1
    assert_success
    assert_output --partial "Red     : ${USUARIO}-red"
}

@test "con varias redes del usuario y ninguna llamada USUARIO-red: error 44" {
    quitar_red "${USUARIO}-red"
    definir_red "${USUARIO}-net" 192.168.8.1 255.255.255.0 192.168.8.128 192.168.8.254
    definir_red "${USUARIO}-network" 192.168.9.1 255.255.255.0 192.168.9.128 192.168.9.254
    run bash "$SCRIPT" --dry-run server1
    assert_failure 44
    assert_output --partial "--red NOMBRE"
}

@test "las redes de otros usuarios no cuentan" {
    quitar_red "${USUARIO}-red"
    definir_red "otro-red" 192.168.8.1 255.255.255.0 192.168.8.128 192.168.8.254
    definir_red "${USUARIO}x-red" 192.168.9.1 255.255.255.0 192.168.9.128 192.168.9.254
    run bash "$SCRIPT" --dry-run server1
    assert_failure 40
    assert_output --partial "${USUARIO}-red"
    assert_output --partial "--red NOMBRE"
}

@test "--red con una red inexistente: error 40" {
    run bash "$SCRIPT" --dry-run --red no-existe server1
    assert_failure 40
}

@test "--red permite usar cualquier red existente" {
    definir_red "red-boletin" 192.168.113.1 255.255.255.0 192.168.113.100 192.168.113.200
    run bash "$SCRIPT" --dry-run --red red-boletin server1 192.168.113.50
    assert_success
    assert_output --partial "Red     : red-boletin"
}

@test "red inactiva: error 45 con el comando para activarla" {
    touch "$MOCK_STATE/red-${USUARIO}-red.inactiva"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 45
    assert_output --partial "virsh net-start ${USUARIO}-red"
}

#############################################
# Validación de la IP fija contra la red real
#############################################

@test "IP libre: aceptada" {
    run bash "$SCRIPT" --dry-run server1 192.168.7.2
    assert_success
    assert_output --partial "IP      : 192.168.7.2"
}

@test "IP dentro del rango DHCP: error 42 con las IPs libres" {
    run bash "$SCRIPT" --dry-run server1 192.168.7.200
    assert_failure 42
    assert_output --partial "192.168.7.2 - 192.168.7.127"
}

@test "IP que es la pasarela, de red, de difusión o de otra subred: error 41" {
    run bash "$SCRIPT" --dry-run server1 192.168.7.1
    assert_failure 41
    run bash "$SCRIPT" --dry-run server1 192.168.7.0
    assert_failure 41
    run bash "$SCRIPT" --dry-run server1 192.168.7.255
    assert_failure 41
    run bash "$SCRIPT" --dry-run server1 192.168.9.2
    assert_failure 41
}

@test "IP mal formada: error 41" {
    run bash "$SCRIPT" --dry-run server1 192.168.7.999
    assert_failure 41
    run bash "$SCRIPT" --dry-run server1 hola
    assert_failure 41
}

@test "IP reservada por MAC fuera del rango DHCP: error 42" {
    quitar_red "${USUARIO}-red"
    definir_red "${USUARIO}-red" 192.168.7.1 255.255.255.0 192.168.7.128 192.168.7.254 192.168.7.10
    run bash "$SCRIPT" --dry-run server1 192.168.7.10
    assert_failure 42
    assert_output --partial "reservada"
}

@test "red con pasarela en .254 y DHCP en .1-.253 (topología de un profesor)" {
    definir_red "corchu-nat" 192.168.200.254 255.255.255.0 192.168.200.1 192.168.200.253
    run bash "$SCRIPT" --dry-run --red corchu-nat server1 192.168.200.2
    assert_failure 42
    assert_output --partial "Pasarela : 192.168.200.254"
    assert_output --partial "(ninguna)"
}

#############################################
# --dry-run
#############################################

@test "--dry-run no crea nada y muestra el comando" {
    run bash "$SCRIPT" --dry-run --extra-disks server1 192.168.7.2
    assert_success
    assert_output --partial "MODO SIMULACIÓN"
    assert_output --partial "virt-install"
    assert_output --partial "--graphics spice"
    assert_output --partial "server1-vdg.qcow2"
    [ "$(llamadas '^virt-install')" -eq 0 ]
    [ ! -e "$SILO/server1.qcow2" ]
    [ ! -e "$SILO/server1-vdb.qcow2" ]
    [ -d "$SILO/cloudinit-${USUARIO}-server1.dry-run" ]
    [ ! -d "$SILO/cloudinit-${USUARIO}-server1" ]
}

@test "--dry-run con --limpiar solo enumera lo que se eliminaría" {
    touch "$SILO/server1.qcow2"
    run bash "$SCRIPT" --si --dry-run --limpiar server1 </dev/null
    assert_success
    assert_output --partial "no se elimina nada"
    [ -e "$SILO/server1.qcow2" ]
}

#############################################
# Creación de una máquina
#############################################

@test "máquina básica con DHCP" {
    run bash "$SCRIPT" server1
    assert_success

    # Disco COW de la imagen de Ubuntu, del tamaño por defecto
    [ "$(qinfo "$SILO/server1.qcow2" '."backing-filename"')" = "noble-server-cloudimg-amd64.img" ]
    [ "$(qinfo "$SILO/server1.qcow2" '."virtual-size"')" = "42949672960" ]
    [ "$(llamadas '--os-variant ubuntu24.04')" -eq 1 ]

    # Dominio creado con los parámetros por defecto
    dominio_existe "${USUARIO}-server1"
    [ "$(llamadas '--ram 2048 --vcpus 2')" -eq 1 ]
    [ "$(llamadas "--network network=${USUARIO}-red")" -eq 1 ]
    [ "$(llamadas '--graphics spice')" -eq 1 ]
    [ "$(llamadas '--disk path=')" -eq 1 ]

    # Ficheros cloud-init protegidos y sin red estática
    local d="$SILO/cloudinit-${USUARIO}-server1"
    [ "$(stat -f %Lp "$d" 2>/dev/null || stat -c %a "$d")" = "700" ]
    [ "$(stat -f %Lp "$d/cip-user.yaml" 2>/dev/null || stat -c %a "$d/cip-user.yaml")" = "600" ]
    [ ! -e "$d/cip-net.yaml" ]

    # Espera, expulsión del medio y resumen con la IP
    assert_output --partial "operativa tras"
    assert_output --partial "Medio de cloud-init expulsado"
    [ ! -e "$MOCK_STATE/dominios/${USUARIO}-server1/iso" ]
    assert_output --partial "IP           : 192.168.7.201 (DHCP)"
    assert_output --partial "Sistema      : Ubuntu 24.04 (imagen cloud)"
    assert_output --partial "virsh console ${USUARIO}-server1"
}

@test "user-data por defecto: root con contraseña de consola, administrador sin ella, SSH solo por clave" {
    run bash "$SCRIPT" server1
    assert_success
    local u="$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    grep -q "^#cloud-config" "$u"
    # Sintaxis vigente de chpasswd (la de 'list:' deja cloud-init en 'degraded done')
    [ "$(sed -n '/^chpasswd:/,/^[a-z]/p' "$u" | tr -s ' \n' ' ')" = "chpasswd: expire: false users: - name: root password: s1st3mas type: text ssh_pwauth: false " ]
    ! grep -q "list:" "$u"
    ! grep -q "ssh-authorized-keys" "$u"
    grep -q "sudo: \['ALL=(ALL) NOPASSWD:ALL'\]" "$u"
    grep -q "^ssh_pwauth: false" "$u"
    grep -A1 "ssh_authorized_keys:" "$u" | grep -q "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0falsa"
    grep -q "qemu-guest-agent" "$u"
    ! grep -q "glusterfs-server" "$u"
    grep -q "instance-id: ${USUARIO}-server1" "$SILO/cloudinit-${USUARIO}-server1/cip-meta.yaml"
    grep -q "local-hostname: server1" "$SILO/cloudinit-${USUARIO}-server1/cip-meta.yaml"
}

@test "--no-root: root sin contraseña; sin --ssh-pass no hay chpasswd" {
    run bash "$SCRIPT" --no-root server1
    assert_success
    local u="$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    ! grep -q "name: root" "$u"
    ! grep -q "chpasswd" "$u"
    assert_output --partial "nadie entra por consola"
}

@test "--no-virt-viewer: sin consola gráfica, y no se sugiere virt-viewer" {
    run bash "$SCRIPT" --no-virt-viewer server1
    assert_success
    [ "$(llamadas '--graphics none')" -eq 1 ]
    [ "$(llamadas '--graphics spice')" -eq 0 ]
    refute_output --partial "virt-viewer --connect"
}

@test "--no-root con --ssh-pass: solo administrador tiene contraseña" {
    run bash "$SCRIPT" --no-root --ssh-pass MiPass1 server1
    assert_success
    local u="$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    grep -A1 "^    - name: administrador" "$u" | grep -q "password: 'MiPass1'"
    ! grep -q "name: root" "$u"
}

@test "--base en una máquina suelta: copia COW de esa imagen, sin descargar nada" {
    qemu-img create -f qcow2 -b noble-server-cloudimg-amd64.img -F qcow2 "$SILO/mibase.qcow2" 3G >/dev/null
    rm -f "$SILO/debian12.qcow2"
    run bash "$SCRIPT" --base mibase.qcow2 server1 192.168.7.10
    assert_success
    [ "$(qinfo "$SILO/server1.qcow2" '."backing-filename"')" = "mibase.qcow2" ]
    [ "$(llamadas '^wget')" -eq 0 ]
    assert_output --partial "copia COW de mibase.qcow2"
    # Copia de la imagen de Ubuntu: variante ubuntu24.04 y administrador como en ella
    [ "$(llamadas '--os-variant ubuntu24.04')" -eq 1 ]
    grep -q "NOPASSWD" "$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
}

@test "--ssh-pass activa el SSH por contraseña con la contraseña elegida" {
    run bash "$SCRIPT" --ssh-pass MiPass1 server1
    assert_success
    local u="$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    grep -q "^ssh_pwauth: true" "$u"
    grep -A1 "^    - name: administrador" "$u" | grep -q "password: 'MiPass1'"
    grep -A1 "^    - name: root" "$u" | grep -q "password: s1st3mas"
    assert_output --partial "contraseña: MiPass1"
}

@test "IP fija y --extra-disks: 7 discos en orden y network-config con routes" {
    run bash "$SCRIPT" --extra-disks server1 192.168.7.2
    assert_success

    # Los siete discos se pasan a virt-install en orden: primero el principal
    local linea
    linea="$(grep '^virt-install' "$MOCK_STATE/log")"
    [ "$(grep -o -- '--disk path=' <<< "$linea" | wc -l | tr -d ' ')" -eq 7 ]
    [[ "$linea" == *"path=$SILO/server1.qcow2,"*"path=$SILO/server1-vdb.qcow2,"*"path=$SILO/server1-vdg.qcow2,"* ]]
    local u
    for u in vdb vdc vdd vde vdf vdg; do
        [ "$(qinfo "$SILO/server1-$u.qcow2" '."virtual-size"')" = "42949672960" ]
    done

    local n="$SILO/cloudinit-${USUARIO}-server1/cip-net.yaml"
    grep -q -- "- 192.168.7.2/24" "$n"
    grep -q "routes:" "$n"
    grep -q "via: 192.168.7.1" "$n"
    ! grep -q "gateway4" "$n"
    grep -q "150.214.186.69" "$n"

    assert_output --partial "IP           : 192.168.7.2 (fija)"
    assert_output --partial "Discos extra : vdb..vdg"
}

@test "--glusterfs: paquetes, orden de runcmd, y al final solo queda el disco" {
    run bash "$SCRIPT" --glusterfs gluster-base
    assert_success
    local u="$SILO/cloudinit-${USUARIO}-gluster-base/cip-user.yaml"
    grep -q "glusterfs-server" "$u"
    grep -q "xfsprogs" "$u"
    # enable glusterd antes de arrancar el agente; truncate del machine-id después
    local runcmd
    runcmd="$(sed -n '/^runcmd:/,$p' "$u" | tr '\n' ' ')"
    [[ "$runcmd" == *"systemctl enable glusterd"*"systemctl start qemu-guest-agent"*"truncate -s 0 /etc/machine-id"* ]]

    # Se espera, se apaga y se elimina el dominio; el disco se conserva
    [ "$(llamadas 'domifaddr')" -ge 1 ]
    [ "$(llamadas "shutdown ${USUARIO}-gluster-base")" -eq 1 ]
    [ "$(llamadas "undefine ${USUARIO}-gluster-base")" -eq 1 ]
    ! dominio_existe "${USUARIO}-gluster-base"
    [ "$(qinfo "$SILO/gluster-base.qcow2" '."backing-filename"')" = "noble-server-cloudimg-amd64.img" ]
    assert_output --partial "Imagen base GlusterFS lista"
    assert_output --partial "qemu-img create -f qcow2 -b gluster-base.qcow2"
}

@test "--glusterfs --imagen ubuntu-base: copia completa de ubuntu-base, administrador como en ella" {
    run bash "$SCRIPT" --imagen ubuntu-base --glusterfs gluster-base
    assert_success
    # Copia completa (sin respaldo), con el tamaño de ubuntu-base (64G) y sin
    # tocar el original
    [ "$(qinfo "$SILO/gluster-base.qcow2" '."backing-filename" // "ninguno"')" = "ninguno" ]
    [ "$(qinfo "$SILO/gluster-base.qcow2" '."virtual-size"')" = "68719476736" ]
    [ -e "$UBUNTU_BASE_COMPARTIDA" ]
    [ "$(llamadas '--os-variant ubuntu24.04')" -eq 1 ]
    assert_output --partial "copia completa de $UBUNTU_BASE_COMPARTIDA"
    assert_output --partial "Ubuntu 24.04 (ubuntu-base.qcow2 del boletín 1)"
    # administrador: solo se le añade la clave; su contraseña y su sudo, intactos
    local u="$SILO/cloudinit-${USUARIO}-gluster-base/cip-user.yaml"
    [ "$(sed -n '/^users:/,/^[a-z]/p' "$u" | tr -s ' \n' ' ')" = "users: - name: administrador lock_passwd: false ssh_authorized_keys: - 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0falsa ${USUARIO}@test' chpasswd: " ]
    ! grep -q "ssh_pwauth" "$u"
    grep -A1 "^    - name: root" "$u" | grep -q "password: s1st3mas"
}

@test "--glusterfs --no-root con ubuntu-base: se bloquea la contraseña que trae root" {
    run bash "$SCRIPT" --no-root --imagen ubuntu-base --glusterfs gluster-base
    assert_success
    grep -q "^  - passwd -l root" "$SILO/cloudinit-${USUARIO}-gluster-base/cip-user.yaml"
    ! grep -q "chpasswd" "$SILO/cloudinit-${USUARIO}-gluster-base/cip-user.yaml"
}

@test "ubuntu-base: no se admite en una máquina suelta, y si no está, error 39" {
    run bash "$SCRIPT" --dry-run --imagen ubuntu-base server1
    assert_failure 10
    assert_output --partial "solo sirve para la imagen base GlusterFS"
    run bash "$SCRIPT" --dry-run --imagen fedora server1
    assert_failure 10
    rm -f "$UBUNTU_BASE_COMPARTIDA"
    run bash "$SCRIPT" --dry-run --gluster-cluster --imagen ubuntu-base
    assert_failure 39
    assert_output --partial "--imagen noble"
    [ "$(llamadas '^wget')" -eq 0 ]
}

@test "--glusterfs no admite --no-wait" {
    run bash "$SCRIPT" --no-wait --glusterfs gluster-base
    assert_failure 10
}

@test "--glusterfs: si cloud-init falla, error 71 y la máquina se conserva para examinarla" {
    MOCK_CI_RESULT=error run bash "$SCRIPT" --glusterfs gluster-base
    assert_failure 71
    assert_output --partial "se conserva"
    assert_output --partial "virsh console ${USUARIO}-gluster-base"
    dominio_existe "${USUARIO}-gluster-base"
    [ -e "$SILO/gluster-base.qcow2" ]
    refute_output --partial "Deshaciendo"
}

@test "--glusterfs: si no se puede consultar cloud-init, no se asume; error 70 y rollback" {
    MOCK_EXEC_UNSUPPORTED=1 run bash "$SCRIPT" --glusterfs gluster-base
    assert_failure 70
    assert_output --partial "No se ha podido confirmar"
    ! dominio_existe "${USUARIO}-gluster-base"
    [ ! -e "$SILO/gluster-base.qcow2" ]
    [ -e "$UBUNTU_BASE_COMPARTIDA" ]
}

@test "--disco y --tam cambian el nombre y el tamaño del disco principal" {
    run bash "$SCRIPT" --disco mio.qcow2 --tam 20G server1
    assert_success
    [ -e "$SILO/mio.qcow2" ]
    [ ! -e "$SILO/server1.qcow2" ]
    [ "$(qinfo "$SILO/mio.qcow2" '."virtual-size"')" = "21474836480" ]
    assert_output --partial "mio.qcow2 (20G, copia COW de noble-server-cloudimg-amd64.img)"
}

@test "--prefijo: dominio y discos con prefijo; lo de tu usuario no se toca ni con --limpiar" {
    run bash "$SCRIPT" server1
    assert_success
    run bash "$SCRIPT" --si --limpiar --prefijo demo --extra-disks server1 </dev/null
    assert_success
    [ "$(llamadas '--name demo-server1')" -eq 1 ]
    [ -e "$SILO/demo-server1.qcow2" ]
    [ -e "$SILO/demo-server1-vdb.qcow2" ] && [ -e "$SILO/demo-server1-vdg.qcow2" ]
    grep -q -r '^local-hostname: server1$' "$SILO/cloudinit-demo-server1/"
    assert_output --partial "demo-server1"
    dominio_existe "${USUARIO}-server1"
    [ -e "$SILO/server1.qcow2" ]
    [ ! -e "$SILO/server1-vdb.qcow2" ]
    refute_output --partial "eliminado"
}

@test "--prefijo con --gluster-cluster: base y nodos con prefijo, hostnames intactos" {
    touch "$SILO/gluster-base.qcow2" "$SILO/server1.qcow2"
    run bash "$SCRIPT" --prefijo demo --gluster-cluster
    assert_success
    [ "$(llamadas '--name demo-gluster-base')" -eq 1 ]
    [ "$(llamadas '--name demo-server')" -eq 4 ]
    [ -e "$SILO/demo-gluster-base.qcow2" ]
    [ "$(qinfo "$SILO/demo-server3.qcow2" '."backing-filename"')" = "demo-gluster-base.qcow2" ]
    [ -e "$SILO/demo-server4-vdd.qcow2" ] && [ ! -e "$SILO/demo-server4-vde.qcow2" ]
    grep -q -r '^local-hostname: server2$' "$SILO/cloudinit-demo-server2/"
    assert_output --partial "no borres $SILO/demo-gluster-base.qcow2"
    [ -e "$SILO/gluster-base.qcow2" ] && [ -e "$SILO/server1.qcow2" ]
}

@test "--prefijo no válido: error 20; sin valor: error 11" {
    run bash "$SCRIPT" --prefijo 'demo/x' server1
    assert_failure 20
    run bash "$SCRIPT" server1 --prefijo
    assert_failure 11
}

@test "si virt-install falla después de definir el dominio, el rollback también lo elimina" {
    MOCK_VIRT_INSTALL_FALLA_TARDE=1 run bash "$SCRIPT" --extra-disks server1
    assert_failure
    assert_output --partial "dominio '${USUARIO}-server1' eliminado"
    ! dominio_existe "${USUARIO}-server1"
    [ ! -e "$SILO/server1.qcow2" ] && [ ! -e "$SILO/server1-vdg.qcow2" ]
}

@test "combinaciones incompatibles: error 10 (y --disco igual a un disco extra: 16)" {
    run bash "$SCRIPT" --dry-run --glusterfs --extra-disks gluster-base
    assert_failure 10
    run bash "$SCRIPT" --dry-run --glusterfs gluster-base 192.168.7.5
    assert_failure 10
    run bash "$SCRIPT" --dry-run --imagen fedora --base debian12.qcow2 server1
    assert_failure 10
    run bash "$SCRIPT" --dry-run --discos-nodo 7 server1
    assert_failure 10
    run bash "$SCRIPT" --dry-run --gluster-cluster --glusterfs
    assert_failure 10
    run bash "$SCRIPT" --dry-run --gluster-cluster --extra-disks
    assert_failure 10
    run bash "$SCRIPT" --dry-run --extra-disks --disco server1-vdb.qcow2 server1
    assert_failure 16
}

@test "opciones con valor: sin valor, con valor vacío o con '=' se explican (11/12)" {
    run bash "$SCRIPT" --ssh-pass --extra-disks server1
    assert_failure 11
    run bash "$SCRIPT" --ram "" server1
    assert_failure 11
    run bash "$SCRIPT" --ram=4096 server1
    assert_failure 12
    assert_output --partial "--ram 4096"
}

@test "el nombre de máquina no debe llevar el usuario delante: error 20" {
    run bash "$SCRIPT" --dry-run "${USUARIO}-server1"
    assert_failure 20
    assert_output --partial "'server1'"
    run bash "$SCRIPT" --dry-run --prefijo demo demo-server1
    assert_failure 20
}

@test "--limpiar se niega a borrar un disco que usa otra máquina o que es respaldo de otra copia" {
    run bash "$SCRIPT" --disco server1.qcow2 otra
    assert_success
    run bash "$SCRIPT" --si --limpiar server1 </dev/null
    assert_failure 21
    assert_output --partial "lo usa la máquina '${USUARIO}-otra'"
    dominio_existe "${USUARIO}-otra"
    [ -e "$SILO/server1.qcow2" ]

    run bash "$SCRIPT" --glusterfs gluster-base
    assert_success
    (cd "$SILO" && qemu-img create -f qcow2 -b gluster-base.qcow2 -F qcow2 nodo1.qcow2 64G >/dev/null)
    run bash "$SCRIPT" --si --limpiar --glusterfs gluster-base </dev/null
    assert_failure 21
    assert_output --partial "imagen base de nodo1.qcow2"
    [ -e "$SILO/gluster-base.qcow2" ]
}

@test "clave pública con dos claves, vacía o que no lo es: error 31" {
    printf 'ssh-rsa AAAA a@b\nssh-ed25519 BBBB c@d\n' > "$HOME/.ssh/id_rsa.pub"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 31
    : > "$HOME/.ssh/id_rsa.pub"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 31
    echo "esto no es una clave" > "$HOME/.ssh/id_rsa.pub"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 31
}

@test "--tam menor que la imagen de partida: error 15" {
    run bash "$SCRIPT" --dry-run --tam 1G server1
    assert_failure 15
    qemu-img create -f qcow2 "$SILO/mibase.qcow2" 40G >/dev/null
    run bash "$SCRIPT" --dry-run --tam 20G --base mibase.qcow2 server1
    assert_failure 15
    run bash "$SCRIPT" --dry-run --tam 40G --base mibase.qcow2 server1
    assert_success
}

@test "sin --tam, el disco toma el tamaño de la imagen de partida si es mayor que 40G" {
    qemu-img create -f qcow2 "$SILO/grande.qcow2" 50G >/dev/null
    run bash "$SCRIPT" --no-wait --base grande.qcow2 server1
    assert_success
    [ "$(qinfo "$SILO/server1.qcow2" '."virtual-size"')" = "53687091200" ]
    assert_output --partial "(50G, copia COW de grande.qcow2)"
}

@test "--base: la variante de SO y el estilo de administrador se deducen de la imagen" {
    # Copia de la imagen de Debian (aunque sea de segunda generación)
    (cd "$SILO" && qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 deb-base.qcow2 >/dev/null \
                && qemu-img create -f qcow2 -b deb-base.qcow2 -F qcow2 deb-nieta.qcow2 >/dev/null)
    run bash "$SCRIPT" --dry-run --base deb-nieta.qcow2 server1
    assert_success
    assert_output --partial "Debian 12 (imagen cloud); variante debian12"
    grep -q "NOPASSWD" "$SILO/cloudinit-${USUARIO}-server1.dry-run/cip-user.yaml"
    # Imagen sin respaldo: la base del boletín (copia de ubuntu-base)
    cp "$UBUNTU_BASE_COMPARTIDA" "$SILO/gluster-base.qcow2"
    run bash "$SCRIPT" --dry-run --gluster-cluster --base gluster-base.qcow2
    assert_success
    assert_output --partial "ubuntu-base.qcow2 del boletín 1); variante ubuntu24.04"
    ! grep -q "NOPASSWD" "$SILO/cloudinit-${USUARIO}-server1.dry-run/cip-user.yaml"
    grep -q "lock_passwd: false" "$SILO/cloudinit-${USUARIO}-server1.dry-run/cip-user.yaml"
}

@test "una máquina llamada como una imagen cloud: error 10 sin hablar de --base, ni con --limpiar" {
    run bash "$SCRIPT" --dry-run debian12
    assert_failure 10
    refute_output --partial "--base"
    run bash "$SCRIPT" --si --limpiar debian12 </dev/null
    assert_failure 10
    [ -e "$SILO/debian12.qcow2" ]
    run bash "$SCRIPT" --si --limpiar --disco noble-server-cloudimg-amd64.img server1 </dev/null
    assert_failure 10
    [ -e "$SILO/noble-server-cloudimg-amd64.img" ]
}

@test "--version muestra la versión" {
    run bash "$SCRIPT" --version
    assert_success
    assert_output --regexp '^ci-provision.sh [0-9]+\.[0-9]+\.[0-9]+$'
}

@test "--listar: máquinas con estado, IP y discos, y discos del silo sin máquina" {
    run bash "$SCRIPT" --extra-disks server1
    assert_success
    run bash "$SCRIPT" --imagen debian12 --glusterfs gluster-base
    assert_success
    run bash "$SCRIPT" --listar
    assert_success
    assert_output --partial "Máquinas ${USUARIO}-* (1):"
    assert_output --regexp "${USUARIO}-server1 +en ejecución +192\.168\.7\.[0-9]+ +server1\.qcow2 \(copia de noble-server-cloudimg-amd64\.img\) \+ 6 discos extra"
    assert_output --partial "Discos del silo sin máquina:"
    assert_output --regexp "gluster-base\.qcow2 +copia de debian12\.qcow2"
    assert_output --regexp "debian12\.qcow2 +imagen cloud de Debian 12"
    assert_output --regexp "noble-server-cloudimg-amd64\.img +imagen cloud de Ubuntu 24\.04"
    run bash "$SCRIPT" --listar server1
    assert_failure 10
    run bash "$SCRIPT" --listar --extra-disks
    assert_failure 10
}

@test "--eliminar MAQUINA: máquina, discos y cloud-init; lo demás intacto" {
    run bash "$SCRIPT" --extra-disks server1
    assert_success
    run bash "$SCRIPT" server2
    assert_success
    run bash "$SCRIPT" --si --dry-run --eliminar server1 </dev/null
    assert_success
    dominio_existe "${USUARIO}-server1"
    run bash "$SCRIPT" --si --eliminar server1 </dev/null
    assert_success
    assert_output --partial "máquina ${USUARIO}-server1 eliminada"
    ! dominio_existe "${USUARIO}-server1"
    [ ! -e "$SILO/server1.qcow2" ] && [ ! -e "$SILO/server1-vdb.qcow2" ] && [ ! -e "$SILO/server1-vdg.qcow2" ]
    [ ! -d "$SILO/cloudinit-${USUARIO}-server1" ]
    dominio_existe "${USUARIO}-server2"
    [ -e "$SILO/server2.qcow2" ] && [ -e "$SILO/debian12.qcow2" ]
    run bash "$SCRIPT" --si --eliminar debian12 </dev/null
    assert_failure 22
    assert_output --partial "debian12.qcow2: es una imagen cloud de partida (nunca se borra)"
    [ -e "$SILO/debian12.qcow2" ]
    run bash "$SCRIPT" --si --eliminar server9 </dev/null
    assert_failure 22
    run bash "$SCRIPT" --si --eliminar "${USUARIO}-server2"
    assert_failure 20
    run bash "$SCRIPT" --si --eliminar
    assert_failure 10
}

@test "--eliminar conserva un disco que usa otra máquina o del que dependen copias" {
    run bash "$SCRIPT" --disco server1.qcow2 otra
    assert_success
    run bash "$SCRIPT" --si --eliminar server1 </dev/null
    assert_failure 22
    assert_output --partial "lo usa la máquina '${USUARIO}-otra'"
    dominio_existe "${USUARIO}-otra"
    [ -e "$SILO/server1.qcow2" ]

    run bash "$SCRIPT" --glusterfs gluster-base
    assert_success
    run bash "$SCRIPT" --base gluster-base.qcow2 nodo1
    assert_success
    # Solo quedan sus ficheros cloud-init por eliminar: el disco se conserva y se explica
    run bash "$SCRIPT" --si --eliminar gluster-base </dev/null
    assert_success
    assert_output --partial "gluster-base.qcow2: es la imagen base de nodo1.qcow2"
    [ -e "$SILO/gluster-base.qcow2" ]
    [ ! -d "$SILO/cloudinit-${USUARIO}-gluster-base" ]
    run bash "$SCRIPT" --si --eliminar nodo1 gluster-base </dev/null
    assert_success
    ! dominio_existe "${USUARIO}-nodo1"
    [ ! -e "$SILO/nodo1.qcow2" ] && [ ! -e "$SILO/gluster-base.qcow2" ]
}

@test "--eliminar-todo: todas las máquinas del usuario y los discos sin máquina; nunca las imágenes cloud ni otro prefijo" {
    run bash "$SCRIPT" server1
    assert_success
    run bash "$SCRIPT" --glusterfs gluster-base
    assert_success
    run bash "$SCRIPT" --prefijo demo server1
    assert_success
    run bash "$SCRIPT" --si --dry-run --eliminar-todo </dev/null
    assert_success
    dominio_existe "${USUARIO}-server1"
    run bash "$SCRIPT" --si --eliminar-todo </dev/null
    assert_success
    ! dominio_existe "${USUARIO}-server1"
    [ ! -e "$SILO/server1.qcow2" ] && [ ! -e "$SILO/gluster-base.qcow2" ]
    [ -e "$SILO/debian12.qcow2" ] && [ -e "$SILO/noble-server-cloudimg-amd64.img" ]
    [ -e "$UBUNTU_BASE_COMPARTIDA" ]
    dominio_existe "demo-server1"
    [ -e "$SILO/demo-server1.qcow2" ]
    assert_output --partial "demo-server1.qcow2: lo usa la máquina 'demo-server1'"
    run bash "$SCRIPT" --si --prefijo demo --eliminar-todo </dev/null
    assert_success
    ! dominio_existe "demo-server1"
    [ ! -e "$SILO/demo-server1.qcow2" ]
    run bash "$SCRIPT" --si --eliminar-todo </dev/null
    assert_failure 22
}

@test "--menu: el asistente construye el comando, lo ejecuta y vuelve al menú" {
    export MOCK_WHIPTAIL="$BATS_TEST_TMPDIR/respuestas"
    printf '%s\n' "0 basica" "0 server1" "0 " "0 debian12" "0 \"extra-disks\" \"no-root\"" "0" "0 salir" > "$MOCK_WHIPTAIL"
    run bash "$SCRIPT" --menu </dev/null
    assert_success
    # La máquina básica es la del boletín 1: Debian 12 aparece marcada
    grep -q -- '--radiolist .* noble Ubuntu 24.04 (boletín 2) off debian12 Debian 12 (boletín 1) on$' "$MOCK_STATE/log"
    assert_output --partial "→ $SCRIPT --imagen debian12 --extra-disks --no-root server1"
    assert_output --partial "Sin cambios."
    dominio_existe "${USUARIO}-server1"
    [ -e "$SILO/server1-vdg.qcow2" ]
    [ "$(qinfo "$SILO/server1.qcow2" '."backing-filename"')" = "debian12.qcow2" ]
    [ "$(llamadas '^whiptail --title')" -eq 7 ]
}

@test "--menu: el clúster deja elegir la imagen de la base y los discos de crea-entorno.sh" {
    export MOCK_WHIPTAIL="$BATS_TEST_TMPDIR/respuestas"
    printf '%s\n' "0 cluster" "0 debian12" "0 \"discos-crea-entorno\"" "0" "1" > "$MOCK_WHIPTAIL"
    run bash "$SCRIPT" --menu </dev/null
    assert_success
    grep -q -- ' 13 78 3 noble Imagen cloud de Ubuntu 24.04, la misma que SERVER1 (recomendada) on ubuntu-base ' "$MOCK_STATE/log"
    assert_output --partial "→ $SCRIPT --gluster-cluster --imagen debian12 --discos-nodo 7"
    [ "$(qinfo "$SILO/gluster-base.qcow2" '."backing-filename"')" = "debian12.qcow2" ]
    [ -e "$SILO/server4-vdh.qcow2" ]

    # Con la base ya hecha, ofrece reutilizarla y no pregunta la imagen
    printf '%s\n' "0 cluster" "0" "0 \"limpiar\"" "0" "1" > "$MOCK_WHIPTAIL"
    run bash "$SCRIPT" --menu </dev/null
    assert_success
    assert_output --partial "→ $SCRIPT --gluster-cluster --base gluster-base.qcow2 --limpiar"
}

@test "--menu: cancelar en el menú principal no hace nada" {
    export MOCK_WHIPTAIL="$BATS_TEST_TMPDIR/respuestas"
    printf '%s\n' "1" > "$MOCK_WHIPTAIL"
    run bash "$SCRIPT" --menu </dev/null
    assert_success
    assert_output --partial "Sin cambios."
    [ "$(llamadas '^virt-install')" -eq 0 ]
}

@test "--menu: almacenamiento extra pide el nombre, sugiere la IP .2 y marca los discos; eliminar elige de la lista" {
    export MOCK_WHIPTAIL="$BATS_TEST_TMPDIR/respuestas"
    printf '%s\n' "0 extra" "0 server1" "0 192.168.7.2" "0 noble" "0 \"extra-disks\"" "0" "0 eliminar" "0 \"server1\"" "0" "1" > "$MOCK_WHIPTAIL"
    run bash "$SCRIPT" --menu --si </dev/null
    assert_success
    grep -q -- ' 16 70 192.168.7.2$' "$MOCK_STATE/log"
    grep -q -- '--radiolist .* noble Ubuntu 24.04 (boletín 2) on debian12 Debian 12 (boletín 1) off$' "$MOCK_STATE/log"
    grep -q -- 'extra-disks Seis discos extra vdb..vdg de 40G on ' "$MOCK_STATE/log"
    assert_output --partial "→ $SCRIPT --si --extra-disks server1 192.168.7.2"
    assert_output --partial "→ $SCRIPT --si --eliminar server1"
    grep -q -- '--checklist .* server1 en ejecución off' "$MOCK_STATE/log"
    ! dominio_existe "${USUARIO}-server1"
    [ ! -e "$SILO/server1-vdb.qcow2" ]
}

@test "--menu: la lista gráfica muestra máquinas y discos sueltos, con ficha al elegir" {
    run bash "$SCRIPT" --extra-disks server1
    assert_success
    run bash "$SCRIPT" --imagen debian12 --glusterfs glusterbase
    assert_success
    export MOCK_WHIPTAIL="$BATS_TEST_TMPDIR/respuestas"
    printf '%s\n' "0 listar" "0 m:${USUARIO}-server1" "0" "0 d:$SILO/glusterbase.qcow2" "0" "1" "1" > "$MOCK_WHIPTAIL"
    run bash "$SCRIPT" --menu </dev/null
    assert_success
    grep -q -- '--notags --menu Mis máquinas virtuales' "$MOCK_STATE/log"
    grep -qE -- "m:${USUARIO}-server1 server1 +en ejecución +192\.168\.7\.[0-9]+ +7 disco\(s\)" "$MOCK_STATE/log"
    grep -q -- "d:$SILO/glusterbase.qcow2 glusterbase.qcow2 sin máquina  copia de debian12.qcow2" "$MOCK_STATE/log"
    grep -q -- "Máquina : ${USUARIO}-server1   (hostname: server1)" "$MOCK_STATE/log"
    grep -q -- "          server1-vdg.qcow2" "$MOCK_STATE/log"
    grep -q -- "Disco   : glusterbase.qcow2" "$MOCK_STATE/log"
    grep -q -- "Tamaño  : 40 GiB (virtual)" "$MOCK_STATE/log"
    assert_output --partial "Sin cambios."
}

@test "--menu: la contraseña no se muestra en el comando; sin whiptail, error 38; sin más opciones" {
    export MOCK_WHIPTAIL="$BATS_TEST_TMPDIR/respuestas"
    printf '%s\n' "0 basica" "0 web" "0 " "0 noble" "0 \"ssh-pass\"" "0 Secreta1" "0" "1" > "$MOCK_WHIPTAIL"
    run bash "$SCRIPT" --menu </dev/null
    assert_success
    assert_output --partial "→ $SCRIPT --ssh-pass •••••• web"
    refute_output --partial "--ssh-pass Secreta1"
    grep -q "password: 'Secreta1'" "$SILO/cloudinit-${USUARIO}-web/cip-user.yaml"

    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    ln -s "$REPO_DIR/test/mocks/virsh" "$bin/virsh"
    ln -s "$REPO_DIR/test/mocks/virt-install" "$bin/virt-install"
    ln -s "$REPO_DIR/test/mocks/wget" "$bin/wget"
    PATH="$bin:${PATH#"$REPO_DIR/test/mocks:"}" run bash "$SCRIPT" --menu
    assert_failure 38
    assert_output --partial "whiptail"
    run bash "$SCRIPT" --menu server1
    assert_failure 10
    run bash "$SCRIPT" --menu --extra-disks
    assert_failure 10
}

@test "confirmación por teclado de --limpiar: 'n' cancela sin tocar nada; 's' elimina y sigue" {
    run bash "$SCRIPT" server1
    assert_success
    run con_terminal '[s/N]' n bash "$SCRIPT" --limpiar server1
    assert_success
    assert_output --partial "Cancelado: no se ha eliminado nada."
    dominio_existe "${USUARIO}-server1"
    [ "$(llamadas '^virt-install')" -eq 1 ]
    run con_terminal '[s/N]' s bash "$SCRIPT" --limpiar server1
    assert_success
    assert_output --partial "dominio ${USUARIO}-server1 eliminado"
    [ "$(llamadas '^virt-install')" -eq 2 ]
}

@test "--ssh-pass -: la contraseña se pide por teclado; sin terminal, error 11" {
    run con_terminal 'Contraseña' Secreta9 bash "$SCRIPT" --ssh-pass - server1
    assert_success
    grep -q "password: 'Secreta9'" "$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    run bash "$SCRIPT" --ssh-pass - server2 </dev/null
    assert_failure 11
}

@test "--tam admite minúsculas; cloud-init 'degraded done' cuenta como terminado con errores" {
    run bash "$SCRIPT" --dry-run --tam 20g server1
    assert_success
    assert_output --partial "20G"
    # Como cloud-init >= 23.4: escribe "done" pero sale con código 2
    MOCK_CI_RESULT=degraded run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "informa de errores"
}

@test "red definida sin máscara ni prefijo: se asume la de su clase" {
    quitar_red "${USUARIO}-red"
    {
        echo "<network>"
        echo "  <name>${USUARIO}-red</name>"
        echo "  <forward mode='nat'/>"
        echo "  <ip address='192.168.7.1'>"
        echo "    <dhcp><range start='192.168.7.128' end='192.168.7.254'/></dhcp>"
        echo "  </ip>"
        echo "</network>"
    } > "$MOCK_STATE/red-${USUARIO}-red.xml"
    echo "${USUARIO}-red" >> "$MOCK_STATE/redes.txt"
    run bash "$SCRIPT" --dry-run server1 192.168.7.50
    assert_success
    assert_output --partial "prefijo /24"
}

@test "--red con un nombre inválido: error 40; una IP mal formada enseña las IPs libres" {
    run bash "$SCRIPT" --dry-run --red 'a,b' server1
    assert_failure 40
    run bash "$SCRIPT" --dry-run server1 192.168.7
    assert_failure 41
    assert_output --partial "IPs libres"
}

@test "un conflicto se detecta antes de descargar la imagen base" {
    rm "$SILO/noble-server-cloudimg-amd64.img"
    touch "$SILO/server1.qcow2"
    run bash "$SCRIPT" server1
    assert_failure 21
    [ "$(llamadas '^wget')" -eq 0 ]
}

@test "si falla un nodo del clúster, se deshacen los nodos pero la base recién construida se conserva" {
    MOCK_VIRT_INSTALL_FALLA_EN=4 run bash "$SCRIPT" --gluster-cluster
    assert_failure
    [ -e "$SILO/gluster-base.qcow2" ]
    assert_output --partial "--base gluster-base.qcow2"
    assert_output --partial "se conserva"
    ! dominio_existe "${USUARIO}-server1"
    [ ! -e "$SILO/server1.qcow2" ] && [ ! -e "$SILO/server3.qcow2" ]
}

@test "si cloud-init no termina pero el agente ya da la IP, el aviso y el resumen la muestran" {
    MOCK_CI_RUNNING=999 CI_PROVISION_WAIT_TIMEOUT=3 run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "ya responde en 192.168.7."
    refute_output --partial "consúltala con"
    assert_output --regexp "IP           : 192\\.168\\.7\\.[0-9]+ \\(DHCP\\)"
}

@test "sin wget se descarga con curl" {
    # PATH sin el wget real: los mocks, qemu-img y jq, y solo /usr/bin y /bin
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    ln -s "$REPO_DIR/test/mocks/virsh" "$bin/virsh"
    ln -s "$REPO_DIR/test/mocks/virt-install" "$bin/virt-install"
    ln -s "$REPO_DIR/test/mocks/curl" "$bin/curl"
    ln -s "$(command -v qemu-img)" "$bin/qemu-img"
    ln -s "$(command -v jq)" "$bin/jq"
    if PATH="$bin:/usr/bin:/bin" command -v wget >/dev/null 2>&1; then
        skip "hay un wget en /usr/bin: no se puede aislar la rama de curl"
    fi
    rm "$SILO/noble-server-cloudimg-amd64.img"
    # "$BASH": el bash con el que corre bats, no el /bin/bash del sistema (en macOS es 3.2)
    PATH="$bin:/usr/bin:/bin" run "$BASH" "$SCRIPT" server1
    assert_success
    [ "$(llamadas '^curl .*noble-server-cloudimg-amd64.img$')" -eq 1 ]
    [ "$(llamadas '^curl .*SHA256SUMS')" -eq 1 ]
    [ "$(qinfo "$SILO/noble-server-cloudimg-amd64.img" '.format')" = "qcow2" ]
}

@test "el agente puede tardar en devolver el resultado de cloud-init status" {
    MOCK_EXEC_PENDIENTE=3 run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "operativa tras"
    refute_output --partial "se da por terminado"
}

@test "si --limpiar no consigue eliminar el dominio: error 21 con el comando" {
    run bash "$SCRIPT" server1
    assert_success
    MOCK_UNDEFINE_FALLA=1 run bash "$SCRIPT" --si --limpiar server1 </dev/null
    assert_failure 21
    assert_output --partial "No se ha podido eliminar el dominio"
    assert_output --partial "virsh undefine ${USUARIO}-server1 --snapshots-metadata"
}

@test "si no se consigue expulsar el medio de cloud-init, se avisa y se termina bien" {
    MOCK_EJECT_NUNCA=1 run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "no se ha podido expulsar el medio"
    assert_output --partial "Apaga la máquina antes de tomar instantáneas"
}

@test "domifaddr con varias interfaces: se toma la IPv4 que no es loopback" {
    MOCK_VARIAS_IFACES=1 run bash "$SCRIPT" server1
    assert_success
    assert_output --regexp "operativa tras [0-9]+s\\. IP: 192\\.168\\.7\\.[0-9]+"
}

@test "aviso de known_hosts cuando la IP ya figura con otra clave" {
    echo "192.168.7.2 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOldKeyOldKeyOldKeyOldKeyOldKeyOldKeyOldKey" > "$HOME/.ssh/known_hosts"
    run bash "$SCRIPT" server1 192.168.7.2
    assert_success
    assert_output --partial "ya figuran en tu known_hosts"
    assert_output --partial "ssh-keygen -f \"$HOME/.ssh/known_hosts\" -R \"192.168.7.2\""
}

@test "red definida con prefix= en vez de netmask=, y red sin bloque IPv4 (error 43)" {
    quitar_red "${USUARIO}-red"
    {
        echo "<network>"
        echo "  <name>${USUARIO}-red</name>"
        echo "  <ip address=\"192.168.7.1\" prefix=\"24\">"
        echo "    <dhcp><range start=\"192.168.7.128\" end=\"192.168.7.254\"/></dhcp>"
        echo "  </ip>"
        echo "</network>"
    } > "$MOCK_STATE/red-${USUARIO}-red.xml"
    echo "${USUARIO}-red" >> "$MOCK_STATE/redes.txt"
    run bash "$SCRIPT" --dry-run server1 192.168.7.50
    assert_success
    assert_output --partial "prefijo /24"
    {
        echo "<network>"
        echo "  <name>${USUARIO}-red</name>"
        echo "  <ip family='ipv6' address='fd00::1' prefix='64'/>"
        echo "</network>"
    } > "$MOCK_STATE/red-${USUARIO}-red.xml"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 43
    assert_output --partial "virsh net-dumpxml ${USUARIO}-red"
}

@test "--tam se aplica a la base y a los nodos del clúster; las opciones de acceso llegan al resumen" {
    run bash "$SCRIPT" --gluster-cluster --tam 20G --no-root --ssh-pass Clave1 --no-virt-viewer
    assert_success
    [ "$(qinfo "$SILO/gluster-base.qcow2" '."virtual-size"')" -eq $(( 20 * 1024 * 1024 * 1024 )) ]
    [ "$(qinfo "$SILO/server4.qcow2" '."virtual-size"')" -eq $(( 20 * 1024 * 1024 * 1024 )) ]
    assert_output --partial "(o con la contraseña: Clave1)"
    assert_output --partial "administrador, contraseña: Clave1"
    refute_output --partial "virt-viewer --connect"
    grep -q "password: 'Clave1'" "$SILO/cloudinit-${USUARIO}-server3/cip-user.yaml"
    ! grep -q "name: root" "$SILO/cloudinit-${USUARIO}-server3/cip-user.yaml"
}

@test "clúster desde ubuntu-base: --tam menor que 64G no vale; uno mayor amplía la copia y los nodos" {
    run bash "$SCRIPT" --dry-run --gluster-cluster --imagen ubuntu-base --tam 40G
    assert_failure 15
    run bash "$SCRIPT" --gluster-cluster --imagen ubuntu-base --tam 80G
    assert_success
    [ "$(qinfo "$SILO/gluster-base.qcow2" '."virtual-size"')" -eq $(( 80 * 1024 * 1024 * 1024 )) ]
    [ "$(qinfo "$SILO/server2.qcow2" '."virtual-size"')" -eq $(( 80 * 1024 * 1024 * 1024 )) ]
    [ "$(qinfo "$UBUNTU_BASE_COMPARTIDA" '."virtual-size"')" -eq $(( 64 * 1024 * 1024 * 1024 )) ]
}

@test "nombre de máquina de más de 63 caracteres: error 20" {
    run bash "$SCRIPT" --dry-run "$(printf 'a%.0s' {1..64})"
    assert_failure 20
}

@test "--glusterfs a partir de otra base (--base) y clúster con --prefijo y --base" {
    run bash "$SCRIPT" --glusterfs gluster-base
    assert_success
    run bash "$SCRIPT" --glusterfs --base gluster-base.qcow2 gluster2
    assert_success
    [ "$(qinfo "$SILO/gluster2.qcow2" '."backing-filename"')" = "gluster-base.qcow2" ]
    run bash "$SCRIPT" --prefijo demo --gluster-cluster --base gluster2.qcow2
    assert_success
    assert_output --partial "Fase 1 de 2: se omite"
    [ "$(qinfo "$SILO/demo-server1.qcow2" '."backing-filename"')" = "gluster2.qcow2" ]
    [ ! -e "$SILO/demo-gluster-base.qcow2" ]
    dominio_existe "demo-server4"
}

@test "--ram y --vcpus llegan a virt-install" {
    run bash "$SCRIPT" --ram 4096 --vcpus 4 server1
    assert_success
    [ "$(llamadas '--ram 4096 --vcpus 4')" -eq 1 ]
}

@test "--no-wait no consulta al agente ni expulsa el medio" {
    run bash "$SCRIPT" --no-wait server1
    assert_success
    assert_output --partial "--no-wait"
    [ "$(llamadas 'domifaddr')" -eq 0 ]
    [ "$(llamadas 'change-media')" -eq 0 ]
    [ -e "$MOCK_STATE/dominios/${USUARIO}-server1/iso" ]
}

#############################################
# Conflictos y --limpiar
#############################################

@test "si el disco ya existe: error 21 con instrucciones y sin crear nada" {
    touch "$SILO/server1.qcow2"
    run bash "$SCRIPT" server1
    assert_failure 21
    assert_output --partial "rm $SILO/server1.qcow2"
    assert_output --partial "--limpiar"
    [ "$(llamadas '^virt-install')" -eq 0 ]
    ! dominio_existe "${USUARIO}-server1"
}

@test "si el dominio ya existe: error 21 con el undefine" {
    bash "$SCRIPT" --no-wait server1 >/dev/null
    rm -f "$SILO/server1.qcow2"
    run bash "$SCRIPT" server1
    assert_failure 21
    assert_output --partial "virsh undefine ${USUARIO}-server1"
}

@test "--limpiar elimina exactamente lo que va a crear y sigue" {
    bash "$SCRIPT" --no-wait --extra-disks server1 >/dev/null
    touch "$SILO/otro.qcow2" "$SILO/server2.qcow2"
    : > "$MOCK_STATE/log"

    run bash "$SCRIPT" --si --limpiar --extra-disks server1 </dev/null
    assert_success
    assert_output --partial "--limpiar: se van a eliminar"
    [ "$(llamadas "undefine ${USUARIO}-server1")" -eq 1 ]
    [ "$(llamadas '^virt-install')" -eq 1 ]
    dominio_existe "${USUARIO}-server1"
    # Lo que no era suyo sigue ahí
    [ -e "$SILO/otro.qcow2" ]
    [ -e "$SILO/server2.qcow2" ]
    [ -e "$SILO/debian12.qcow2" ]
}

#############################################
# Fallos a medias: aviso y rollback
#############################################

@test "si virt-install falla: lo dice, borra los discos que había creado y no deja dominio" {
    MOCK_VIRT_INSTALL_FALLA=1 run bash "$SCRIPT" --extra-disks server1
    assert_failure
    assert_output --partial "terminado de forma inesperada"
    assert_output --partial "Deshaciendo"
    [ ! -e "$SILO/server1.qcow2" ]
    [ ! -e "$SILO/server1-vdb.qcow2" ]
    [ ! -e "$SILO/server1-vdg.qcow2" ]
    [ -e "$SILO/debian12.qcow2" ]
    ! dominio_existe "${USUARIO}-server1"
}

@test "un error de validación no deja rastro" {
    run bash "$SCRIPT" server1 192.168.7.200
    assert_failure 42
    refute_output --partial "Deshaciendo"
    [ ! -e "$SILO/server1.qcow2" ]
}

#############################################
# Espera a cloud-init
#############################################

@test "espera aunque el agente tarde en responder" {
    MOCK_AGENT_DELAY=3 run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "operativa tras"
    [ "$(llamadas 'domifaddr')" -ge 4 ]
}

@test "no da la máquina por lista mientras cloud-init siga en marcha" {
    MOCK_CI_RUNNING=3 run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "operativa tras"
    [ "$(llamadas 'guest-exec-status')" -ge 4 ]
}

@test "si el agente no permite consultar cloud-init, se asume lista y se avisa" {
    MOCK_EXEC_UNSUPPORTED=1 run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "no se ha podido consultar el estado de cloud-init"
    assert_output --partial "Medio de cloud-init expulsado"
}

@test "si cloud-init termina con error, lo dice pero no aborta" {
    MOCK_CI_RESULT=error run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "informa de errores"
    assert_output --partial "cloud-init status --long"
}

@test "si se agota el tiempo: aviso, sin expulsar el medio, y el resumen igualmente" {
    MOCK_AGENT_DELAY=999 CI_PROVISION_WAIT_TIMEOUT=3 run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "no ha(n) terminado en 3s"
    [ "$(llamadas 'change-media')" -eq 0 ]
    assert_output --partial "consúltala con"
}

#############################################
# Clúster GlusterFS
#############################################

@test "clúster en --dry-run: plan de dos fases y sin efectos" {
    run bash "$SCRIPT" --dry-run --gluster-cluster
    assert_success
    assert_output --partial "Fase 1"
    assert_output --partial "Fase 2"
    assert_output --partial "${USUARIO}-server1  →  192.168.7.10"
    assert_output --partial "${USUARIO}-server4  →  192.168.7.13"
    assert_output --partial "1024 MB y 1 vCPU"
    [ "$(llamadas '^virt-install')" -eq 0 ]
    assert_output --partial "copia COW de noble-server-cloudimg-amd64.img, 40G"
    assert_output --partial "vdb, vdc y vdd en xfs, montados en /gluster1 /gluster2 /gluster3."
    [ ! -e "$SILO/gluster-base.qcow2" ]
    [ ! -e "$SILO/server1.qcow2" ]
    [ -d "$SILO/cloudinit-${USUARIO}-gluster-base.dry-run" ]
    [ -d "$SILO/cloudinit-${USUARIO}-server4.dry-run" ]
}

@test "clúster completo: base, apagado, 4 nodos con IP fija, discos y cloud-init propio" {
    run bash "$SCRIPT" --gluster-cluster
    assert_success

    # Fase 1: la base (copia COW de la imagen de Ubuntu, como SERVER1) se crea,
    # se espera, se apaga y se elimina su dominio; el disco queda
    [ "$(llamadas "shutdown ${USUARIO}-gluster-base")" -eq 1 ]
    [ "$(llamadas "undefine ${USUARIO}-gluster-base")" -eq 1 ]
    ! dominio_existe "${USUARIO}-gluster-base"
    [ "$(qinfo "$SILO/gluster-base.qcow2" '."backing-filename"')" = "noble-server-cloudimg-amd64.img" ]
    grep -q "glusterfs-server" "$SILO/cloudinit-${USUARIO}-gluster-base/cip-user.yaml"

    # Fase 2: cuatro nodos, COW de la base, con sus tres discos extra (los del boletín)
    [ "$(llamadas '^virt-install')" -eq 5 ]
    [ "$(llamadas '--os-variant ubuntu24.04')" -eq 5 ]
    local h u i
    for h in server1 server2 server3 server4; do
        dominio_existe "${USUARIO}-$h"
        [ "$(qinfo "$SILO/$h.qcow2" '."backing-filename"')" = "gluster-base.qcow2" ]
        [ "$(qinfo "$SILO/$h.qcow2" '."virtual-size"')" = "42949672960" ]
        for u in vdb vdc vdd; do
            [ -e "$SILO/$h-$u.qcow2" ]
        done
        [ ! -e "$SILO/$h-vde.qcow2" ]
    done
    local linea
    linea="$(grep "^virt-install.*--name ${USUARIO}-server2 " "$MOCK_STATE/log")"
    [ "$(grep -o -- '--disk path=' <<< "$linea" | wc -l | tr -d ' ')" -eq 4 ]
    [[ "$linea" == *"--ram 1024 --vcpus 1"* ]]

    # cloud-init de un nodo: sin apt, con /etc/hosts, xfs y montajes
    local un="$SILO/cloudinit-${USUARIO}-server2/cip-user.yaml"
    grep -q "^package_update: false" "$un"
    grep -q "^manage_etc_hosts: false" "$un"
    ! grep -q "glusterfs-server" "$un"
    grep -q "192.168.7.10 server1" "$un"
    grep -q "192.168.7.13 server4" "$un"
    grep -q "127.0.1.1 server2" "$un"
    grep -q "device: /dev/vdb" "$un"
    grep -q "device: /dev/vdd" "$un"
    ! grep -q "device: /dev/vde" "$un"
    grep -q "filesystem: xfs" "$un"
    # fstab con las mismas líneas que muestra el manual, y montaje en runcmd
    grep -q "/dev/vdc /gluster2 xfs auto,async,nofail 0 0' >> /etc/fstab" "$un"
    grep -q "mkdir -p /gluster1 /gluster2 /gluster3" "$un"
    grep -q -- "- mount -a" "$un"
    ! grep -q "^mounts:" "$un"
    # administrador como en SERVER1: tu clave y sudo sin contraseña
    grep -q "NOPASSWD" "$un"
    grep -q "^ssh_pwauth: false" "$un"
    ! grep -q "lock_passwd" "$un"
    grep -q "instance-id: ${USUARIO}-server2" "$SILO/cloudinit-${USUARIO}-server2/cip-meta.yaml"
    grep -q -- "- 192.168.7.11/24" "$SILO/cloudinit-${USUARIO}-server2/cip-net.yaml"

    # Espera a los cuatro, expulsa sus medios y resume
    for i in 1 2 3 4; do
        assert_output --partial "${USUARIO}-server$i operativa tras"
        [ ! -e "$MOCK_STATE/dominios/${USUARIO}-server$i/iso" ]
    done
    assert_output --regexp "${USUARIO}-server3 +192\.168\.7\.12 +hostname server3"
    assert_output --partial "Discos       : vdb..vdd (3 × 40G) en cada nodo"
    refute_output --partial "sudo la pide"
    assert_output --partial "no borres $SILO/gluster-base.qcow2"
    assert_output --partial "(nodos e imagen base)"
    assert_output --partial "--eliminar server1 server2 server3 server4 gluster-base"
}

@test "clúster con --discos-nodo 7: los siete discos de crea-entorno.sh, solo tres formateados" {
    run bash "$SCRIPT" --gluster-cluster --discos-nodo 7
    assert_success
    local u
    for u in vdb vdc vdd vde vdf vdg vdh; do
        [ -e "$SILO/server3-$u.qcow2" ]
    done
    local linea
    linea="$(grep "^virt-install.*--name ${USUARIO}-server3 " "$MOCK_STATE/log")"
    [ "$(grep -o -- '--disk path=' <<< "$linea" | wc -l | tr -d ' ')" -eq 8 ]
    ! grep -q "device: /dev/vde" "$SILO/cloudinit-${USUARIO}-server3/cip-user.yaml"
    assert_output --partial "vdb, vdc y vdd en xfs, montados en /gluster1 /gluster2 /gluster3; vde..vdh sin formatear"
    run bash "$SCRIPT" --dry-run --prefijo otro --gluster-cluster --discos-nodo 4 --ip-inicial 20
    assert_success
    assert_output --partial "; vde sin formatear."
    run bash "$SCRIPT" --dry-run --gluster-cluster --discos-nodo 2
    assert_failure 13
    run bash "$SCRIPT" --dry-run --gluster-cluster --discos-nodo 8
    assert_failure 13
    run bash "$SCRIPT" --dry-run --gluster-cluster --discos-nodo tres
    assert_failure 13
}

@test "clúster con --imagen debian12: la base es copia COW de Debian y administrador como en SERVER1" {
    run bash "$SCRIPT" --gluster-cluster --imagen debian12
    assert_success
    [ "$(qinfo "$SILO/gluster-base.qcow2" '."backing-filename"')" = "debian12.qcow2" ]
    [ "$(llamadas '--os-variant debian12')" -eq 5 ]
    grep -q "NOPASSWD" "$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    grep -q "^ssh_pwauth: false" "$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    refute_output --partial "sudo la pide"
}

@test "clúster: conflicto con un disco de un nodo, y --limpiar lo resuelve" {
    touch "$SILO/server3-vdd.qcow2"
    run bash "$SCRIPT" --gluster-cluster
    assert_failure 21
    assert_output --partial "server3-vdd.qcow2"
    [ "$(llamadas '^virt-install')" -eq 0 ]

    run bash "$SCRIPT" --si --limpiar --gluster-cluster </dev/null
    assert_success
    [ "$(llamadas '^virt-install')" -eq 5 ]
}

@test "clúster con --base: se omite la fase 1 y --limpiar no toca la imagen base" {
    qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 "$SILO/mibase.qcow2" 40G >/dev/null
    touch "$SILO/server2.qcow2"
    run bash "$SCRIPT" --si --limpiar --gluster-cluster --base mibase.qcow2 </dev/null
    assert_success
    assert_output --partial "Fase 1 de 2: se omite"
    refute_output --partial "Creando la máquina '${USUARIO}-gluster-base'"
    [ "$(llamadas '^virt-install')" -eq 4 ]
    [ "$(llamadas '--os-variant debian12')" -eq 4 ]
    [ -e "$SILO/mibase.qcow2" ]
    [ ! -e "$SILO/gluster-base.qcow2" ]
    local h
    for h in server1 server2 server3 server4; do
        [ "$(qinfo "$SILO/$h.qcow2" '."backing-filename"')" = "mibase.qcow2" ]
    done
    assert_output --partial "no borres $SILO/mibase.qcow2"
}

@test "clúster con --base inexistente o que no es qcow2: error 39" {
    run bash "$SCRIPT" --dry-run --gluster-cluster --base noexiste.qcow2
    assert_failure 39
    echo "hola" > "$SILO/rota.qcow2"
    run bash "$SCRIPT" --dry-run --gluster-cluster --base rota.qcow2
    assert_failure 39
}

@test "--base no puede ser uno de los discos que se van a crear" {
    qemu-img create -f qcow2 "$SILO/server1.qcow2" 1G >/dev/null
    run bash "$SCRIPT" --dry-run --gluster-cluster --base server1.qcow2
    assert_failure 10
    run bash "$SCRIPT" --dry-run --base server1.qcow2 server1
    assert_failure 10
}

@test "clúster: si las IPs .10-.13 caen en el DHCP de la red, error 42 antes de crear nada" {
    quitar_red "${USUARIO}-red"
    definir_red "${USUARIO}-red" 192.168.144.1 255.255.255.0 192.168.144.2 192.168.144.127
    run bash "$SCRIPT" --gluster-cluster
    assert_failure 42
    assert_output --partial "192.168.144.10"
    [ "$(llamadas '^virt-install')" -eq 0 ]
}

@test "clúster: si la base no se apaga, error 70 y rollback de la base" {
    MOCK_SHUTDOWN_NUNCA=1 run bash "$SCRIPT" --gluster-cluster
    assert_failure 70
    assert_output --partial "Deshaciendo"
    ! dominio_existe "${USUARIO}-gluster-base"
    [ ! -e "$SILO/gluster-base.qcow2" ]
    [ ! -e "$SILO/server1.qcow2" ]
}

@test "clúster: si cloud-init falla en la base, error 71, la base se conserva y no hay nodos" {
    MOCK_CI_RESULT=error run bash "$SCRIPT" --gluster-cluster
    assert_failure 71
    dominio_existe "${USUARIO}-gluster-base"
    [ -e "$SILO/gluster-base.qcow2" ]
    ! dominio_existe "${USUARIO}-server1"
    [ ! -e "$SILO/server1.qcow2" ]
}

@test "clúster con --no-wait: espera a la base pero no a los nodos" {
    run bash "$SCRIPT" --no-wait --gluster-cluster
    assert_success
    [ "$(llamadas "domifaddr ${USUARIO}-gluster-base")" -ge 1 ]
    [ "$(llamadas "domifaddr ${USUARIO}-server1")" -eq 0 ]
    [ "$(llamadas '^virt-install')" -eq 5 ]
}

@test "clúster: --ram y --vcpus sobrescriben los valores por nodo" {
    run bash "$SCRIPT" --dry-run --gluster-cluster --ram 2048 --vcpus 2
    assert_success
    assert_output --partial "2048 MB y 2 vCPU"
}

#############################################
# Regresión de la auditoría de la v3.0.0
#############################################

@test "auditoría 1: --eliminar-todo no borra la imagen base de una copia que se conserva (aunque sea indirecta)" {
    run bash "$SCRIPT" --glusterfs gluster-base
    assert_success
    # Cadena: gluster-base ← intermedia ← copia, y 'copia' la usa una máquina hecha a mano
    (cd "$SILO" && qemu-img create -f qcow2 -b gluster-base.qcow2 -F qcow2 intermedia.qcow2 >/dev/null \
                && qemu-img create -f qcow2 -b intermedia.qcow2 -F qcow2 copia.qcow2 >/dev/null)
    definir_dominio SERVIDOR-A-MANO running "$SILO/copia.qcow2"
    run bash "$SCRIPT" --si --eliminar-todo </dev/null
    assert_success
    assert_output --partial "copia.qcow2: lo usa la máquina 'SERVIDOR-A-MANO'"
    assert_output --partial "intermedia.qcow2: es la imagen base de copia.qcow2, que se conserva"
    assert_output --partial "gluster-base.qcow2: es la imagen base de intermedia.qcow2, que se conserva"
    [ -e "$SILO/gluster-base.qcow2" ] && [ -e "$SILO/intermedia.qcow2" ] && [ -e "$SILO/copia.qcow2" ]
}

@test "auditoría 1: --eliminar conserva la base de un disco que se queda porque lo usa otra máquina" {
    run bash "$SCRIPT" --glusterfs gluster-base
    assert_success
    run bash "$SCRIPT" --base gluster-base.qcow2 server1
    assert_success
    # Otra máquina (otro nombre) usa también server1.qcow2
    definir_dominio "${USUARIO}-copia" running "$SILO/server1.qcow2"
    run bash "$SCRIPT" --si --eliminar server1 gluster-base </dev/null
    assert_success
    assert_output --partial "server1.qcow2: lo usa la máquina '${USUARIO}-copia'"
    assert_output --partial "gluster-base.qcow2: es la imagen base de server1.qcow2, que se conserva"
    [ -e "$SILO/gluster-base.qcow2" ] && [ -e "$SILO/server1.qcow2" ]
    ! dominio_existe "${USUARIO}-server1"
}

@test "auditoría 2: sin terminal y sin --si no se elimina nada (error 23); libvirt del sistema" {
    run bash "$SCRIPT" server1
    assert_success
    [ "$(cat "$MOCK_STATE/uri")" = "qemu:///system" ]
    touch "$SILO/mi-copia-seguridad.qcow2"
    run bash "$SCRIPT" --eliminar-todo </dev/null
    assert_failure 23
    assert_output --partial "--si"
    dominio_existe "${USUARIO}-server1"
    [ -e "$SILO/mi-copia-seguridad.qcow2" ] && [ -e "$SILO/server1.qcow2" ]
    run bash "$SCRIPT" --eliminar server1 </dev/null
    assert_failure 23
    dominio_existe "${USUARIO}-server1"
    run bash "$SCRIPT" --limpiar server1 </dev/null
    assert_failure 23
    dominio_existe "${USUARIO}-server1"
    [ "$(llamadas '^virt-install')" -eq 1 ]
    # Aunque el entorno traiga otra (p.ej. qemu:///session), se usa la del sistema
    LIBVIRT_DEFAULT_URI=qemu:///session run bash "$SCRIPT" --listar
    [ "$(cat "$MOCK_STATE/uri")" = "qemu:///system" ]
}

@test "auditoría 3: --eliminar y --limpiar no borran un disco que usa una máquina con otro nombre" {
    run bash "$SCRIPT" server1
    assert_success
    run bash "$SCRIPT" --si --eliminar server1 </dev/null
    assert_success
    qemu-img create -f qcow2 "$SILO/server1.qcow2" 1G >/dev/null
    definir_dominio mi-servidor running "$SILO/server1.qcow2"
    run bash "$SCRIPT" --si --eliminar server1 </dev/null
    assert_failure 22
    assert_output --partial "server1.qcow2: lo usa la máquina 'mi-servidor'"
    [ -e "$SILO/server1.qcow2" ]
    run bash "$SCRIPT" --si --limpiar server1 </dev/null
    assert_failure 21
    assert_output --partial "lo usa la máquina 'mi-servidor'"
    [ "$(qinfo "$SILO/server1.qcow2" '."virtual-size"')" = "1073741824" ]
}

@test "auditoría 4: con --prefijo no se tocan las máquinas de otro usuario que se llamen igual" {
    # 'demo-server1' es de otro usuario: sus discos no están en este silo
    definir_dominio demo-server1 running /home/otro/imagenesMV/server1.qcow2
    run bash "$SCRIPT" --si --prefijo demo --limpiar server1 </dev/null
    assert_failure 21
    assert_output --partial "sus discos no están en tu silo"
    dominio_existe demo-server1
    run bash "$SCRIPT" --si --prefijo demo --eliminar server1 </dev/null
    assert_failure 22
    assert_output --partial "no la ha creado este script para ti"
    run bash "$SCRIPT" --si --prefijo demo --eliminar-todo </dev/null
    assert_failure 22
    dominio_existe demo-server1
    [ "$(llamadas 'undefine demo-server1')" -eq 0 ]
    run bash "$SCRIPT" --prefijo demo --listar
    assert_output --partial "No tienes máquinas"
}

@test "auditoría 5 y 6: --menu --dry-run no crea nada; la contraseña no va en la línea de órdenes" {
    export MOCK_WHIPTAIL="$BATS_TEST_TMPDIR/respuestas"
    printf '%s\n' "0 basica" "0 web" "0 " "0 noble" "0 \"ssh-pass\"" "0 Secreta1" "0" "1" > "$MOCK_WHIPTAIL"
    # Un 'bash' que anota sus argumentos: así se ve qué recibe el proceso hijo
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!%s\necho "$*" >> "%s/argv"\nexec %q "$@"\n' "$BASH" "$MOCK_STATE" "$BASH" > "$bin/bash"
    chmod +x "$bin/bash"
    PATH="$bin:$PATH" run bash "$SCRIPT" --menu --dry-run </dev/null
    assert_success
    assert_output --partial "→ $SCRIPT --dry-run --ssh-pass •••••• web"
    assert_output --partial "MODO SIMULACIÓN"
    ! dominio_existe "${USUARIO}-web"
    [ ! -e "$SILO/web.qcow2" ]
    grep -q -- "--ssh-pass - web" "$MOCK_STATE/argv"
    ! grep -q "Secreta1" "$MOCK_STATE/argv"
    grep -q "password: 'Secreta1'" "$SILO/cloudinit-${USUARIO}-web.dry-run/cip-user.yaml"
}

@test "auditoría 7: cloud-init terminado con avisos (código 2) no se da por bueno en la base GlusterFS" {
    MOCK_CI_RESULT=degraded run bash "$SCRIPT" --glusterfs gluster-base
    assert_failure 71
    MOCK_CI_RESULT=degraded run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "informa de errores"
}

@test "auditoría 8: --base con la cadena rota (39), sin imagen reconocible (aviso) o con --imagen" {
    (cd "$SILO" && qemu-img create -u -f qcow2 -b no-existe.qcow2 -F qcow2 rota.qcow2 1G >/dev/null)
    run bash "$SCRIPT" --dry-run --base rota.qcow2 server1
    assert_failure 39
    assert_output --partial "backing-chain"
    cp "$SILO/noble-server-cloudimg-amd64.img" "$SILO/mi-noble.qcow2"
    run bash "$SCRIPT" --dry-run --base mi-noble.qcow2 server1
    assert_success
    assert_output --partial "AVISO: no sé de qué imagen sale mi-noble.qcow2"
    assert_output --partial "Ubuntu 24.04 (imagen cloud); variante ubuntu24.04"
    grep -q "NOPASSWD" "$SILO/cloudinit-${USUARIO}-server1.dry-run/cip-user.yaml"
    run bash "$SCRIPT" --dry-run --base mi-noble.qcow2 --imagen debian12 server1
    assert_success
    refute_output --partial "AVISO: no sé"
    assert_output --partial "variante debian12"
}

@test "auditoría 9: una clave pública con ': ' en el comentario va entre comillas en el YAML" {
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFalsa David: portátil #1" > "$HOME/.ssh/id_rsa.pub"
    run bash "$SCRIPT" --dry-run server1
    assert_success
    grep -qxF "      - 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFalsa David: portátil #1'" "$SILO/cloudinit-${USUARIO}-server1.dry-run/cip-user.yaml"
}

@test "auditoría 10: si el DHCP ocupa .10-.13, el clúster propone --ip-inicial, que funciona" {
    quitar_red "${USUARIO}-red"
    definir_red "${USUARIO}-red" 192.168.144.1 255.255.255.0 192.168.144.2 192.168.144.127
    run bash "$SCRIPT" --dry-run --gluster-cluster
    assert_failure 42
    assert_output --partial "--ip-inicial 128"
    refute_output --partial "omitir el parámetro IP"
    run bash "$SCRIPT" --dry-run --gluster-cluster --ip-inicial 200
    assert_success
    assert_output --partial "${USUARIO}-server1  →  192.168.144.200"
    assert_output --partial "${USUARIO}-server4  →  192.168.144.203"
    run bash "$SCRIPT" --dry-run --gluster-cluster --ip-inicial 252
    assert_failure 13
    run bash "$SCRIPT" --dry-run --ip-inicial 20 server1
    assert_failure 10
}

@test "auditoría 11: una IP fija que ya tiene otra máquina, o que responde a ping, se rechaza" {
    run bash "$SCRIPT" server1 192.168.7.2
    assert_success
    run bash "$SCRIPT" --dry-run server2 192.168.7.2
    assert_failure 42
    assert_output --partial "ya la tiene asignada tu máquina '${USUARIO}-server1'"
    assert_output --partial "--eliminar server1"
    # Rehacerla con --limpiar, con la misma IP, sí vale (aunque responda a ping)
    echo 192.168.7.2 > "$MOCK_STATE/ping_responde"
    run bash "$SCRIPT" --si --limpiar server1 192.168.7.2 </dev/null
    assert_success
    echo 192.168.7.30 > "$MOCK_STATE/ping_responde"
    run bash "$SCRIPT" --dry-run server3 192.168.7.30
    assert_failure 42
    assert_output --partial "Algo responde ya en la IP '192.168.7.30'"
}

@test "auditoría 12: --base no admite el disco de una máquina apagada" {
    run bash "$SCRIPT" server1
    assert_success
    run virsh shutdown "${USUARIO}-server1"
    run bash "$SCRIPT" --dry-run --base server1.qcow2 server2
    assert_failure 39
    assert_output --partial "es el disco de la máquina '${USUARIO}-server1'"
}

@test "auditoría 14: números con ceros a la izquierda se leen en decimal" {
    run bash "$SCRIPT" --dry-run --tam 080G --ram 0900 --vcpus 02 server1 192.168.7.020
    assert_success
    refute_output --partial "value too great"
    assert_output --partial "IP      : 192.168.7.20, disponible"
    assert_output --partial "Recursos: 900 MB y 2 vCPU"
    assert_output --partial "(copia COW de noble-server-cloudimg-amd64.img, 80G)"
    grep -q -- "- 192.168.7.20/24" "$SILO/cloudinit-${USUARIO}-server1.dry-run/cip-net.yaml"
    run bash "$SCRIPT" --dry-run --gluster-cluster --discos-nodo 07
    assert_success
    run bash "$SCRIPT" --dry-run --tam 08G server1
    assert_success
    assert_output --partial "(copia COW de noble-server-cloudimg-amd64.img, 8G)"
    run bash "$SCRIPT" --dry-run --tam 0G server1
    assert_failure 15
}

@test "auditoría 15: una red con DHCPv6 no rompe nada" {
    quitar_red "${USUARIO}-red"
    {
        echo "<network>"
        echo "  <name>${USUARIO}-red</name>"
        echo "  <ip family='ipv6' address='fd00::1' prefix='64'>"
        echo "    <dhcp><range start='fd00::100' end='fd00::1ff'/><host name='x' ip='fd00::5'/></dhcp>"
        echo "  </ip>"
        echo "  <ip address='192.168.7.1' netmask='255.255.255.0'>"
        echo "    <dhcp><range start='192.168.7.128' end='192.168.7.254'/></dhcp>"
        echo "  </ip>"
        echo "</network>"
    } > "$MOCK_STATE/red-${USUARIO}-red.xml"
    echo "${USUARIO}-red" >> "$MOCK_STATE/redes.txt"
    run bash "$SCRIPT" --dry-run server1 192.168.7.2
    assert_success
    run bash "$SCRIPT" --dry-run server1 192.168.7.130
    assert_failure 42
}

@test "auditoría 16, 17 y 22: mensajes de --user-pass, de la base que ya existe y de la clave pública" {
    run bash "$SCRIPT" --user-pass x server1
    assert_failure 12
    assert_output --partial "por consola entra root"
    refute_output --partial "'administrador' ya tiene contraseña"
    run bash "$SCRIPT" --glusterfs gluster-base
    assert_success
    run bash "$SCRIPT" --dry-run --gluster-cluster
    assert_failure 21
    assert_output --partial "--gluster-cluster --base gluster-base.qcow2"
    echo "esto no es una clave" > "$HOME/.ssh/id_rsa.pub"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 31
    assert_output --partial "no contiene una clave pública"
    refute_output --partial "1 líneas"
}

@test "auditoría 18: los fuentes funcionan sin generar el script (src/main.sh carga todas las librerías)" {
    run bash "$REPO_DIR/src/main.sh" --listar
    assert_success
    assert_output --partial "Discos del silo sin máquina"
}

@test "auditoría 19: las variables de entorno de espera llevan prefijo y se validan" {
    CI_PROVISION_POLL_SECS=x run bash "$SCRIPT" --dry-run server1
    assert_failure 13
    assert_output --partial "CI_PROVISION_POLL_SECS"
    CI_PROVISION_WAIT_TIMEOUT=abc run bash "$SCRIPT" --dry-run server1
    assert_failure 13
    # Las de nombre genérico ya no se leen
    WAIT_TIMEOUT=abc POLL_SECS=x run bash "$SCRIPT" --dry-run server1
    assert_success
}

@test "auditoría 20: el instance-id es nuevo en cada creación" {
    run bash "$SCRIPT" --dry-run server1
    assert_success
    grep -qE "^instance-id: ${USUARIO}-server1-[0-9]{14}$" "$SILO/cloudinit-${USUARIO}-server1.dry-run/cip-meta.yaml"
}

@test "auditoría 21: el asistente rechaza nombres que empiezan por '-' y la ficha respeta --prefijo" {
    export MOCK_WHIPTAIL="$BATS_TEST_TMPDIR/respuestas"
    printf '%s\n' "0 basica" "0 -h" "0" "1" > "$MOCK_WHIPTAIL"
    run bash "$SCRIPT" --menu </dev/null
    assert_success
    grep -q -- "El nombre '-h' no es válido" "$MOCK_STATE/log"
    [ "$(llamadas '^virt-install')" -eq 0 ]
    run bash "$SCRIPT" --prefijo demo server1
    assert_success
    printf '%s\n' "0 listar" "0 m:demo-server1" "0" "1" "1" > "$MOCK_WHIPTAIL"
    run bash "$SCRIPT" --prefijo demo --menu </dev/null
    assert_success
    grep -q -- "--prefijo demo --eliminar server1" "$MOCK_STATE/log"
}

@test "auditoría 23: los nodos de ubuntu-base avisan de la contraseña común" {
    run bash "$SCRIPT" --gluster-cluster --imagen ubuntu-base --no-wait
    assert_success
    assert_output --partial "AVISO: 'administrador' conserva la contraseña de ubuntu-base"
    run bash "$SCRIPT" --si --limpiar --gluster-cluster --no-wait </dev/null
    assert_success
    refute_output --partial "conserva la contraseña de ubuntu-base"
}

@test "auditoría 24: la descarga se comprueba con la suma publicada; la copia compartida evita descargar" {
    rm -f "$SILO/noble-server-cloudimg-amd64.img"
    MOCK_SUMAS_MAL=1 run bash "$SCRIPT" --no-wait server1
    assert_failure 37
    assert_output --partial "no coincide con la suma publicada"
    [ ! -e "$SILO/noble-server-cloudimg-amd64.img" ]
    [ -z "$(ls "$SILO" | grep descargando || true)" ]
    MOCK_SUMAS_FALLA=1 run bash "$SCRIPT" --no-wait server1
    assert_success
    assert_output --partial "AVISO: no se ha podido descargar"
    [ -e "$SILO/noble-server-cloudimg-amd64.img" ]
    # Con la imagen en el directorio compartido, se copia y no se descarga nada
    run bash "$SCRIPT" --si --eliminar server1 </dev/null
    mv "$SILO/noble-server-cloudimg-amd64.img" "$CI_PROVISION_DIR_COMPARTIDO/"
    : > "$MOCK_STATE/log"
    run bash "$SCRIPT" --dry-run server1
    assert_output --partial "se copiará de $CI_PROVISION_DIR_COMPARTIDO/noble-server-cloudimg-amd64.img"
    run bash "$SCRIPT" --no-wait server1
    assert_success
    assert_output --partial "Se copia de"
    [ "$(llamadas '^wget')" -eq 0 ]
    [ -e "$SILO/noble-server-cloudimg-amd64.img" ]
}

@test "auditoría 25: el rollback quita también los ficheros cloud-init" {
    MOCK_VIRT_INSTALL_FALLA=1 run bash "$SCRIPT" server1
    assert_failure
    [ ! -d "$SILO/cloudinit-${USUARIO}-server1" ]
    assert_output --partial "ficheros cloud-init"
}

@test "auditoría 26: si la ISO sigue también en la definición persistente, se expulsa de las dos" {
    MOCK_ISO_PERSISTENTE=1 run bash "$SCRIPT" server1
    assert_success
    assert_output --partial "Medio de cloud-init expulsado"
    [ ! -e "$MOCK_STATE/dominios/${USUARIO}-server1/iso" ]
    [ ! -e "$MOCK_STATE/dominios/${USUARIO}-server1/iso_persistente" ]
}

@test "auditoría 13: --listar lee cada disco del silo una sola vez" {
    local i
    for i in $(seq 1 15); do
        qemu-img create -f qcow2 "$SILO/suelto$i.qcow2" 1G >/dev/null
    done
    # Un qemu-img que cuenta sus llamadas
    local bin="$BATS_TEST_TMPDIR/bin" real
    real="$(command -v qemu-img)"
    mkdir -p "$bin"
    printf '#!/bin/sh\necho x >> "%s/qemu-img.n"\nexec "%s" "$@"\n' "$MOCK_STATE" "$real" > "$bin/qemu-img"
    chmod +x "$bin/qemu-img"
    PATH="$bin:$PATH" run bash "$SCRIPT" --listar
    assert_success
    assert_output --partial "suelto15.qcow2"
    # 17 ficheros (15 sueltos y las dos imágenes cloud): antes eran cientos de llamadas
    [ "$(wc -l < "$MOCK_STATE/qemu-img.n")" -le 20 ]
}
