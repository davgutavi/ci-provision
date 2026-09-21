########################################
# Expulsión del medio de cloud-init
#
# virt-install genera una ISO efímera en /var/lib/libvirt/boot/ con la
# configuración de cloud-init y la deja enganchada como CD-ROM. libvirt borra
# ese fichero más adelante, pero la referencia permanece en la definición de
# la máquina. Si se toma una instantánea mientras la referencia sigue ahí, al
# revertirla falla con "Cannot access storage file" (apartado B.6 del manual).
#
# Expulsando el medio en cuanto la máquina está configurada, las instantáneas
# que tome después el alumno ya no pueden heredar el problema.
########################################

# Devuelve la unidad que tiene enganchada la ISO de cloud-init, mirando tanto
# la definición activa como la persistente. Cadena vacía si no hay ninguna.
cloudinit_unidad() {
    local vm="$1" salida
    # Se recoge primero la salida y luego se filtra con un here-string. Si se
    # encadenara con una tubería, el 'exit' de awk cerraría el conducto antes
    # de que terminase el segundo virsh, que moriría con SIGPIPE y, por
    # 'pipefail', abortaría el script entero.
    salida="$(
        virsh domblklist "$vm" 2>/dev/null || true
        virsh domblklist "$vm" --inactive 2>/dev/null || true
    )"
    awk '$2 ~ /cloudinit\.iso$/ { print $1; exit }' <<< "$salida"
}

eject_cloudinit_media() {
    local vm="$1"
    local unidad

    unidad="$(cloudinit_unidad "$vm")"

    if [[ -z "$unidad" ]]; then
        return 0
    fi

    # Se intenta por separado sobre cada definición. Según el momento, libvirt
    # ya puede haber limpiado una de las dos por su cuenta, y entonces esa
    # llamada falla ('The disk device doesn't have media') aunque la otra sea
    # necesaria y perfectamente posible. Hacerlo en una sola llamada con
    # --live --config aborta las dos.
    virsh change-media "$vm" "$unidad" --eject --live   >/dev/null 2>&1 || true
    virsh change-media "$vm" "$unidad" --eject --config >/dev/null 2>&1 || true

    # Lo que decide es el estado final, no el código de salida de los intentos.
    if [[ -z "$(cloudinit_unidad "$vm")" ]]; then
        echo "✔ Medio de cloud-init expulsado de $vm: ya puedes tomar instantáneas."
    else
        echo "AVISO: no se ha podido expulsar el medio de cloud-init de $vm (unidad ${unidad})." >&2
        echo "       Apaga la máquina antes de tomar instantáneas." >&2
    fi
}

