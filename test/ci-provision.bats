setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    
    # Variables de entorno para tests
    export SCRIPT="./ci-provision.sh"
    export TEST_VM_NAME="test-vm-$$"
    export TEST_DISK="$HOME/imagenesMV/test-disk-$$.qcow2"
    export TEST_HOSTNAME="test-host"
    export TEST_NETWORK="default"
    export SILO_DIR="$HOME/imagenesMV"
    export DEBIAN_BASE="$HOME/imagenesMV/debian12.qcow2"
    
    # Crear directorio de pruebas si no existe
    mkdir -p "$SILO_DIR"
}

teardown() {
    # Limpiar VM de prueba si existe
    virsh destroy "$TEST_VM_NAME" 2>/dev/null || true
    virsh undefine "$TEST_VM_NAME" 2>/dev/null || true
    
    # Limpiar disco de prueba
    rm -f "$TEST_DISK"
    
    # Limpiar directorio cloudinit
    rm -rf "./cloudinit-${TEST_VM_NAME}"
}

#############################################
# PRUEBAS DE AYUDA
#############################################

@test "mostrar ayuda con -h" {
    run bash "$SCRIPT" -h
    assert_success
    assert_output --partial "Uso:"
    assert_output --partial "ci-provision"
}

@test "mostrar ayuda con --help" {
    run bash "$SCRIPT" --help
    assert_success
    assert_output --partial "Descripción:"
}

#############################################
# PRUEBAS DE VALIDACIÓN DE PARÁMETROS
#############################################

@test "error con número incorrecto de parámetros" {
    run bash "$SCRIPT" vm1
    assert_failure
    assert_output --partial "ERROR: Número incorrecto de parámetros"
}

@test "error con parámetros insuficientes" {
    run bash "$SCRIPT" vm1 disk1 host1
    assert_failure
    assert_output --partial "ERROR: Número incorrecto de parámetros"
}

@test "error con opción desconocida" {
    run bash "$SCRIPT" --opcion-invalida vm1 disk1 host1 default
    assert_failure
    assert_output --partial "ERROR: Opción desconocida"
}

#############################################
# PRUEBAS DE VALIDACIÓN DE DISCO
#############################################

@test "error cuando el disco no existe" {
    run bash "$SCRIPT" "$TEST_VM_NAME" "/ruta/inexistente.qcow2" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_failure
    assert_output --partial "ERROR: No existe el disco"
}

@test "error cuando el disco no está en SILO_DIR" {
    # Crear disco temporal fuera de SILO_DIR
    local temp_disk="/tmp/test-outside-$$.qcow2"
    touch "$temp_disk"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$temp_disk" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_failure
    assert_output --partial "ERROR: El disco debe estar dentro de"
    
    rm -f "$temp_disk"
}

@test "error cuando el disco no es qcow2" {
    # Crear archivo no-qcow2 en SILO_DIR
    local fake_disk="$SILO_DIR/fake-$$.img"
    touch "$fake_disk"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$fake_disk" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_failure
    assert_output --partial "ERROR: El disco no es qcow2"
    
    rm -f "$fake_disk"
}

@test "error cuando el disco no tiene backing file debian12.qcow2" {
    skip "Requiere crear imagen qcow2 sin backing correcto"
    
    local test_disk="$SILO_DIR/test-no-backing-$$.qcow2"
    qemu-img create -f qcow2 "$test_disk" 10G
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$test_disk" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_failure
    assert_output --partial "ERROR: El disco NO es copia COW de debian12.qcow2"
    
    rm -f "$test_disk"
}

@test "acepta disco válido con backing file correcto" {
    skip "Requiere debian12.qcow2 en $SILO_DIR"
    
    # Verificar que existe debian12.qcow2
    [ -f "$DEBIAN_BASE" ]
    
    # Crear disco de prueba con backing correcto
    qemu-img create -f qcow2 -b "$DEBIAN_BASE" -F qcow2 "$TEST_DISK" 10G
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_success
}

#############################################
# PRUEBAS DE VALIDACIÓN DE RED
#############################################

@test "error cuando la red no existe" {
    skip "Requiere disco válido en $SILO_DIR"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "red-inexistente"
    assert_failure
    assert_output --partial "ERROR: La red 'red-inexistente' no existe"
}

@test "acepta red existente" {
    skip "Requiere disco válido y red configurada"
    
    # Verificar que existe la red
    virsh net-list --all | grep -q "$TEST_NETWORK"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_success
}

#############################################
# PRUEBAS DE CLAVE PÚBLICA
#############################################

@test "error cuando no existe clave pública SSH" {
    skip "Requiere renombrar temporalmente ~/.ssh/id_rsa.pub"
    
    local ssh_key="$HOME/.ssh/id_rsa.pub"
    local backup="$HOME/.ssh/id_rsa.pub.bak"
    
    mv "$ssh_key" "$backup" 2>/dev/null || true
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_failure
    assert_output --partial "ERROR: No se encontró"
    assert_output --partial "ssh-keygen"
    
    mv "$backup" "$ssh_key" 2>/dev/null || true
}

@test "carga correctamente clave pública existente" {
    skip "Requiere disco y red válidos"
    
    # Verificar que existe la clave
    [ -f "$HOME/.ssh/id_rsa.pub" ]
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_success
}

#############################################
# PRUEBAS DE GENERACIÓN DE ARCHIVOS CLOUD-INIT
#############################################

@test "genera archivos cloud-init en directorio correcto" {
    skip "Requiere disco y red válidos"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    
    [ -d "./cloudinit-${TEST_VM_NAME}" ]
    [ -f "./cloudinit-${TEST_VM_NAME}/cip-user.yaml" ]
    [ -f "./cloudinit-${TEST_VM_NAME}/cip-meta.yaml" ]
}

