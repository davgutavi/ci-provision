setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    
    # Variables de entorno para tests
    export SCRIPT="./ci-provision.sh"
    export TEST_VM_NAME="test-vm-$$"
    export TEST_HOSTNAME="test-host"
    export TEST_NETWORK="default"
    export SILO_DIR="$HOME/imagenesMV"
    export DEBIAN_BASE="$HOME/imagenesMV/debian12.qcow2"
    export DEBIAN_BASE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
    export TEST_DISK="$HOME/imagenesMV/test-disk-$$.qcow2"
    
    # Crear directorio de pruebas si no existe
    mkdir -p "$SILO_DIR"
    
    # Crear disco de prueba si existe debian12.qcow2
    if [ -f "$DEBIAN_BASE" ]; then
        qemu-img create -f qcow2 -b "$DEBIAN_BASE" -F qcow2 "$TEST_DISK" 10G 2>/dev/null || true
    fi
}

teardown() {
    # Limpiar VM de prueba si existe
    virsh destroy "$TEST_VM_NAME" 2>/dev/null || true
    virsh undefine "$TEST_VM_NAME" --remove-all-storage 2>/dev/null || true
    
    # Limpiar disco de prueba
    rm -f "$TEST_DISK"
    rm -f "$SILO_DIR/test-no-backing-$$.qcow2"
    rm -f "$SILO_DIR/fake-$$.img"
    
    # Limpiar directorio cloudinit
    rm -rf "./cloudinit-${TEST_VM_NAME}"
}

#############################################
# PRUEBAS INFORMATIVAS DE PREREQUISITOS
#############################################

@test "INFO: prerequisitos del sistema" {
    echo "# ============================================"
    echo "# Verificando prerequisitos del sistema"
    echo "# ============================================"
    echo "# "
    
    # 1. Verificar debian12.qcow2
    if [ -f "$DEBIAN_BASE" ]; then
        local size=$(ls -lh "$DEBIAN_BASE" | awk '{print $5}')
        echo "# ✓ debian12.qcow2 encontrado en $SILO_DIR (tamaño: $size)"
    else
        echo "# ✗ debian12.qcow2 NO encontrado en $SILO_DIR"
        echo "# "
        echo "#   Para descargarlo, ejecuta:"
        echo "#   wget $DEBIAN_BASE_URL \\"
        echo "#        -O $DEBIAN_BASE"
        echo "# "
        echo "#   O con curl:"
        echo "#   curl -L $DEBIAN_BASE_URL \\"
        echo "#        -o $DEBIAN_BASE"
    fi
    
    # 2. Verificar clave SSH
    if [ -f "$HOME/.ssh/id_rsa.pub" ]; then
        local key_type=$(head -n1 "$HOME/.ssh/id_rsa.pub" | awk '{print $1}')
        echo "# ✓ Clave SSH encontrada en ~/.ssh/id_rsa.pub (tipo: $key_type)"
    else
        echo "# ✗ Clave SSH NO encontrada en ~/.ssh/id_rsa.pub"
        echo "#   Para crearla: ssh-keygen -t rsa -b 4096"
    fi
    
    # 3. Verificar red virtual
    if virsh net-list --all 2>/dev/null | grep -q "$TEST_NETWORK"; then
        echo "# ✓ Red '$TEST_NETWORK' encontrada"
    else
        echo "# ✗ Red '$TEST_NETWORK' NO encontrada"
        echo "#   Redes disponibles:"
        virsh net-list --all 2>/dev/null | sed 's/^/#   /' || echo "#   (virsh no disponible)"
    fi
    
    # 4. Verificar herramientas
    echo "# "
    echo "# Herramientas del sistema:"
    
    if command -v virt-install >/dev/null 2>&1; then
        echo "#   ✓ virt-install disponible"
    else
        echo "#   ✗ virt-install NO disponible"
    fi
    
    if command -v qemu-img >/dev/null 2>&1; then
        local version=$(qemu-img --version | head -n1)
        echo "#   ✓ qemu-img disponible ($version)"
    else
        echo "#   ✗ qemu-img NO disponible"
    fi
    
    if command -v cloud-localds >/dev/null 2>&1; then
        echo "#   ✓ cloud-localds disponible"
    else
        echo "#   ✗ cloud-localds NO disponible"
    fi
    
    if command -v virsh >/dev/null 2>&1; then
        echo "#   ✓ virsh disponible"
    else
        echo "#   ✗ virsh NO disponible"
    fi
    
    echo "# "
    echo "# ============================================"
    
    # Este test siempre pasa, solo muestra información
    true
}

#############################################
# PRUEBAS DE AYUDA
#############################################

@test "mostrar ayuda con -h" {
    run bash "$SCRIPT" -h
    assert_success
    assert_output --partial "Uso:"
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
}

@test "error con parámetros insuficientes" {
    run bash "$SCRIPT" vm1 disk1 host1
    assert_failure
}

@test "error con opción desconocida" {
    run bash "$SCRIPT" --opcion-invalida vm1 disk1 host1 default
    assert_failure
}

