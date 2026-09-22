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
    rm -f "$SILO/debian12.qcow2"
    run bash "$SCRIPT" --no-wait server1
    assert_success
    assert_output --partial "Se descarga de:"
    assert_output --partial "Imagen base descargada"
    [ "$(llamadas '^wget .*debian-12-generic-amd64.qcow2')" -eq 1 ]
    [ "$(qinfo "$SILO/debian12.qcow2" '.format')" = "qcow2" ]
    [ ! -e "$SILO/debian12.qcow2.descargando" ]
    [ "$(qinfo "$SILO/server1.qcow2" '."backing-filename"')" = "debian12.qcow2" ]
}

@test "sin imagen base y --dry-run: avisa de que la descargaría, sin descargar" {
    rm -f "$SILO/debian12.qcow2"
    run bash "$SCRIPT" --dry-run server1
    assert_success
    assert_output --partial "se descargará de"
    [ "$(llamadas '^wget')" -eq 0 ]
    [ ! -e "$SILO/debian12.qcow2" ]
}

@test "la descarga se hace después de las demás validaciones" {
    rm -f "$SILO/debian12.qcow2"
    run bash "$SCRIPT" server1 192.168.7.200
    assert_failure 42
    [ "$(llamadas '^wget')" -eq 0 ]
}

@test "descarga fallida: error 37 con el comando manual y sin restos" {
    rm -f "$SILO/debian12.qcow2"
    MOCK_WGET_FALLA=1 run bash "$SCRIPT" server1
    assert_failure 37
    assert_output --partial "wget https://cloud.debian.org"
    [ ! -e "$SILO/debian12.qcow2" ]
    [ ! -e "$SILO/debian12.qcow2.descargando" ]
    refute_output --partial "Deshaciendo"
}

@test "descarga corrupta (portal cautivo): error 37 y se elimina lo descargado" {
    rm -f "$SILO/debian12.qcow2"
    MOCK_WGET_CORRUPTO=1 run bash "$SCRIPT" server1
    assert_failure 37
    assert_output --partial "se ha eliminado"
    [ ! -e "$SILO/debian12.qcow2" ]
}

@test "imagen base existente que no es un qcow2: error 37 y NO se toca" {
    echo "<html>404</html>" > "$SILO/debian12.qcow2"
    run bash "$SCRIPT" --dry-run server1
    assert_failure 37
    assert_output --partial "rm $SILO/debian12.qcow2"
    [ -e "$SILO/debian12.qcow2" ]
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
    run bash "$SCRIPT" --dry-run --limpiar server1 </dev/null
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

    # Disco COW del tamaño por defecto
    [ "$(qinfo "$SILO/server1.qcow2" '."backing-filename"')" = "debian12.qcow2" ]
    [ "$(qinfo "$SILO/server1.qcow2" '."virtual-size"')" = "42949672960" ]

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
    assert_output --partial "virsh console ${USUARIO}-server1"
}

@test "user-data por defecto: root con contraseña de consola, administrador sin ella, SSH solo por clave" {
    run bash "$SCRIPT" server1
    assert_success
    local u="$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    grep -q "^#cloud-config" "$u"
    ! grep -q "administrador:" "$u"
    grep -q "root:s1st3mas" "$u"
    grep -q "^ssh_pwauth: false" "$u"
    grep -q "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0falsa" "$u"
    grep -q "qemu-guest-agent" "$u"
    ! grep -q "glusterfs-server" "$u"
    grep -q "instance-id: ${USUARIO}-server1" "$SILO/cloudinit-${USUARIO}-server1/cip-meta.yaml"
    grep -q "local-hostname: server1" "$SILO/cloudinit-${USUARIO}-server1/cip-meta.yaml"
}

@test "--no-root: root sin contraseña; sin --ssh-pass no hay chpasswd" {
    run bash "$SCRIPT" --no-root server1
    assert_success
    local u="$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    ! grep -q "root:" "$u"
    ! grep -q "chpasswd" "$u"
    assert_output --partial "root sin contraseña"
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
    grep -q "administrador:MiPass1" "$u"
    ! grep -q "root:" "$u"
}

@test "--base en una máquina suelta: copia COW de esa imagen, sin descargar nada" {
    qemu-img create -f qcow2 "$SILO/mibase.qcow2" 3G >/dev/null
    rm -f "$SILO/debian12.qcow2"
    run bash "$SCRIPT" --base mibase.qcow2 server1 192.168.7.10
    assert_success
    [ "$(qinfo "$SILO/server1.qcow2" '."backing-filename"')" = "mibase.qcow2" ]
    [ "$(llamadas '^wget')" -eq 0 ]
    assert_output --partial "copia COW de mibase.qcow2"
}

