# Preparación común de los tests locales: un HOME de mentira con su silo,
# un virsh y un virt-install simulados, y una red virtual del usuario.
#
# Los tests ejecutan el script distribuible (ci-provision.sh), que es lo que
# usa el alumnado, no los fuentes de src/ y lib/.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/ci-provision.sh"
USUARIO="$(id -un)"

preparar_entorno() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export MOCK_STATE="$BATS_TEST_TMPDIR/mock"
    export PATH="$REPO_DIR/test/mocks:$PATH"
    SILO="$HOME/imagenesMV"

    mkdir -p "$SILO" "$HOME/.ssh" "$MOCK_STATE"
    echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0falsa ${USUARIO}@test" > "$HOME/.ssh/id_rsa.pub"
    qemu-img create -f qcow2 "$SILO/debian12.qcow2" 3G >/dev/null

    # Esperas cortas para que los tests no tarden
    export WAIT_TIMEOUT=15
    export POLL_SECS=1
    export GRACE_SECS=1
    export SHUTDOWN_TIMEOUT=5

    # Red del usuario, conforme al manual
    definir_red "${USUARIO}-red" 192.168.7.1 255.255.255.0 192.168.7.128 192.168.7.254
    echo "192.168.7" > "$MOCK_STATE/dhcp_base"
}

# definir_red NOMBRE PASARELA MASCARA DHCP_INICIO DHCP_FIN [RESERVA_IP...]
definir_red() {
    local nombre="$1" gw="$2" mask="$3" ini="$4" fin="$5"
    shift 5
    {
        echo "<network>"
        echo "  <name>$nombre</name>"
        echo "  <forward mode='nat'/>"
        echo "  <bridge name='virbr9' stp='on' delay='0'/>"
        echo "  <domain name='$nombre'/>"
        echo "  <ip address='$gw' netmask='$mask'>"
        echo "    <dhcp>"
        echo "      <range start='$ini' end='$fin'/>"
        local r
        for r in "$@"; do
            echo "      <host mac='52:54:00:00:00:01' name='reservada' ip='$r'/>"
        done
        echo "    </dhcp>"
        echo "  </ip>"
        echo "</network>"
    } > "$MOCK_STATE/red-$nombre.xml"
    echo "$nombre" >> "$MOCK_STATE/redes.txt"
}

quitar_red() {
    rm -f "$MOCK_STATE/red-$1.xml"
    grep -vx "$1" "$MOCK_STATE/redes.txt" > "$MOCK_STATE/redes.tmp" || true
    mv "$MOCK_STATE/redes.tmp" "$MOCK_STATE/redes.txt"
}

# Número de veces que se ha invocado un comando del mock (por patrón)
llamadas() {
    grep -c -- "$1" "$MOCK_STATE/log" 2>/dev/null || true
}

dominio_existe() {
    [[ -d "$MOCK_STATE/dominios/$1" ]]
}
