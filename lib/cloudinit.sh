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

# Escalar YAML entre comillas simples (dentro, la comilla simple se duplica):
# así una contraseña con ':', '#' o espacios no rompe el user-data
yaml_comillas() {
    local q="'"
    printf "'%s'" "${1//$q/$q$q}"
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
#
# Solo se usan claves vigentes en el cloud-init de Ubuntu 24.04: con una
# obsoleta (p.ej. 'chpasswd: list:' o 'ssh-authorized-keys') termina en
# 'degraded done', que el script trata como error.
########################################
generar_cloudinit() {
    local vm="$1" host="$2" ip="$3" modo="$4"

    preparar_workdir "$vm"
    escribir_meta_data "$vm" "$host"
    {
        echo "#cloud-config"
        yaml_usuarios
        yaml_paquetes_y_ficheros "$modo" "$host"
        yaml_runcmd "$modo"
    } > "$USER_DATA"
    chmod 600 "$USER_DATA"
    escribir_network_config "$ip"
}

# Directorio de los ficheros. En --dry-run es otro, para no sobrescribir los
# de una máquina que ya exista.
preparar_workdir() {   # DOMINIO
    if $DRY_RUN; then
        WORKDIR="${SILO_DIR}/cloudinit-$1.dry-run"
    else
        WORKDIR="${SILO_DIR}/cloudinit-$1"
        # Si algo falla después, el rollback lo quita junto a los discos
        DIRS_CREADOS+=( "$WORKDIR" )
    fi

    # Estos ficheros contienen contraseñas en texto plano y el servidor de la
    # asignatura es multiusuario: solo su propietario debe poder leerlos, ni
    # siquiera un instante (por eso el umask, y no un chmod después).
    rm -rf "$WORKDIR"
    ( umask 077 && mkdir -p "$WORKDIR" )
    chmod 700 "$WORKDIR"

    USER_DATA="$WORKDIR/cip-user.yaml"
    META_DATA="$WORKDIR/cip-meta.yaml"
    NETWORK_DATA=""
}

# El instance-id importa: cloud-init vuelve a configurar una máquina cuando ve
# uno distinto del que tenía. Así se personalizan los nodos del clúster, que
# parten de un disco ya configurado. Lleva la fecha para que sea nuevo aunque
# el disco de partida ya hubiera sido una máquina con el mismo nombre.
escribir_meta_data() {   # DOMINIO HOSTNAME
    ( umask 077 && cat > "$META_DATA" <<EOF
instance-id: $1-$(date +%Y%m%d%H%M%S)
local-hostname: $2
EOF
    )
}

# Usuarios, contraseñas y acceso por SSH
yaml_usuarios() {
    echo "users:"
    echo "  - name: administrador"
    if [[ "$IMAGEN" == ubuntu-base ]]; then
        # En ubuntu-base 'administrador' ya existe, con la contraseña del
        # boletín 1, y sudo se la pide: se deja como está (lock_passwd: false
        # para que cloud-init no la bloquee) y solo se añade la clave
        echo "    lock_passwd: false"
    else
        echo "    groups: [sudo]"
        echo "    shell: /bin/bash"
        echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']"
    fi
    echo "    ssh_authorized_keys:"
    # Entre comillas: el comentario de la clave puede llevar ': ' o '#'
    echo "      - $(yaml_comillas "$PUBKEY")"

    # root tiene contraseña para poder entrar por consola (por SSH no
    # entra: el sshd de Debian y el de Ubuntu traen PermitRootLogin
    # prohibit-password). Hace falta, p.ej., en el modo de rescate del
    # epígrafe 2.3 del boletín 2. 'administrador' solo la tiene si se pide
    # --ssh-pass; si no, entra únicamente por SSH con su clave, igual que
    # en las máquinas que se crean a mano siguiendo el boletín.
    if [[ -n "$SSH_PASS" ]] || ! $NO_ROOT; then
        echo "chpasswd:"
        echo "  expire: false"
        echo "  users:"
        if [[ -n "$SSH_PASS" ]]; then
            echo "    - name: administrador"
            echo "      password: $(yaml_comillas "$SSH_PASS")"
            echo "      type: text"
        fi
        if ! $NO_ROOT; then
            echo "    - name: root"
            echo "      password: ${PASS_CONSOLA}"
            echo "      type: text"
        fi
    fi

    # SSH por contraseña solo si el alumno lo pide explícitamente. Se fija
    # también el 'false' para no depender del valor por defecto de la
    # imagen, salvo en ubuntu-base, que lo trae activado y se respeta.
    if [[ -n "$SSH_PASS" ]]; then
        echo "ssh_pwauth: true"
    elif [[ "$IMAGEN" != ubuntu-base ]]; then
        echo "ssh_pwauth: false"
    fi
}

# Paquetes y, en los nodos, /etc/hosts y discos xfs
yaml_paquetes_y_ficheros() {   # MODO HOSTNAME
    local modo="$1" host="$2" i
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

            # Resolución por nombre entre los nodos (epígrafe 2.4 c).
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
            # runcmd (ver yaml_runcmd) para que las líneas de /etc/fstab sean
            # las mismas que escribe crea-entorno.sh; el módulo 'mounts' de
            # cloud-init las escribiría a su manera.
            echo "fs_setup:"
            for i in "${!CLUSTER_MONTAJES[@]}"; do
                echo "  - device: /dev/${UNIDADES_CLUSTER[$i]}"
                echo "    filesystem: xfs"
                echo "    partition: none"
                echo "    overwrite: false"
            done
            ;;
    esac
}

yaml_runcmd() {   # MODO
    local modo="$1" i
    echo "runcmd:"
    if [[ "$modo" == "nodo" ]]; then
        echo "  - mkdir -p ${CLUSTER_MONTAJES[*]}"
        for i in "${!CLUSTER_MONTAJES[@]}"; do
            echo "  - echo '/dev/${UNIDADES_CLUSTER[$i]} ${CLUSTER_MONTAJES[$i]} xfs ${OPCIONES_FSTAB_CLUSTER} 0 0' >> /etc/fstab"
        done
        echo "  - mount -a"
    fi
    if [[ "$IMAGEN" == ubuntu-base ]] && $NO_ROOT; then
        # ubuntu-base trae root con contraseña: --no-root la bloquea
        echo "  - passwd -l root"
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
}

# network-config, solo si la IP es fija. La pasarela y el prefijo se toman de
# la configuración real de la red (ver load_network_info). Se usa la forma
# 'routes:' en lugar de la obsoleta 'gateway4:', como el capítulo 6 del manual.
escribir_network_config() {   # IP
    [[ -n "$1" ]] || return 0
    NETWORK_DATA="$WORKDIR/cip-net.yaml"
    ( umask 077 && cat > "$NETWORK_DATA" <<EOF
version: 2
ethernets:
  enp1s0:
    addresses:
      - $1/${NET_PREFIX}
    routes:
      - to: default
        via: ${NET_GATEWAY}
    nameservers:
      addresses:
        - 150.214.186.69
        - 150.214.130.15
EOF
    )
}