@test "--ssh-pass activa el SSH por contraseña con la contraseña elegida" {
    run bash "$SCRIPT" --ssh-pass MiPass1 server1
    assert_success
    local u="$SILO/cloudinit-${USUARIO}-server1/cip-user.yaml"
    grep -q "^ssh_pwauth: true" "$u"
    grep -q "administrador:MiPass1" "$u"
    grep -q "root:s1st3mas" "$u"
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
    run bash "$SCRIPT" --glusterfs glusterbase
    assert_success
    local u="$SILO/cloudinit-${USUARIO}-glusterbase/cip-user.yaml"
    grep -q "glusterfs-server" "$u"
    grep -q "xfsprogs" "$u"
    # enable glusterd antes de arrancar el agente; truncate del machine-id después
    local runcmd
    runcmd="$(sed -n '/^runcmd:/,$p' "$u" | tr '\n' ' ')"
    [[ "$runcmd" == *"systemctl enable glusterd"*"systemctl start qemu-guest-agent"*"truncate -s 0 /etc/machine-id"* ]]

    # Se espera, se apaga y se elimina el dominio; el disco se conserva
    [ "$(llamadas 'domifaddr')" -ge 1 ]
    [ "$(llamadas "shutdown ${USUARIO}-glusterbase")" -eq 1 ]
    [ "$(llamadas "undefine ${USUARIO}-glusterbase")" -eq 1 ]
    ! dominio_existe "${USUARIO}-glusterbase"
    [ "$(qinfo "$SILO/glusterbase.qcow2" '."backing-filename"')" = "debian12.qcow2" ]
    assert_output --partial "Imagen base GlusterFS lista"
    assert_output --partial "qemu-img create -f qcow2 -b glusterbase.qcow2"
}

@test "--glusterfs no admite --no-wait" {
    run bash "$SCRIPT" --no-wait --glusterfs glusterbase
    assert_failure 10
}

@test "--glusterfs: si cloud-init falla, error 71 y no queda ni disco ni dominio" {
    MOCK_CI_RESULT=error run bash "$SCRIPT" --glusterfs glusterbase
    assert_failure 71
    ! dominio_existe "${USUARIO}-glusterbase"
    [ ! -e "$SILO/glusterbase.qcow2" ]
}

@test "--disco y --tam cambian el nombre y el tamaño del disco principal" {
    run bash "$SCRIPT" --disco mio.qcow2 --tam 20G server1
    assert_success
    [ -e "$SILO/mio.qcow2" ]
    [ ! -e "$SILO/server1.qcow2" ]
    [ "$(qinfo "$SILO/mio.qcow2" '."virtual-size"')" = "21474836480" ]
    assert_output --partial "mio.qcow2 (20G)"
}

@test "--prefijo: dominio y discos con prefijo; lo de tu usuario no se toca ni con --limpiar" {
    run bash "$SCRIPT" server1
    assert_success
    run bash "$SCRIPT" --limpiar --prefijo demo --extra-disks server1 </dev/null
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
    touch "$SILO/glusterbase.qcow2" "$SILO/server1.qcow2"
    run bash "$SCRIPT" --prefijo demo --gluster-cluster
    assert_success
    [ "$(llamadas '--name demo-glusterbase')" -eq 1 ]
    [ "$(llamadas '--name demo-server')" -eq 4 ]
    [ -e "$SILO/demo-glusterbase.qcow2" ]
    [ "$(qinfo "$SILO/demo-server3.qcow2" '."backing-filename"')" = "demo-glusterbase.qcow2" ]
    [ -e "$SILO/demo-server4-vdh.qcow2" ]
    grep -q -r '^local-hostname: server2$' "$SILO/cloudinit-demo-server2/"
    assert_output --partial "no borres $SILO/demo-glusterbase.qcow2"
    [ -e "$SILO/glusterbase.qcow2" ] && [ -e "$SILO/server1.qcow2" ]
}

@test "--prefijo no válido: error 20; sin valor: error 11" {
    run bash "$SCRIPT" --prefijo 'demo/x' server1
    assert_failure 20
    run bash "$SCRIPT" server1 --prefijo
    assert_failure 11
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

    run bash "$SCRIPT" --limpiar --extra-disks server1 </dev/null
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
    MOCK_AGENT_DELAY=999 WAIT_TIMEOUT=3 run bash "$SCRIPT" server1
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
    [ ! -e "$SILO/glusterbase.qcow2" ]
    [ ! -e "$SILO/server1.qcow2" ]
    [ -d "$SILO/cloudinit-${USUARIO}-glusterbase.dry-run" ]
    [ -d "$SILO/cloudinit-${USUARIO}-server4.dry-run" ]
}