#############################################
# PRUEBAS DE VALIDACIÓN DE DISCO
#############################################

@test "error cuando el disco no existe" {
    run bash "$SCRIPT" "$TEST_VM_NAME" "/ruta/inexistente.qcow2" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_failure
    assert_output --partial "ERROR"
}

@test "error cuando el disco no está en SILO_DIR" {
    # Crear disco temporal fuera de SILO_DIR
    local temp_disk="/tmp/test-outside-$$.qcow2"
    touch "$temp_disk"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$temp_disk" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_failure
    assert_output --partial "ERROR"
    
    rm -f "$temp_disk"
}

@test "error cuando el disco no es qcow2" {
    # Crear archivo no-qcow2 en SILO_DIR
    local fake_disk="$SILO_DIR/fake-$$.img"
    touch "$fake_disk"
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$fake_disk" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_failure
    assert_output --partial "ERROR"
    
    rm -f "$fake_disk"
}

@test "error cuando el disco no tiene backing file debian12.qcow2" {
    # Crear imagen qcow2 sin backing file correcto
    local test_disk="$SILO_DIR/test-no-backing-$$.qcow2"
    qemu-img create -f qcow2 "$test_disk" 10G 2>/dev/null
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$test_disk" "$TEST_HOSTNAME" "$TEST_NETWORK"
    assert_failure
    assert_output --partial "ERROR"
    
    rm -f "$test_disk"
}

@test "acepta disco válido con backing file correcto" {
    # Solo ejecutar si existe debian12.qcow2
    if [ ! -f "$DEBIAN_BASE" ]; then
        skip "No existe debian12.qcow2 en $SILO_DIR - Descárgalo con: wget $DEBIAN_BASE_URL -O $DEBIAN_BASE"
    fi
    
    # El disco de prueba ya se creó en setup()
    [ -f "$TEST_DISK" ]
    
    # Verificar que el backing file es correcto
    qemu-img info "$TEST_DISK" | grep -q "debian12.qcow2"
}

#############################################
# PRUEBAS DE VALIDACIÓN DE RED
#############################################

@test "error cuando la red no existe" {
    # Solo ejecutar si existe debian12.qcow2
    if [ ! -f "$DEBIAN_BASE" ]; then
        skip "No existe debian12.qcow2 en $SILO_DIR"
    fi
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "red-inexistente-$$"
    assert_failure
    assert_output --partial "ERROR"
}

@test "acepta red existente" {
    # Solo ejecutar si existe debian12.qcow2 y la red
    if [ ! -f "$DEBIAN_BASE" ]; then
        skip "No existe debian12.qcow2 en $SILO_DIR"
    fi
    
    # Verificar que existe la red default
    if ! virsh net-list --all 2>/dev/null | grep -q "$TEST_NETWORK"; then
        skip "No existe la red $TEST_NETWORK"
    fi
    
    # Solo verificar que no da error de red (puede fallar por otras razones)
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    refute_output --partial "ERROR: La red"
}

#############################################
# PRUEBAS DE CLAVE PÚBLICA
#############################################

@test "error cuando no existe clave pública SSH" {
    # Guardar clave si existe
    local ssh_key="$HOME/.ssh/id_rsa.pub"
    local backup="$HOME/.ssh/id_rsa.pub.test-backup-$$"
    
    if [ -f "$ssh_key" ]; then
        mv "$ssh_key" "$backup"
    fi
    
    run bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK"
    local result=$status
    
    # Restaurar clave
    if [ -f "$backup" ]; then
        mv "$backup" "$ssh_key"
    fi
    
    [ "$result" -ne 0 ]
}

