########################################
# Generación de ficheros cloud-init
########################################
generate_cloudinit_files() {
    local vm="$1"
    local host="$2"

    WORKDIR="./cloudinit-${vm}"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    # Estos ficheros contienen contraseñas en texto plano y el servidor de la
    # asignatura es multiusuario: solo su propietario debe poder leerlos.
    chmod 700 "$WORKDIR"

    USER_DATA="$WORKDIR/cip-user.yaml"
    META_DATA="$WORKDIR/cip-meta.yaml"

    ########################################
    # meta-data
    ########################################
    cat > "$META_DATA" <<EOF
instance-id: ${vm}
local-hostname: ${host}
EOF

    ########################################
    # Construcción de lista de contraseñas
    ########################################
    local chpass_list=""
    local ssh_pwauth=false

    if [[ -n "$USER_PASS" ]]; then
        chpass_list+="administrador:${USER_PASS}"$'\n'
        ssh_pwauth=true
    fi

    if $ENABLE_ROOT; then
        chpass_list+="root:s1st3mas"$'\n'
    fi

    ########################################
    # user-data
    ########################################
    {
        echo "#cloud-config"
        echo "users:"
        echo "  - name: administrador"
        echo "    groups: [sudo]"
        echo "    shell: /bin/bash"
        echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']"
        echo "    ssh-authorized-keys:"
        echo "      - $(cat "$PUBKEY_PATH")"

        if [[ -n "$chpass_list" ]]; then
            if $ssh_pwauth; then
                echo "ssh_pwauth: true"
            fi
            echo "chpasswd:"
            echo "  list: |"
            while IFS= read -r line; do
                [[ -n "$line" ]] && echo "    $line"
            done <<< "$chpass_list"
            echo "  expire: false"
        fi

        echo "package_update: true"
        echo "packages:"
        echo "  - qemu-guest-agent"
        if $GLUSTERFS; then
            echo "  - glusterfs-server"
        fi

        echo "runcmd:"
        echo "  - timedatectl set-timezone Europe/Madrid"
        echo "  - systemctl start qemu-guest-agent"

        if $GLUSTERFS; then
            # Solo habilitamos glusterd (no se arranca, solo enable)
            echo "  - systemctl enable glusterd"
            # Reset de machine-id para poder clonar sin conflictos
            echo "  - truncate -s 0 /etc/machine-id"
        fi
    } > "$USER_DATA"

    chmod 600 "$USER_DATA" "$META_DATA"

    ########################################
    # network-config (solo si IP estática)
    ########################################
    # La pasarela y el prefijo se toman de la configuración real de la red
    # (ver load_network_info), no de una suposición sobre la IP indicada.
    # Se usa la forma 'routes:' en lugar de la obsoleta 'gateway4:' para que
    # coincida con la plantilla que se enseña en el manual de laboratorio.
    if [[ -n "$IP" ]]; then
        NETWORK_DATA="$WORKDIR/cip-net.yaml"

        cat > "$NETWORK_DATA" <<EOF
version: 2
ethernets:
  enp1s0:
    addresses:
      - ${IP}/${NET_PREFIX}
    routes:
      - to: default
        via: ${NET_GATEWAY}
    nameservers:
      addresses:
        - 150.214.186.69
        - 150.214.130.15
EOF
        chmod 600 "$NETWORK_DATA"
    else
        NETWORK_DATA=""
    fi
}