@test "clúster completo: base, apagado, 4 nodos con IP fija, discos y cloud-init propio" {
    run bash "$SCRIPT" --gluster-cluster
    assert_success

    # Fase 1: la base se crea, se espera, se apaga y se elimina su dominio; el disco queda
    [ "$(llamadas "shutdown ${USUARIO}-glusterbase")" -eq 1 ]
    [ "$(llamadas "undefine ${USUARIO}-glusterbase")" -eq 1 ]
    ! dominio_existe "${USUARIO}-glusterbase"
    [ "$(qinfo "$SILO/glusterbase.qcow2" '."backing-filename"')" = "debian12.qcow2" ]
    grep -q "glusterfs-server" "$SILO/cloudinit-${USUARIO}-glusterbase/cip-user.yaml"

    # Fase 2: cuatro nodos, COW de la base, con sus siete discos extra
    [ "$(llamadas '^virt-install')" -eq 5 ]
    local h u i
    for h in server1 server2 server3 server4; do
        dominio_existe "${USUARIO}-$h"
        [ "$(qinfo "$SILO/$h.qcow2" '."backing-filename"')" = "glusterbase.qcow2" ]
        for u in vdb vdc vdd vde vdf vdg vdh; do
            [ -e "$SILO/$h-$u.qcow2" ]
        done
    done
    local linea
    linea="$(grep "^virt-install.*--name ${USUARIO}-server2 " "$MOCK_STATE/log")"
    [ "$(grep -o -- '--disk path=' <<< "$linea" | wc -l | tr -d ' ')" -eq 8 ]
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
    grep -q "instance-id: ${USUARIO}-server2" "$SILO/cloudinit-${USUARIO}-server2/cip-meta.yaml"
    grep -q -- "- 192.168.7.11/24" "$SILO/cloudinit-${USUARIO}-server2/cip-net.yaml"

    # Espera a los cuatro, expulsa sus medios y resume
    for i in 1 2 3 4; do
        assert_output --partial "${USUARIO}-server$i operativa tras"
        [ ! -e "$MOCK_STATE/dominios/${USUARIO}-server$i/iso" ]
    done
    assert_output --regexp "${USUARIO}-server3 +192\.168\.7\.12 +hostname server3"
    assert_output --partial "no borres $SILO/glusterbase.qcow2"
}

@test "clúster: conflicto con un disco de un nodo, y --limpiar lo resuelve" {
    touch "$SILO/server3-vdh.qcow2"
    run bash "$SCRIPT" --gluster-cluster
    assert_failure 21
    assert_output --partial "server3-vdh.qcow2"
    [ "$(llamadas '^virt-install')" -eq 0 ]

    run bash "$SCRIPT" --limpiar --gluster-cluster </dev/null
    assert_success
    [ "$(llamadas '^virt-install')" -eq 5 ]
}

@test "clúster con --base: se omite la fase 1 y --limpiar no toca la imagen base" {
    qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 "$SILO/mibase.qcow2" 40G >/dev/null
    touch "$SILO/server2.qcow2"
    run bash "$SCRIPT" --limpiar --gluster-cluster --base mibase.qcow2 </dev/null
    assert_success
    assert_output --partial "Fase 1 de 2: se omite"
    refute_output --partial "Creando la máquina '${USUARIO}-glusterbase'"
    [ "$(llamadas '^virt-install')" -eq 4 ]
    [ -e "$SILO/mibase.qcow2" ]
    [ ! -e "$SILO/glusterbase.qcow2" ]
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
    ! dominio_existe "${USUARIO}-glusterbase"
    [ ! -e "$SILO/glusterbase.qcow2" ]
    [ ! -e "$SILO/server1.qcow2" ]
}

@test "clúster: si cloud-init falla en la base, error 71 y rollback" {
    MOCK_CI_RESULT=error run bash "$SCRIPT" --gluster-cluster
    assert_failure 71
    ! dominio_existe "${USUARIO}-glusterbase"
    [ ! -e "$SILO/glusterbase.qcow2" ]
}

@test "clúster con --no-wait: espera a la base pero no a los nodos" {
    run bash "$SCRIPT" --no-wait --gluster-cluster
    assert_success
    [ "$(llamadas "domifaddr ${USUARIO}-glusterbase")" -ge 1 ]
    [ "$(llamadas "domifaddr ${USUARIO}-server1")" -eq 0 ]
    [ "$(llamadas '^virt-install')" -eq 5 ]
}

@test "clúster: --ram y --vcpus sobrescriben los valores por nodo" {
    run bash "$SCRIPT" --dry-run --gluster-cluster --ram 2048 --vcpus 2
    assert_success
    assert_output --partial "2048 MB y 2 vCPU"
}