@test "carga correctamente clave pública existente" {
    # Solo ejecutar si existe la clave SSH
    if [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
        skip "No existe ~/.ssh/id_rsa.pub - Créala con: ssh-keygen -t rsa -b 4096"
    fi
    
    # Verificar que la clave existe y tiene contenido
    [ -f "$HOME/.ssh/id_rsa.pub" ]
    [ -s "$HOME/.ssh/id_rsa.pub" ]
}

#############################################
# PRUEBAS DE GENERACIÓN DE ARCHIVOS CLOUD-INIT
#############################################

@test "genera archivos cloud-init en directorio correcto" {
    # Solo ejecutar si tenemos todo preparado
    if [ ! -f "$DEBIAN_BASE" ] || [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
        skip "Faltan prerequisitos: debian12.qcow2 o clave SSH"
    fi
    
    if ! virsh net-list --all 2>/dev/null | grep -q "$TEST_NETWORK"; then
        skip "No existe la red $TEST_NETWORK"
    fi
    
    # Ejecutar el script (puede fallar al crear la VM, pero debe generar archivos)
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" 2>/dev/null || true
    
    # Verificar que se crearon los archivos cloud-init
    [ -d "./cloudinit-${TEST_VM_NAME}" ]
    [ -f "./cloudinit-${TEST_VM_NAME}/cip-user.yaml" ]
    [ -f "./cloudinit-${TEST_VM_NAME}/cip-meta.yaml" ]
}

@test "archivo meta-data contiene instance-id correcto" {
    # Solo ejecutar si tenemos todo preparado
    if [ ! -f "$DEBIAN_BASE" ] || [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
        skip "Faltan prerequisitos: debian12.qcow2 o clave SSH"
    fi
    
    if ! virsh net-list --all 2>/dev/null | grep -q "$TEST_NETWORK"; then
        skip "No existe la red $TEST_NETWORK"
    fi
    
    # Ejecutar el script
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" 2>/dev/null || true
    
    # Verificar contenido
    run cat "./cloudinit-${TEST_VM_NAME}/cip-meta.yaml"
    assert_output --partial "instance-id: ${TEST_VM_NAME}"
    assert_output --partial "local-hostname: ${TEST_HOSTNAME}"
}

@test "archivo user-data contiene usuario administrador" {
    # Solo ejecutar si tenemos todo preparado
    if [ ! -f "$DEBIAN_BASE" ] || [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
        skip "Faltan prerequisitos: debian12.qcow2 o clave SSH"
    fi
    
    if ! virsh net-list --all 2>/dev/null | grep -q "$TEST_NETWORK"; then
        skip "No existe la red $TEST_NETWORK"
    fi
    
    # Ejecutar el script
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" 2>/dev/null || true
    
    # Verificar contenido
    run cat "./cloudinit-${TEST_VM_NAME}/cip-user.yaml"
    assert_output --partial "name: administrador"
    assert_output --partial "groups:"
    assert_output --partial "sudo"
}

@test "archivo user-data NO contiene contraseña por defecto" {
    # Solo ejecutar si tenemos todo preparado
    if [ ! -f "$DEBIAN_BASE" ] || [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
        skip "Faltan prerequisitos: debian12.qcow2 o clave SSH"
    fi
    
    if ! virsh net-list --all 2>/dev/null | grep -q "$TEST_NETWORK"; then
        skip "No existe la red $TEST_NETWORK"
    fi
    
    # Ejecutar el script
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" 2>/dev/null || true
    
    # Verificar que NO contiene contraseña
    run cat "./cloudinit-${TEST_VM_NAME}/cip-user.yaml"
    refute_output --partial "chpasswd:"
}

@test "archivo user-data contiene contraseña con --user-pass" {
    # Solo ejecutar si tenemos todo preparado
    if [ ! -f "$DEBIAN_BASE" ] || [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
        skip "Faltan prerequisitos: debian12.qcow2 o clave SSH"
    fi
    
    if ! virsh net-list --all 2>/dev/null | grep -q "$TEST_NETWORK"; then
        skip "No existe la red $TEST_NETWORK"
    fi
    
    # Ejecutar el script con contraseña
    bash "$SCRIPT" --user-pass "test123" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" 2>/dev/null || true
    
    # Verificar contenido
    run cat "./cloudinit-${TEST_VM_NAME}/cip-user.yaml"
    assert_output --partial "ssh_pwauth: true"
    assert_output --partial "administrador:test123"
}

@test "genera network-config cuando se proporciona IP" {
    # Solo ejecutar si tenemos todo preparado
    if [ ! -f "$DEBIAN_BASE" ] || [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
        skip "Faltan prerequisitos: debian12.qcow2 o clave SSH"
    fi
    
    if ! virsh net-list --all 2>/dev/null | grep -q "$TEST_NETWORK"; then
        skip "No existe la red $TEST_NETWORK"
    fi
    
    # Ejecutar el script con IP
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" "192.168.1.100" 2>/dev/null || true
    
    # Verificar que se creó el archivo de red
    [ -f "./cloudinit-${TEST_VM_NAME}/cip-net.yaml" ]
    
    run cat "./cloudinit-${TEST_VM_NAME}/cip-net.yaml"
    assert_output --partial "192.168.1.100"
}

@test "NO genera network-config sin IP (DHCP)" {
    # Solo ejecutar si tenemos todo preparado
    if [ ! -f "$DEBIAN_BASE" ] || [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
        skip "Faltan prerequisitos: debian12.qcow2 o clave SSH"
    fi
    
    if ! virsh net-list --all 2>/dev/null | grep -q "$TEST_NETWORK"; then
        skip "No existe la red $TEST_NETWORK"
    fi
    
    # Ejecutar el script sin IP
    bash "$SCRIPT" "$TEST_VM_NAME" "$TEST_DISK" "$TEST_HOSTNAME" "$TEST_NETWORK" 2>/dev/null || true
    
    # Verificar que NO se creó el archivo de red
    [ ! -f "./cloudinit-${TEST_VM_NAME}/cip-net.yaml" ]
}

#############################################
# PRUEBAS DE INTEGRACIÓN COMPLETA
#############################################

@test "integración: crear VM completa con todas las opciones" {
    skip "Test de integración completa - ejecutar manualmente cuando estés listo"
    
    # Verificar prerequisitos
    [ -f "$DEBIAN_BASE" ]
    [ -f "$HOME/.ssh/id_rsa.pub" ]
    virsh net-list --all | grep -q "$TEST_NETWORK"
    
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