########################################
# Generación de ficheros cloud-init
#
#   generar_cloudinit DOMINIO HOSTNAME IP MODO
#
#   MODO:
#     normal   máquina corriente
#     gluster  nodo GlusterFS suelto, o base del clúster: instala
#              glusterfs-server y xfsprogs, habilita glusterd y resetea el
#              machine-id para que las copias sean máquinas distintas
#     nodo     nodo del clúster, creado a partir de la base: ya tiene todo
#              instalado; solo se personaliza (IP, /etc/hosts, discos xfs)
#
# Deja las rutas en WORKDIR, USER_DATA, META_DATA y NETWORK_DATA (vacío si DHCP).
########################################
generar_cloudinit() {
    local vm="$1" host="$2" ip="$3" modo="$4"

    # En modo simulación se usa un directorio aparte, para no sobrescribir los
    # ficheros de una máquina que ya exista.
    if $DRY_RUN; then
        WORKDIR="${SILO_DIR}/cloudinit-${vm}.dry-run"
    else
        WORKDIR="${SILO_DIR}/cloudinit-${vm}"
    fi

    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    # Estos ficheros contienen contraseñas en texto plano y el servidor de la
    # asignatura es multiusuario: solo su propietario debe poder leerlos.
    chmod 700 "$WORKDIR"

    USER_DATA="$WORKDIR/cip-user.yaml"
    META_DATA="$WORKDIR/cip-meta.yaml"
    NETWORK_DATA=""

    ########################################
    # meta-data
    #
    # El instance-id importa: cloud-init vuelve a configurar una máquina
    # cuando ve uno distinto del que tenía. Así se personalizan los nodos del
    # clúster, que parten de un disco ya configurado.
    ########################################
    cat > "$META_DATA" <<EOF
instance-id: ${vm}
local-hostname: ${host}
EOF

    ########################################
    # user-data
    ########################################
    local i

    {
        echo "#cloud-config"
        echo "users:"
        echo "  - name: administrador"
        echo "    groups: [sudo]"
        echo "    shell: /bin/bash"
        echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']"
        echo "    ssh-authorized-keys:"
        echo "      - $(cat "$PUBKEY_PATH")"

        # root tiene contraseña para poder entrar por consola (por SSH no
        # entra: sshd de Debian trae PermitRootLogin prohibit-password).
        # 'administrador' solo la tiene si se pide --ssh-pass; si no, entra
        # únicamente por SSH con su clave, igual que en las máquinas que se
        # crean a mano siguiendo el manual.
        if [[ -n "$SSH_PASS" ]] || ! $NO_ROOT; then
            echo "chpasswd:"
            echo "  list: |"
            if [[ -n "$SSH_PASS" ]]; then
                echo "    administrador:${SSH_PASS}"
            fi
            if ! $NO_ROOT; then
                echo "    root:${PASS_CONSOLA}"
            fi
            echo "  expire: false"
        fi

        # SSH por contraseña solo si el alumno lo pide explícitamente. Se fija
        # también el 'false' para no depender del valor por defecto de la imagen.
        if [[ -n "$SSH_PASS" ]]; then
            echo "ssh_pwauth: true"
        else
            echo "ssh_pwauth: false"
        fi

        case "$modo" in
            normal|gluster)
                echo "package_update: true"
                echo "packages:"
                echo "  - qemu-guest-agent"
                if [[ "$modo" == "gluster" ]]; then
                    echo "  - glusterfs-server"
                    # Necesario para que los nodos del clúster puedan formatear
                    # sus discos en xfs en el primer arranque
                    echo "  - xfsprogs"
                fi
                ;;
            nodo)
                # La base ya tiene todo instalado: no hace falta tocar apt
                echo "package_update: false"

                # Resolución por nombre entre los nodos (apartado A.3.2).
                # Se fija manage_etc_hosts a false para que cloud-init no
                # regenere /etc/hosts en cada arranque y pise lo escrito aquí.
                echo "manage_etc_hosts: false"
                echo "write_files:"
                echo "  - path: /etc/hosts"
                echo "    content: |"
                echo "      127.0.0.1 localhost"
                echo "      127.0.1.1 ${host}"
                for i in "${!CLUSTER_NODOS[@]}"; do
                    echo "      ${CLUSTER_IPS[$i]} ${CLUSTER_NODOS[$i]}"
                done
                echo "      ::1 localhost ip6-localhost ip6-loopback"
                echo "      ff02::1 ip6-allnodes"
                echo "      ff02::2 ip6-allrouters"

                # Discos vdb, vdc y vdd formateados en xfs. Deben estar
                # conectados desde el primer arranque: por eso se pasan a
                # virt-install en vez de añadirlos después. El montaje va en
                # runcmd (más abajo) para que las líneas de /etc/fstab sean
                # exactamente las que muestran los ejercicios del manual; el
                # módulo 'mounts' de cloud-init las escribiría a su manera.
                echo "fs_setup:"
                for i in "${!CLUSTER_MONTAJES[@]}"; do
                    echo "  - device: /dev/${UNIDADES_CLUSTER[$i]}"
                    echo "    filesystem: xfs"
                    echo "    partition: none"
                    echo "    overwrite: false"
                done
                ;;
        esac

        echo "runcmd:"
        if [[ "$modo" == "nodo" ]]; then
            echo "  - mkdir -p ${CLUSTER_MONTAJES[*]}"
            for i in "${!CLUSTER_MONTAJES[@]}"; do
                echo "  - echo '/dev/${UNIDADES_CLUSTER[$i]} ${CLUSTER_MONTAJES[$i]} xfs ${OPCIONES_FSTAB_CLUSTER} 0 0' >> /etc/fstab"
            done
            echo "  - mount -a"
        fi
        echo "  - timedatectl set-timezone Europe/Madrid"
        if [[ "$modo" == "gluster" ]]; then
            # Solo se habilita glusterd, no se arranca: así no genera su UUID en
            # la base, y cada copia tendrá el suyo cuando arranque
            echo "  - systemctl enable glusterd"
        fi
        echo "  - systemctl start qemu-guest-agent"
        if [[ "$modo" == "gluster" ]]; then
            # machine-id vacío: cada copia de este disco generará el suyo
            echo "  - truncate -s 0 /etc/machine-id"
        fi
    } > "$USER_DATA"

    chmod 600 "$USER_DATA" "$META_DATA"

    ########################################
    # network-config (solo si IP estática)
    #
    # La pasarela y el prefijo se toman de la configuración real de la red
    # (ver load_network_info). Se usa la forma 'routes:' en lugar de la
    # obsoleta 'gateway4:' para que coincida con la plantilla del manual.
    ########################################
    if [[ -n "$ip" ]]; then
        NETWORK_DATA="$WORKDIR/cip-net.yaml"

        cat > "$NETWORK_DATA" <<EOF
version: 2
ethernets:
  enp1s0:
    addresses:
      - ${ip}/${NET_PREFIX}
    routes:
      - to: default
        via: ${NET_GATEWAY}
    nameservers:
      addresses:
        - 150.214.186.69
        - 150.214.130.15
EOF
        chmod 600 "$NETWORK_DATA"
    fi
}