@test "archivo meta-data contiene instance-id correcto" {
    skip "Requiere disco y red válidos"
    
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    
    run cat "./cloudinit-${TEST_VM_NAME}/cip-meta.yaml"
    assert_output --partial "instance-id: ${TEST_VM_NAME}"
    assert_output --partial "local-hostname: ${TEST_HOSTNAME}"
}

@test "archivo user-data contiene usuario administrador" {
    skip "Requiere disco y red válidos"
    
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    
    run cat "./cloudinit-${TEST_VM_NAME}/cip-user.yaml"
    assert_output --partial "name: administrador"
    assert_output --partial "groups: [sudo]"
    assert_output --partial "NOPASSWD:ALL"
}

@test "archivo user-data NO contiene contraseña por defecto" {
    skip "Requiere disco y red válidos"
    
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    
    run cat "./cloudinit-${TEST_VM_NAME}/cip-user.yaml"
    refute_output --partial "chpasswd:"
    refute_output --partial "ssh_pwauth:"
}

@test "archivo user-data contiene contraseña con --user-pass" {
    skip "Requiere disco y red válidos"
    
    bash "$SCRIPT" --user-pass "test123" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    
    run cat "./cloudinit-${TEST_VM_NAME}/cip-user.yaml"
    assert_output --partial "ssh_pwauth: true"
    assert_output --partial "administrador:test123"
}

@test "genera network-config cuando se proporciona IP" {
    skip "Requiere disco y red válidos"
    
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" "192.168.1.100"
    
    [ -f "./cloudinit-${TEST_VM_NAME}/cip-net.yaml" ]
    
    run cat "./cloudinit-${TEST_VM_NAME}/cip-net.yaml"
    assert_output --partial "192.168.1.100/24"
    assert_output --partial "gateway4: 192.168.1.1"
}

@test "NO genera network-config sin IP (DHCP)" {
    skip "Requiere disco y red válidos"
    
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    
    [ ! -f "./cloudinit-${TEST_VM_NAME}/cip-net.yaml" ]
}

#############################################
# PRUEBAS DE VALORES POR DEFECTO
#############################################

@test "usa valores por defecto para RAM y vCPUs" {
    skip "Requiere disco y red válidos"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_success
    assert_output --partial "RAM           : 2048 MB"
    assert_output --partial "vCPUs         : 2"
}

@test "acepta valores personalizados para RAM y vCPUs" {
    skip "Requiere disco y red válidos"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" "" 4096 4
    assert_success
    assert_output --partial "RAM           : 4096 MB"
    assert_output --partial "vCPUs         : 4"
}

#############################################
# PRUEBAS DE FUNCIONALIDAD --enable-root
#############################################

@test "sin --enable-root no aplica contraseña de root" {
    skip "Requiere disco y red válidos"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_success
    refute_output --partial "Estableciendo contraseña de root"
    assert_output --partial "Root NO habilitado"
}

@test "con --enable-root aplica contraseña y reinicia VM" {
    skip "Requiere disco y red válidos"
    
    run bash "$SCRIPT" --enable-root "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_success
    assert_output --partial "Solicitando apagado de la VM"
    assert_output --partial "Estableciendo contraseña de root"
    assert_output --partial "Iniciando VM"
}

#############################################
# PRUEBAS DE RESUMEN FINAL
#############################################

@test "muestra resumen completo al final" {
    skip "Requiere disco y red válidos"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" "192.168.1.50" 4096 4
    assert_success
    assert_output --partial "VM            : ${TEST_VM_NAME}"
    assert_output --partial "Hostname      : ${TEST_HOSTNAME}"
    assert_output --partial "Red           : ${TEST_NETWORK}"
    assert_output --partial "IP            : 192.168.1.50"
    assert_output --partial "RAM           : 4096 MB"
    assert_output --partial "vCPUs         : 4"
}

@test "resumen indica DHCP cuando no hay IP" {
    skip "Requiere disco y red válidos"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_success
    assert_output --partial "IP            : DHCP"
}

@test "resumen indica estado de root correctamente" {
    skip "Requiere disco y red válidos"
    
    run bash "$SCRIPT" --enable-root "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_success
    assert_output --partial "Root:"
    assert_output --partial "Habilitado SOLO consola"
    assert_output --partial "Contraseña: s1st3mas"
}

#############################################
# PRUEBAS DE INTEGRACIÓN COMPLETA
#############################################

@test "integración: crear VM completa con todas las opciones" {
    skip "Test de integración completa - ejecutar manualmente"
    
    # Verificar prerequisitos
    [ -f "$DEBIAN_BASE" ]
    [ -f "$HOME/.ssh/id_rsa.pub" ]
    virsh net-list --all | grep -q "$TEST_NETWORK"
    
    # Crear disco de prueba
    qemu-img create -f qcow2 -b "$DEBIAN_BASE" -F qcow2 "$TEST_DISK" 20G
    
    # Crear VM con todas las opciones
    run bash "$SCRIPT" --enable-root --user-pass "test123" \
        "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" \
        "192.168.1.100" 4096 4
    
    assert_success
    
    # Verificar que la VM existe
    virsh list --all | grep -q "$TEST_VM_NAME"
    
    # Verificar archivos cloud-init
    [ -f "./cloudinit-${TEST_VM_NAME}/cip-user.yaml" ]
    [ -f "./cloudinit-${TEST_VM_NAME}/cip-meta.yaml" ]
    [ -f "./cloudinit-${TEST_VM_NAME}/cip-net.yaml" ]
}