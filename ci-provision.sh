#!/bin/bash
set -euo pipefail

########################################
# Datos de la red virtual (se rellenan en load_network_info)
########################################
NET_GATEWAY=""
NET_NETMASK=""
NET_PREFIX=""
NET_DOMAIN=""
NET_DHCP_STARTS=()
NET_DHCP_ENDS=()
NET_RESERVED=()

# IPs de los nodos del clúster (se calculan a partir de la red)
CLUSTER_IPS=()

########################################
# Utilidades: herramientas y aritmética de IPs
########################################

# Comprueba que están disponibles las herramientas que necesita el script
require_commands() {
    local faltan=()
    local c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            faltan+=("$c")
        fi
    done
    if (( ${#faltan[@]} > 0 )); then
        error 38 "No se encuentran estas herramientas necesarias: ${faltan[*]}
Avisa al administrador del servidor."
    fi
}

# Comprueba que una cadena es una IPv4 con octetos entre 0 y 255
valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS=.
    for o in $ip; do
        if (( 10#$o > 255 )); then
            return 1
        fi
    done
    return 0
}

# Convierte una IPv4 en su valor entero
ip_to_int() {
    local IFS=. o1 o2 o3 o4
    read -r o1 o2 o3 o4 <<< "$1"
    printf '%s' $(( (10#$o1 << 24) + (10#$o2 << 16) + (10#$o3 << 8) + 10#$o4 ))
}

# Convierte un entero en su IPv4
int_to_ip() {
    local n="$1"
    printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) \
                         $(( (n >> 8) & 255 ))  $(( n & 255 ))
}

# Convierte una máscara (255.255.255.0) en su prefijo (24)
mask_to_prefix() {
    local o bits=0
    local IFS=.
    for o in $1; do
        case "$o" in
            255) bits=$(( bits + 8 )) ;;
            254) bits=$(( bits + 7 )) ;;
            252) bits=$(( bits + 6 )) ;;
            248) bits=$(( bits + 5 )) ;;
            240) bits=$(( bits + 4 )) ;;
            224) bits=$(( bits + 3 )) ;;
            192) bits=$(( bits + 2 )) ;;
            128) bits=$(( bits + 1 )) ;;
            0)   ;;
            *)   return 1 ;;
        esac
    done
    printf '%s' "$bits"
}

# Extrae el valor de un atributo XML de una línea.
# libvirt emite siempre comillas simples, pero se aceptan también las dobles
# para no depender de ese detalle.
xml_attr() {
    local valor
    valor="$(sed -n "s/.*[[:space:]]$2='\([^']*\)'.*/\1/p" <<< "$1")"

    if [[ -z "$valor" ]]; then
        valor="$(sed -n "s/.*[[:space:]]$2=\"\([^\"]*\)\".*/\1/p" <<< "$1")"
    fi

    printf '%s' "$valor"
}

# Dirección de red y de difusión (enteros) de la red cargada
red_neti()   { local gwi maski; gwi="$(ip_to_int "$NET_GATEWAY")"; maski=$(( 0xFFFFFFFF ^ ((1 << (32 - NET_PREFIX)) - 1) )); printf '%s' $(( gwi & maski )); }
red_bcasti() { local neti maski; neti="$(red_neti)"; maski=$(( 0xFFFFFFFF ^ ((1 << (32 - NET_PREFIX)) - 1) )); printf '%s' $(( neti | (~maski & 0xFFFFFFFF) )); }

########################################
# Elección de la red virtual
#
# El manual pide llamarla USUARIO-red, pero en los servidores hay redes con
# otros sufijos (-net, -network, _red, sin sufijo) y usuarios con más de una.
# Se busca entre las que empiezan por el usuario; si hay dudas, se pide --red.
########################################
detectar_red() {
    if [[ -n "$RED_OPT" ]]; then
        if ! virsh net-info "$RED_OPT" >/dev/null 2>&1; then
            error 40 "La red '$RED_OPT' (--red) no existe.
Consulta las redes disponibles con: virsh net-list --all"
        fi
        NET_NAME="$RED_OPT"
    else
        local todas r usuario_min candidatas=() elegida=""
        usuario_min="${USUARIO,,}"
        todas="$(virsh net-list --all --name 2>/dev/null || true)"

        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            local r_min="${r,,}"
            if [[ "$r_min" == "$usuario_min" || "$r_min" == "${usuario_min}-"* || "$r_min" == "${usuario_min}_"* ]]; then
                candidatas+=( "$r" )
            fi
        done <<< "$todas"

        for r in ${candidatas[@]+"${candidatas[@]}"}; do
            if [[ "$r" == "${USUARIO}-red" ]]; then
                elegida="$r"
            fi
        done

        if [[ -z "$elegida" ]]; then
            if (( ${#candidatas[@]} == 1 )); then
                elegida="${candidatas[0]}"
            elif (( ${#candidatas[@]} == 0 )); then
                error 40 "No encuentro ninguna red virtual con tu nombre de usuario ('$USUARIO').
Crea tu red virtual según el apartado 5.2 del manual, con el nombre '${USUARIO}-red',
o indica cuál usar con: --red NOMBRE
Redes existentes: virsh net-list --all"
            else
                error 44 "Hay varias redes virtuales con tu nombre de usuario: ${candidatas[*]}
Indica cuál usar con: --red NOMBRE"
            fi
        fi

        NET_NAME="$elegida"
    fi

    # La red tiene que estar activa para que virt-install pueda conectar la máquina
    local activa
    activa="$(virsh net-info "$NET_NAME" 2>/dev/null | awk '/^Active:/ { print $2 }')"
    if [[ "$activa" != "yes" ]]; then
        error 45 "La red '$NET_NAME' existe pero está inactiva.
Actívala con:            virsh net-start $NET_NAME
Para que arranque sola:  virsh net-autostart $NET_NAME"
    fi
}

########################################
# Introspección de la red virtual
#
# En lugar de dar por supuesta la configuración recomendada en el manual
# (192.168.X.0/24, pasarela en .1 y DHCP en .128-.254), se leen los datos
# reales de la red con 'virsh net-dumpxml'. Así el script funciona igual
# con redes que sigan otra topología.
########################################
load_network_info() {
    local xml
    if ! xml="$(virsh net-dumpxml "$NET_NAME" 2>/dev/null)"; then
        error 40 "La red '$NET_NAME' no existe.
Consulta las redes disponibles con: virsh net-list --all"
    fi

    # Bloque <ip> de IPv4 (se descartan los de IPv6).
    # El 'head -n1' cierra la tubería en cuanto tiene su línea; sin el '|| true'
    # el SIGPIPE de los grep haría fallar la tubería por 'pipefail'.
    local ipline
    ipline="$( { printf '%s\n' "$xml" | grep -E '<ip[[:space:]]' | grep -v "family='ipv6'" | head -n1; } || true )"
    if [[ -z "$ipline" ]]; then
        error 43 "No se ha podido determinar la configuración IPv4 de la red '$NET_NAME'."
    fi

    NET_GATEWAY="$(xml_attr "$ipline" address)"
    NET_NETMASK="$(xml_attr "$ipline" netmask)"
    local pfx
    pfx="$(xml_attr "$ipline" prefix)"

    if [[ -n "$NET_NETMASK" ]]; then
        if ! NET_PREFIX="$(mask_to_prefix "$NET_NETMASK")"; then
            error 43 "La máscara '$NET_NETMASK' de la red '$NET_NAME' no es válida."
        fi
    elif [[ -n "$pfx" ]]; then
        NET_PREFIX="$pfx"
    else
        error 43 "La red '$NET_NAME' no declara ni máscara ni prefijo."
    fi

    if ! valid_ipv4 "$NET_GATEWAY"; then
        error 43 "La pasarela '$NET_GATEWAY' de la red '$NET_NAME' no es una IPv4 válida."
    fi

    # Nombre de dominio de la red (puede no existir)
    local domline
    domline="$( { printf '%s\n' "$xml" | grep -E '<domain[[:space:]]' | head -n1; } || true )"
    if [[ -n "$domline" ]]; then
        NET_DOMAIN="$(xml_attr "$domline" name)"
    fi

    # Rangos DHCP (puede haber varios)
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        NET_DHCP_STARTS+=( "$(xml_attr "$line" start)" )
        NET_DHCP_ENDS+=( "$(xml_attr "$line" end)" )
    done < <(printf '%s\n' "$xml" | grep -E '<range[[:space:]]' || true)

    # Reservas estáticas por MAC. Pueden estar fuera del rango DHCP,
    # así que hay que tenerlas en cuenta aparte.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        NET_RESERVED+=( "$(xml_attr "$line" ip)" )
    done < <(printf '%s\n' "$xml" | grep -E '<host[[:space:]].*[[:space:]]ip=' || true)
}

# Imprime hasta 3 bloques de IPs libres para asignación fija
free_ip_blocks() {
    local neti bcasti
    neti="$(red_neti)"
    bcasti="$(red_bcasti)"
    local -a ini fin
    local i orden cur s e mostrados

    ini=( "$(ip_to_int "$NET_GATEWAY")" )
    fin=( "$(ip_to_int "$NET_GATEWAY")" )

    for (( i = 0; i < ${#NET_DHCP_STARTS[@]}; i++ )); do
        ini+=( "$(ip_to_int "${NET_DHCP_STARTS[$i]}")" )
        fin+=( "$(ip_to_int "${NET_DHCP_ENDS[$i]}")" )
    done

    for (( i = 0; i < ${#NET_RESERVED[@]}; i++ )); do
        ini+=( "$(ip_to_int "${NET_RESERVED[$i]}")" )
        fin+=( "$(ip_to_int "${NET_RESERVED[$i]}")" )
    done

    orden="$(for (( i = 0; i < ${#ini[@]}; i++ )); do
                 echo "${ini[$i]} ${fin[$i]}"
             done | sort -n)"

    cur=$(( neti + 1 ))
    mostrados=0

    while read -r s e; do
        if (( mostrados >= 3 )); then
            return 0
        fi
        if (( s > cur )); then
            echo "  $(int_to_ip "$cur") - $(int_to_ip $(( s - 1 )))"
            mostrados=$(( mostrados + 1 ))
        fi
        if (( e >= cur )); then
            cur=$(( e + 1 ))
        fi
    done <<< "$orden"

    if (( mostrados < 3 && cur <= bcasti - 1 )); then
        echo "  $(int_to_ip "$cur") - $(int_to_ip $(( bcasti - 1 )))"
        mostrados=$(( mostrados + 1 ))
    fi

    if (( mostrados == 0 )); then
        echo "  (ninguna)"
    fi
}

# Valida una IP fija contra la configuración real de la red
validar_ip_fija() {
    local ip="$1"

    if ! valid_ipv4 "$ip"; then
        error 41 "La IP '$ip' no es una dirección IPv4 válida."
    fi

    local ipi gwi neti bcasti maski
    ipi="$(ip_to_int "$ip")"
    gwi="$(ip_to_int "$NET_GATEWAY")"
    maski=$(( 0xFFFFFFFF ^ ((1 << (32 - NET_PREFIX)) - 1) ))
    neti="$(red_neti)"
    bcasti="$(red_bcasti)"

    if (( (ipi & maski) != neti )); then
        error 41 "La IP '$ip' no pertenece a la red '$NET_NAME'.
Red      : $(int_to_ip "$neti")/${NET_PREFIX}
Pasarela : ${NET_GATEWAY}
IPs libres para asignación fija:
$(free_ip_blocks)"
    fi

    if (( ipi == neti || ipi == bcasti )); then
        error 41 "La IP '$ip' es la dirección de red o la de difusión de '$NET_NAME'. No se puede asignar a una máquina."
    fi

    if (( ipi == gwi )); then
        error 41 "La IP '$ip' es la pasarela de la red '$NET_NAME'. Elige otra."
    fi

    # Dentro de algún rango DHCP
    local i si ei
    for (( i = 0; i < ${#NET_DHCP_STARTS[@]}; i++ )); do
        si="$(ip_to_int "${NET_DHCP_STARTS[$i]}")"
        ei="$(ip_to_int "${NET_DHCP_ENDS[$i]}")"
        if (( ipi >= si && ipi <= ei )); then
            error 42 "La IP '$ip' está dentro del rango DHCP de la red '$NET_NAME' (${NET_DHCP_STARTS[$i]} - ${NET_DHCP_ENDS[$i]}).
Si se la asignas de forma fija, el servidor DHCP puede entregársela a otra máquina.
Pasarela : ${NET_GATEWAY}
IPs libres para asignación fija:
$(free_ip_blocks)

También puedes omitir el parámetro IP para que la máquina use DHCP."
        fi
    done

    # Coincide con una reserva estática
    for (( i = 0; i < ${#NET_RESERVED[@]}; i++ )); do
        if [[ "$ip" == "${NET_RESERVED[$i]}" ]]; then
            error 42 "La IP '$ip' ya está reservada por MAC en la red '$NET_NAME'.
IPs libres para asignación fija:
$(free_ip_blocks)"
        fi
    done
}

# Calcula las IPs de los nodos del clúster (.10, .11, ...) dentro de la red
calcular_ips_cluster() {
    local neti i
    neti="$(red_neti)"
    CLUSTER_IPS=()
    for (( i = 0; i < ${#CLUSTER_NODOS[@]}; i++ )); do
        CLUSTER_IPS+=( "$(int_to_ip $(( neti + CLUSTER_IP_INICIAL + i )))" )
    done
}

########################################
# Comprobación de la imagen base
########################################
comprobar_imagen_base() {
    if [[ ! -f "$BASE_IMG" ]]; then
        error 37 "No se encuentra la imagen base '$BASE_IMG'.
Descárgala en el silo con el nombre $(basename "$BASE_IMG") (apartado 5.3.1 del manual)."
    fi

    # Se usa la salida JSON: campos tipados, sin interpretar texto ni unidades
    local info fmt
    info="$(qemu-img info --output=json "$BASE_IMG" 2>/dev/null || true)"
    fmt="$(printf '%s' "$info" | jq -r '.format // empty' 2>/dev/null || true)"

    if [[ "$fmt" != "qcow2" ]]; then
        error 37 "La imagen base '$BASE_IMG' no es un qcow2 válido (formato: ${fmt:-desconocido}).
Probablemente la descarga falló. Bórrala y descárgala de nuevo (apartado 5.3.1 del manual)."
    fi
}

########################################
# Validaciones generales
########################################
validar_entorno() {

    # Herramientas necesarias
    require_commands qemu-img virsh virt-install jq base64

    # Conexión con libvirt
    if ! virsh list --name >/dev/null 2>&1; then
        error 38 "No se puede conectar con libvirt (virsh).
¿Estás en el servidor de la asignatura? Prueba: virsh list --all"
    fi

    # Silo existente
    if [[ ! -d "$SILO_DIR" ]]; then
        error 30 "No existe el silo en: $SILO_DIR
Créalo según el apartado 5.1 del manual."
    fi

    comprobar_imagen_base

    # Clave pública existente
    if [[ ! -f "$PUBKEY_PATH" ]]; then
        error 31 "No existe la clave pública en $PUBKEY_PATH. Genera una con: ssh-keygen"
    fi

    # Red: elegirla y leer sus datos reales
    detectar_red
    load_network_info

    # IPs fijas, contra la red real
    if $CLUSTER; then
        calcular_ips_cluster
        local ip
        for ip in "${CLUSTER_IPS[@]}"; do
            validar_ip_fija "$ip"
        done
    elif [[ -n "$IP" ]]; then
        validar_ip_fija "$IP"
    fi
}

########################################
# Conflictos con lo que ya existe, y --limpiar
#
# El script siempre crea dominios y discos nuevos. Si alguno de los que va a
# crear ya existe, se detiene y lo dice; con --limpiar los elimina antes, pero
# solo exactamente esos: nunca otro dominio ni otro fichero del silo.
########################################

# Los rellena quien llama: qué dominios y qué ficheros va a crear
OBJ_DOMINIOS=()
OBJ_FICHEROS=()

comprobar_conflictos() {
    local -a dominios=() ficheros=()
    local d f

    for d in ${OBJ_DOMINIOS[@]+"${OBJ_DOMINIOS[@]}"}; do
        if virsh dominfo "$d" >/dev/null 2>&1; then
            dominios+=( "$d" )
        fi
    done

    for f in ${OBJ_FICHEROS[@]+"${OBJ_FICHEROS[@]}"}; do
        if [[ -e "$f" ]]; then
            ficheros+=( "$f" )
        fi
    done

    if (( ${#dominios[@]} == 0 && ${#ficheros[@]} == 0 )); then
        return 0
    fi

    if ! $LIMPIAR; then
        local msg="Ya existen elementos que este script tendría que crear:"
        for d in ${dominios[@]+"${dominios[@]}"}; do msg+=$'\n'"  dominio  $d"; done
        for f in ${ficheros[@]+"${ficheros[@]}"}; do msg+=$'\n'"  disco    $f"; done
        msg+=$'\n\n'"El script siempre crea máquinas y discos nuevos. Tienes dos opciones:"
        msg+=$'\n'"  a) Eliminarlos tú:"
        for d in ${dominios[@]+"${dominios[@]}"}; do
            msg+=$'\n'"       virsh destroy $d; virsh undefine $d --snapshots-metadata"
        done
        for f in ${ficheros[@]+"${ficheros[@]}"}; do
            msg+=$'\n'"       rm $f"
        done
        msg+=$'\n'"  b) Repetir el comando añadiendo --limpiar, que elimina exactamente eso y nada más."
        error 21 "$msg"
    fi

    echo "--limpiar: se van a eliminar estos elementos (y solo estos):"
    for d in ${dominios[@]+"${dominios[@]}"}; do echo "  dominio  $d"; done
    for f in ${ficheros[@]+"${ficheros[@]}"}; do echo "  disco    $f"; done

    if $DRY_RUN; then
        echo "  (--dry-run: no se elimina nada)"
        echo
        return 0
    fi

    if [[ -t 0 && -t 1 ]]; then
        local s
        for s in 5 4 3 2 1; do
            printf '\r  Empezando en %ds (Ctrl-C para cancelar)…' "$s"
            sleep 1
        done
        printf '\r\033[K'
    fi

    for d in ${dominios[@]+"${dominios[@]}"}; do
        virsh destroy "$d" >/dev/null 2>&1 || true
        if ! virsh undefine "$d" --snapshots-metadata >/dev/null 2>&1; then
            error 21 "No se ha podido eliminar el dominio '$d'. Inténtalo a mano:
  virsh destroy $d; virsh undefine $d --snapshots-metadata"
        fi
        echo "  ✔ dominio $d eliminado"
    done

    for f in ${ficheros[@]+"${ficheros[@]}"}; do
        rm -f "$f"
        echo "  ✔ disco $f eliminado"
    done
    echo
}

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
        echo "       Apaga la máquina antes de tomar instantáneas y, si el revert falla," >&2
        echo "       consulta el apartado B.6 del manual." >&2
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
    local pass_admin="${SSH_PASS:-$PASS_CONSOLA}"
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

        # Contraseñas de consola (root solo entra por consola: sshd de Debian
        # trae PermitRootLogin prohibit-password)
        echo "chpasswd:"
        echo "  list: |"
        echo "    administrador:${pass_admin}"
        echo "    root:${PASS_CONSOLA}"
        echo "  expire: false"

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

                # Discos vdb, vdc y vdd formateados en xfs y montados por fstab.
                # Los discos deben estar conectados desde el primer arranque:
                # por eso se pasan a virt-install en vez de añadirlos después.
                echo "fs_setup:"
                for i in "${!CLUSTER_MONTAJES[@]}"; do
                    echo "  - device: /dev/${UNIDADES_CLUSTER[$i]}"
                    echo "    filesystem: xfs"
                    echo "    partition: none"
                    echo "    overwrite: false"
                done
                echo "mounts:"
                for i in "${!CLUSTER_MONTAJES[@]}"; do
                    echo "  - [/dev/${UNIDADES_CLUSTER[$i]}, ${CLUSTER_MONTAJES[$i]}, xfs, 'defaults,nofail', '0', '0']"
                done
                ;;
        esac

        echo "runcmd:"
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

########################################
# Creación de discos
#
# Todos los discos los crea el script; los registra en DISCOS_CREADOS antes
# de crearlos, para que se eliminen si la ejecución falla a medias.
########################################

# Copia COW de una imagen que está en el mismo directorio del silo.
# El respaldo se referencia con ruta relativa, como hace el manual, para que
# el silo se pueda mover sin romper la cadena.
#   crear_disco_cow RUTA IMAGEN_BASE TAMAÑO
crear_disco_cow() {
    local ruta="$1" base="$2" tam="$3"
    local dir
    dir="$(dirname "$ruta")"

    DISCOS_CREADOS+=( "$ruta" )
    (
        cd "$dir" && \
        qemu-img create -f qcow2 -b "$(basename "$base")" -F qcow2 "$(basename "$ruta")" "$tam" >/dev/null
    )
}

# Disco vacío (sin respaldo)
#   crear_disco_vacio RUTA TAMAÑO
crear_disco_vacio() {
    local ruta="$1" tam="$2"

    DISCOS_CREADOS+=( "$ruta" )
    qemu-img create -f qcow2 "$ruta" "$tam" >/dev/null
}

########################################
# Espera activa a que cloud-init termine
#
# Una espera de duración fija no sirve: las medidas en los tres servidores
# mostraron que cloud-init tarda entre 60 y 140 segundos según lo que instale
# y la carga del servidor. En su lugar se consulta al guest agent:
#
#   1. Que el agente responda con la IP de la máquina ya dice que ha
#      arrancado y, en una máquina recién creada, que apt ha terminado
#      (el agente se instala con cloud-init).
#   2. Además, a través del propio agente se ejecuta 'cloud-init status'
#      dentro de la máquina, que dice exactamente si ha terminado. Esto es
#      imprescindible en los nodos del clúster, donde el agente ya está
#      instalado de antes y responde mucho antes de que cloud-init acabe.
#
# Si el agente no permite ejecutar comandos, se recurre solo al punto 1 con
# un pequeño margen, y se avisa.
########################################

declare -A IPS_DETECTADAS=()   # dominio → IP que reporta el agente
declare -A ESTADO_CI=()        # dominio → done | error | asumido
declare -A IP_ESPERADA=()      # dominio → IP fija que debe tener (si la hay)
declare -A FALLOS_CONSULTA=()  # dominio → veces seguidas sin poder consultar cloud-init
declare -A ASUMIDO_DESDE=()    # dominio → instante en que se empezó a asumir que está lista

limpiar_linea() {
    if [[ -t 1 ]]; then
        printf '\r\033[K'
    fi
}

# Devuelve por stdout la primera IPv4 no local que reporte el guest agent.
# Cadena vacía si el agente no responde todavía.
obtener_ip_agente() {
    local vm="$1" salida
    # Nada de tuberías hacia un awk que hace 'exit': con 'pipefail' un SIGPIPE
    # aguas arriba abortaría el script.
    salida="$(virsh domifaddr "$vm" --source agent 2>/dev/null || true)"
    awk '$3 == "ipv4" && $4 !~ /^127\./ { split($4, a, "/"); print a[1]; exit }' <<< "$salida"
}

# Ejecuta 'cloud-init status' dentro de la máquina a través del guest agent y
# devuelve por stdout su estado (done, running, error, ...).
# Devuelve 1 si no se ha podido consultar.
cloudinit_status() {
    local vm="$1" r pid s exited datos i

    r="$(virsh qemu-agent-command "$vm" --timeout 5 \
          '{"execute":"guest-exec","arguments":{"path":"/usr/bin/cloud-init","arg":["status"],"capture-output":true}}' \
          2>/dev/null || true)"
    pid="$(jq -r '.return.pid // empty' <<< "$r" 2>/dev/null || true)"

    if [[ -z "$pid" ]]; then
        return 1
    fi

    for i in 1 2 3 4 5; do
        sleep 1
        s="$(virsh qemu-agent-command "$vm" --timeout 5 \
              "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}" \
              2>/dev/null || true)"
        exited="$(jq -r '.return.exited // empty' <<< "$s" 2>/dev/null || true)"
        if [[ "$exited" == "true" ]]; then
            datos="$( { jq -r '.return."out-data" // empty' <<< "$s" | base64 -d; } 2>/dev/null || true)"
            sed -n 's/^status: *//p' <<< "$datos"
            return 0
        fi
    done

    return 1
}

# ¿Está la máquina lista? Deja la IP en IPS_DETECTADAS y el estado en ESTADO_CI.
maquina_lista() {
    local vm="$1" ip estado n

    ip="$(obtener_ip_agente "$vm")"
    if [[ -z "$ip" ]]; then
        return 1
    fi

    # Si se pidió IP fija, se exige esa IP concreta
    if [[ -n "${IP_ESPERADA[$vm]:-}" && "$ip" != "${IP_ESPERADA[$vm]}" ]]; then
        return 1
    fi

    if estado="$(cloudinit_status "$vm")"; then
        FALLOS_CONSULTA[$vm]=0
        case "$estado" in
            done)
                IPS_DETECTADAS[$vm]="$ip"
                ESTADO_CI[$vm]="done"
                return 0
                ;;
            error)
                IPS_DETECTADAS[$vm]="$ip"
                ESTADO_CI[$vm]="error"
                return 0
                ;;
            *)
                # running, not run, disabled...
                return 1
                ;;
        esac
    fi

    # No se ha podido consultar cloud-init. Si pasa varias veces seguidas, se
    # da la máquina por lista en cuanto lleve GRACE_SECS respondiendo.
    n=$(( ${FALLOS_CONSULTA[$vm]:-0} + 1 ))
    FALLOS_CONSULTA[$vm]=$n

    if (( n >= 3 )); then
        if [[ -z "${ASUMIDO_DESDE[$vm]:-}" ]]; then
            ASUMIDO_DESDE[$vm]=$SECONDS
        elif (( SECONDS - ASUMIDO_DESDE[$vm] >= GRACE_SECS )); then
            IPS_DETECTADAS[$vm]="$ip"
            ESTADO_CI[$vm]="asumido"
            return 0
        fi
    fi

    return 1
}

# Espera hasta que todas las máquinas indicadas estén operativas o se agote
# WAIT_TIMEOUT. Devuelve 0 si todas terminaron, 1 si alguna no.
esperar_maquinas() {
    local -a pendientes=( "$@" ) restantes
    local inicio=$SECONDS transcurrido vm

    echo "Esperando a que cloud-init termine de configurar ${#pendientes[@]} máquina(s)."
    echo "Puede tardar entre uno y tres minutos, según lo que haya que instalar."

    while true; do
        restantes=()
        for vm in "${pendientes[@]}"; do
            if maquina_lista "$vm"; then
                transcurrido=$(( SECONDS - inicio ))
                limpiar_linea
                case "${ESTADO_CI[$vm]}" in
                    done)
                        echo "✔ $vm operativa tras ${transcurrido}s. IP: ${IPS_DETECTADAS[$vm]}"
                        ;;
                    error)
                        echo "⚠ $vm ha arrancado (IP ${IPS_DETECTADAS[$vm]}), pero cloud-init informa de errores tras ${transcurrido}s."
                        echo "  Entra en la máquina y revisa: sudo cloud-init status --long"
                        ;;
                    asumido)
                        echo "✔ $vm responde tras ${transcurrido}s. IP: ${IPS_DETECTADAS[$vm]}"
                        echo "  (no se ha podido consultar el estado de cloud-init; se da por terminado)"
                        ;;
                esac
            else
                restantes+=( "$vm" )
            fi
        done

        pendientes=( ${restantes[@]+"${restantes[@]}"} )
        if (( ${#pendientes[@]} == 0 )); then
            return 0
        fi

        transcurrido=$(( SECONDS - inicio ))
        if (( transcurrido >= WAIT_TIMEOUT )); then
            limpiar_linea
            echo "AVISO: no ha(n) terminado en ${WAIT_TIMEOUT}s: ${pendientes[*]}" >&2
            echo "       Puede que siga(n) instalando paquetes. Comprueba su estado con:" >&2
            for vm in "${pendientes[@]}"; do
                echo "         virsh domifaddr $vm --source agent" >&2
            done
            echo "       Si no responde, entra por consola: virsh console NOMBRE" >&2
            return 1
        fi

        if [[ -t 1 ]]; then
            printf '\r  … %ss  (esperando: %s)' "$transcurrido" "${pendientes[*]}"
        fi
        sleep "$POLL_SECS"
    done
}

# Apaga una máquina de forma limpia y espera a que esté parada.
# Devuelve 1 si no se ha apagado en SHUTDOWN_TIMEOUT.
apagar_maquina() {
    local vm="$1" inicio=$SECONDS estado

    virsh shutdown "$vm" >/dev/null 2>&1 || true

    while true; do
        estado="$(virsh domstate "$vm" 2>/dev/null || true)"
        if [[ "$estado" == "shut off" ]]; then
            return 0
        fi
        if (( SECONDS - inicio >= SHUTDOWN_TIMEOUT )); then
            return 1
        fi
        sleep 2
    done
}

########################################
# Infraestructura GlusterFS completa (apartado A.3.2 del manual)
#
# Dos fases, las mismas que describe el manual, pero todo con cloud-init:
#
#   Fase 1  Se crea una máquina base con glusterfs-server instalado, glusterd
#           habilitado y el machine-id vacío; se espera a que termine, se
#           apaga y se elimina su dominio conservando el disco.
#   Fase 2  Cada nodo es una copia COW de ese disco con sus discos extra
#           conectados desde el primer arranque. Un instance-id nuevo hace
#           que cloud-init lo personalice: IP fija, /etc/hosts, discos xfs
#           montados. Los nodos arrancan en paralelo y se espera a todos.
#
# Frente a crea-entorno.sh no hace falta virt-customize (el error 'supermin'
# del apartado B.5 desaparece), ni virt-format, ni xmllint; cada nodo tiene
# sus propias claves SSH de host, y las IPs se validan contra el DHCP real.
########################################

# Quita un dominio del registro de creados (cuando se elimina a propósito)
quitar_dominio_creado() {
    local quitar="$1" d
    local -a nuevos=()
    for d in ${DOMINIOS_CREADOS[@]+"${DOMINIOS_CREADOS[@]}"}; do
        if [[ "$d" != "$quitar" ]]; then
            nuevos+=( "$d" )
        fi
    done
    DOMINIOS_CREADOS=( ${nuevos[@]+"${nuevos[@]}"} )
}

# Discos extra de un nodo
discos_extra_nodo() {
    local host="$1" u
    for u in "${UNIDADES_CLUSTER[@]}"; do
        echo "${SILO_DIR}/${host}-${u}.qcow2"
    done
}

# Rellena OBJ_DOMINIOS y OBJ_FICHEROS con todo lo que crea el clúster
objetivos_cluster() {
    local host d
    OBJ_DOMINIOS=( "${USUARIO}-${CLUSTER_BASE}" )
    OBJ_FICHEROS=( "${SILO_DIR}/${CLUSTER_BASE}.qcow2" )
    for host in "${CLUSTER_NODOS[@]}"; do
        OBJ_DOMINIOS+=( "${USUARIO}-${host}" )
        OBJ_FICHEROS+=( "${SILO_DIR}/${host}.qcow2" )
        while IFS= read -r d; do
            OBJ_FICHEROS+=( "$d" )
        done < <(discos_extra_nodo "$host")
    done
}

mostrar_plan_cluster() {
    local base_vm="${USUARIO}-${CLUSTER_BASE}"
    local base_disco="${SILO_DIR}/${CLUSTER_BASE}.qcow2"
    local i host vm

    echo "→ MODO SIMULACIÓN (--dry-run): no se creará nada."
    echo
    echo "✔ Validaciones superadas."
    echo "    Usuario : $USUARIO"
    echo "    Red     : $NET_NAME (pasarela $NET_GATEWAY, prefijo /$NET_PREFIX)"
    echo "    Nodos   :"
    for i in "${!CLUSTER_NODOS[@]}"; do
        echo "      ${USUARIO}-${CLUSTER_NODOS[$i]}  →  ${CLUSTER_IPS[$i]}"
    done
    echo "    Recursos: ${RAM_MB} MB y ${VCPUS} vCPU por máquina"
    echo

    echo "Fase 1: base GlusterFS"
    echo "    Máquina $base_vm con disco $(basename "$base_disco") (COW de $(basename "$BASE_IMG"), $TAM_DISCO)."
    echo "    Instala glusterfs-server y xfsprogs, habilita glusterd, vacía el machine-id."
    echo "    Al terminar se apaga y se elimina el dominio; el disco se conserva como respaldo."
    generar_cloudinit "$base_vm" "$CLUSTER_BASE" "" gluster
    construir_comando "$base_vm" "$RAM_MB" "$VCPUS" "$base_disco"
    echo "    Ficheros cloud-init en $WORKDIR/"
    echo "    Comando:"
    imprimir_comando | sed 's/^/    /'
    echo

    echo "Fase 2: ${#CLUSTER_NODOS[@]} nodos, cada uno con ${#UNIDADES_CLUSTER[@]} discos extra de ${TAM_DISCO_EXTRA}"
    echo "    ${UNIDADES_CLUSTER[0]}, ${UNIDADES_CLUSTER[1]} y ${UNIDADES_CLUSTER[2]} en xfs, montados en ${CLUSTER_MONTAJES[*]}; el resto sin formatear."
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${USUARIO}-${host}"
        generar_cloudinit "$vm" "$host" "${CLUSTER_IPS[$i]}" nodo
        echo "    $vm: disco ${host}.qcow2 (COW de $(basename "$base_disco")), IP ${CLUSTER_IPS[$i]}, cloud-init en $WORKDIR/"
    done
    echo
    echo "    Comando del primer nodo (los demás son iguales, con su nombre, IP y discos):"
    local -a extras=()
    while IFS= read -r i; do extras+=( "$i" ); done < <(discos_extra_nodo "${CLUSTER_NODOS[0]}")
    generar_cloudinit "${USUARIO}-${CLUSTER_NODOS[0]}" "${CLUSTER_NODOS[0]}" "${CLUSTER_IPS[0]}" nodo
    construir_comando "${USUARIO}-${CLUSTER_NODOS[0]}" "$RAM_MB" "$VCPUS" "${SILO_DIR}/${CLUSTER_NODOS[0]}.qcow2" "${extras[@]}"
    imprimir_comando | sed 's/^/    /'
    echo
    echo "No se ha creado ni modificado ninguna máquina, disco ni red."
}

print_summary_cluster() {
    local i host vm ip
    echo "-------------------------------------------"
    echo "Infraestructura GlusterFS creada (apartado A.3.2 del manual)"
    echo
    echo "Red          : $NET_NAME"
    echo "Nodos        :"
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${USUARIO}-${host}"
        ip="${IPS_DETECTADAS[$vm]:-${CLUSTER_IPS[$i]}}"
        printf '  %-28s %-16s hostname %s\n' "$vm" "$ip" "$host"
    done
    echo "RAM / vCPUs  : ${RAM_MB} MB / ${VCPUS} por nodo"
    echo "Discos       : ${UNIDADES_CLUSTER[0]}..${UNIDADES_CLUSTER[-1]} (${#UNIDADES_CLUSTER[@]} × ${TAM_DISCO_EXTRA}) en cada nodo"
    echo "               ${UNIDADES_CLUSTER[0]}, ${UNIDADES_CLUSTER[1]} y ${UNIDADES_CLUSTER[2]} en xfs, montados en ${CLUSTER_MONTAJES[*]}"
    echo "GlusterFS    : glusterfs-server instalado y glusterd habilitado en todos"
    echo "/etc/hosts   : con los ${#CLUSTER_NODOS[@]} nombres, en todos"
    echo
    echo "Acceso (igual en todos los nodos):"
    echo "  ssh administrador@IP                  con tu clave pública"
    if [[ -n "$SSH_PASS" ]]; then
        echo "                                        (o con la contraseña: $SSH_PASS)"
    fi
    echo "  virsh console ${USUARIO}-server1"
    echo "      administrador o root, contraseña: $PASS_CONSOLA"
    echo "  virt-viewer --connect qemu+ssh://${USUARIO}@$(servidor_fqdn)/system ${USUARIO}-server1"
    echo
    echo "IMPORTANTE: no borres ${SILO_DIR}/${CLUSTER_BASE}.qcow2."
    echo "            Los discos de los ${#CLUSTER_NODOS[@]} nodos dependen de él."
    echo "-------------------------------------------"
}

ejecutar_cluster() {
    local base_vm="${USUARIO}-${CLUSTER_BASE}"
    local base_disco="${SILO_DIR}/${CLUSTER_BASE}.qcow2"
    local i host vm ip disco d
    local -a extras nodos_vm=()

    objetivos_cluster
    comprobar_conflictos

    if $DRY_RUN; then
        mostrar_plan_cluster
        return 0
    fi

    ########################################
    # Fase 1: base
    ########################################
    echo "═══ Fase 1 de 2: base GlusterFS ($base_vm) ═══"
    generar_cloudinit "$base_vm" "$CLUSTER_BASE" "" gluster
    construir_comando "$base_vm" "$RAM_MB" "$VCPUS" "$base_disco"

    echo "→ Creando el disco $(basename "$base_disco") (copia COW de $(basename "$BASE_IMG"), $TAM_DISCO)…"
    crear_disco_cow "$base_disco" "$BASE_IMG" "$TAM_DISCO"

    echo "→ Creando la máquina '$base_vm' con cloud-init…"
    crear_dominio "$base_vm"

    if ! esperar_maquinas "$base_vm"; then
        error 70 "La base '$base_vm' no ha terminado de configurarse en ${WAIT_TIMEOUT}s.
Sin ella no se pueden crear los nodos. Comprueba la carga del servidor y vuelve a intentarlo."
    fi

    if [[ "${ESTADO_CI[$base_vm]}" == "error" ]]; then
        error 71 "cloud-init ha terminado con errores en la base '$base_vm' (probablemente al
instalar glusterfs-server). Los nodos heredarían el problema, así que se detiene aquí.
Puedes verlo con: virsh console $base_vm  (root, contraseña ${PASS_CONSOLA}) y cloud-init status --long"
    fi

    echo "→ Apagando la base…"
    if ! apagar_maquina "$base_vm"; then
        error 70 "La base '$base_vm' no se ha apagado en ${SHUTDOWN_TIMEOUT}s."
    fi

    # El dominio de la base sobra; su disco se queda como respaldo de los nodos
    virsh undefine "$base_vm" --snapshots-metadata >/dev/null
    quitar_dominio_creado "$base_vm"
    echo "✔ Base lista: $(basename "$base_disco") (dominio eliminado; el disco se conserva)."
    echo

    ########################################
    # Fase 2: nodos
    ########################################
    echo "═══ Fase 2 de 2: ${#CLUSTER_NODOS[@]} nodos ═══"
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${USUARIO}-${host}"
        ip="${CLUSTER_IPS[$i]}"
        disco="${SILO_DIR}/${host}.qcow2"
        extras=()
        while IFS= read -r d; do extras+=( "$d" ); done < <(discos_extra_nodo "$host")

        generar_cloudinit "$vm" "$host" "$ip" nodo
        construir_comando "$vm" "$RAM_MB" "$VCPUS" "$disco" "${extras[@]}"

        echo "→ $vm ($ip): creando $(basename "$disco") y ${#extras[@]} discos extra…"
        crear_disco_cow "$disco" "$base_disco" "$TAM_DISCO"
        for d in "${extras[@]}"; do
            crear_disco_vacio "$d" "$TAM_DISCO_EXTRA"
        done

        echo "→ $vm: creando la máquina…"
        crear_dominio "$vm"
        IP_ESPERADA[$vm]="$ip"
        nodos_vm+=( "$vm" )
    done
    CREACION_COMPLETA=true
    echo "✔ Los ${#nodos_vm[@]} nodos están creados y arrancando."
    echo "-------------------------------------------"

    if $NO_WAIT; then
        echo "Omitiendo la espera (--no-wait activo)."
        echo "NOTA: los nodos siguen configurándose por dentro (discos xfs, /etc/hosts...)."
        echo "      No se expulsa el medio de cloud-init; apágalos antes de tomar instantáneas."
    else
        esperar_maquinas "${nodos_vm[@]}" || true
        for vm in "${nodos_vm[@]}"; do
            if [[ -n "${ESTADO_CI[$vm]:-}" ]]; then
                eject_cloudinit_media "$vm"
            fi
        done
    fi

    print_summary_cluster
    avisar_known_hosts "${CLUSTER_IPS[@]}"
}


# Salidas de las herramientas en formato neutro, independiente del idioma
# configurado en el servidor.
export LC_ALL=C

########################################
# Configuración general
########################################
SILO_DIR="$HOME/imagenesMV"
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"
BASE_IMG="$SILO_DIR/debian12.qcow2"

# Usuario del servidor: de él salen los nombres de los dominios y el de la red
USUARIO="$(id -un)"

# Contraseña de consola de 'administrador' y de 'root' (la misma que usa el
# manual de laboratorio). Por SSH se entra siempre con clave; solo con
# --ssh-pass se admite contraseña, y entonces la elige el alumno.
PASS_CONSOLA="s1st3mas"

# Discos
TAM_DISCO_DEFECTO="40G"
TAM_DISCO_EXTRA="40G"
UNIDADES_EXTRA=(vdb vdc vdd vde vdf vdg)          # --extra-disks (apartado A.3.1 del manual)
UNIDADES_CLUSTER=(vdb vdc vdd vde vdf vdg vdh)    # nodos del clúster (apartado A.3.2)

# Clúster GlusterFS (apartado A.3.2 del manual)
CLUSTER_BASE="glusterbase"
CLUSTER_NODOS=(server1 server2 server3 server4)
CLUSTER_IP_INICIAL=10                             # server1 = .10, server2 = .11, ...
CLUSTER_RAM_MB=1024                               # recursos por nodo: los mismos que
CLUSTER_VCPUS=1                                   # usa crea-entorno.sh
CLUSTER_MONTAJES=(/gluster1 /gluster2 /gluster3)  # vdb, vdc y vdd, formateados en xfs

# Recursos por defecto de una máquina suelta
RAM_MB_DEFECTO=2048
VCPUS_DEFECTO=2
RAM_MB_MINIMO=512

# Espera a que cloud-init termine (segundos). Se pueden ajustar desde el
# entorno; los tests lo usan para no esperar de verdad.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"          # máximo antes de rendirse
POLL_SECS="${POLL_SECS:-3}"                  # cada cuánto se consulta
GRACE_SECS="${GRACE_SECS:-5}"                # margen si no se puede consultar cloud-init
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-120}"  # apagado limpio de la base del clúster

########################################
# Opciones (valores por defecto)
########################################
EXTRA_DISKS=false
GLUSTERFS=false
CLUSTER=false
LIMPIAR=false
DRY_RUN=false
NO_WAIT=false

RED_OPT=""
DISCO_OPT=""
TAM_DISCO="$TAM_DISCO_DEFECTO"
RAM_OPT=""
VCPUS_OPT=""
SSH_PASS=""

MAQUINA=""
IP=""

# Derivados
VM_NAME=""
HOST_NAME=""
DISCO_MAIN=""
NET_NAME=""
RAM_MB=""
VCPUS=""

# Ficheros cloud-init de la máquina que se está generando
WORKDIR=""
USER_DATA=""
META_DATA=""
NETWORK_DATA=""

# Comando virt-install, como array para poder ejecutarlo y mostrarlo tal cual
VIRT_INSTALL_CMD=()

########################################
# Registro de lo creado, para poder deshacerlo si algo falla a medias
########################################
DOMINIOS_CREADOS=()
DISCOS_CREADOS=()
CREACION_COMPLETA=false   # true cuando ya solo queda esperar: a partir de ahí no se deshace nada
SALIDA_CONTROLADA=false   # true si se sale por un error propio (validaciones)
INTERRUMPIDO=false        # true si el usuario pulsa Ctrl-C

########################################
# Carga de librerías
########################################
# Ajusta las rutas si tu estructura es distinta

########################################
# Función de error con código
########################################
error() {
    local code="$1"
    shift
    SALIDA_CONTROLADA=true
    echo "ERROR [$code] $*" >&2
    exit "$code"
}

########################################
# Deshacer lo creado si la ejecución se interrumpe a medias
#
# Solo se eliminan los elementos creados por ESTA ejecución: los dominios y
# los discos que el propio script acaba de crear. Nada preexistente se toca.
########################################
revertir_cambios() {
    if (( ${#DOMINIOS_CREADOS[@]} == 0 && ${#DISCOS_CREADOS[@]} == 0 )); then
        return 0
    fi

    echo >&2
    echo "Deshaciendo lo que se había creado en esta ejecución:" >&2

    local dominio disco
    for dominio in ${DOMINIOS_CREADOS[@]+"${DOMINIOS_CREADOS[@]}"}; do
        virsh destroy  "$dominio" >/dev/null 2>&1 || true
        virsh undefine "$dominio" --snapshots-metadata >/dev/null 2>&1 || true
        echo "  - dominio '$dominio' eliminado" >&2
    done

    for disco in ${DISCOS_CREADOS[@]+"${DISCOS_CREADOS[@]}"}; do
        if rm -f "$disco"; then
            echo "  - disco '$disco' eliminado" >&2
        fi
    done

    echo "  (nada que existiera antes de ejecutar el script se ha tocado)" >&2
}

al_salir() {
    local code=$?

    if (( code == 0 )); then
        return 0
    fi

    if $INTERRUMPIDO; then
        echo >&2
        echo "Interrumpido por el usuario." >&2
    elif ! $SALIDA_CONTROLADA; then
        echo >&2
        echo "ERROR: el script ha terminado de forma inesperada (código $code)." >&2
        echo "       Si el problema persiste, avisa a tu profesor indicando el comando usado." >&2
    fi

    if $CREACION_COMPLETA; then
        echo "Las máquinas ya estaban creadas: no se deshace nada. Comprueba su estado con:" >&2
        echo "  virsh list --all" >&2
    else
        revertir_cambios
    fi
}

trap al_salir EXIT
trap 'INTERRUMPIDO=true; exit 130' INT TERM

########################################
# Función de ayuda
########################################
print_help() {
    cat <<EOF
Uso:
  $0 [opciones] MAQUINA [IP]
  $0 [opciones] --gluster-cluster

Crea una máquina virtual Debian 12 con cloud-init en tu silo ($SILO_DIR).
De MAQUINA salen el nombre del dominio (${USUARIO}-MAQUINA), el nombre de
host (MAQUINA) y el disco (MAQUINA.qcow2), que el script crea como copia COW
de debian12.qcow2. La red virtual se busca por tu nombre de usuario.

Parámetros:
  MAQUINA              Nombre corto de la máquina (server1, server2, glusterbase, ...)
  IP                   (Opcional) IP fija dentro de tu red virtual. Sin ella, DHCP.

Opciones:
  --extra-disks        Crea y conecta 6 discos extra de ${TAM_DISCO_EXTRA} (vdb..vdg)
  --glusterfs          Prepara la máquina como nodo GlusterFS (glusterfs-server
                       instalado, glusterd habilitado, machine-id reseteado)
  --gluster-cluster    Construye la infraestructura completa del apartado A.3.2
                       del manual: una base GlusterFS y ${#CLUSTER_NODOS[@]} nodos
                       (${CLUSTER_NODOS[*]}) con IP fija, /etc/hosts, ${#UNIDADES_CLUSTER[@]} discos
                       cada uno y ${CLUSTER_MONTAJES[*]} en xfs. No lleva MAQUINA.
  --limpiar            Si ya existen los dominios o discos que el script va a
                       crear, los elimina antes (solo esos; nada más)
  --red NOMBRE         Red virtual a usar (por defecto se busca ${USUARIO}-red)
  --disco NOMBRE       Nombre del disco principal (por defecto MAQUINA.qcow2)
  --tam TAMAÑO         Tamaño del disco principal (por defecto ${TAM_DISCO_DEFECTO})
  --ram MB             Memoria (por defecto ${RAM_MB_DEFECTO}; en el clúster, ${CLUSTER_RAM_MB} por nodo)
  --vcpus N            vCPUs (por defecto ${VCPUS_DEFECTO}; en el clúster, ${CLUSTER_VCPUS} por nodo)
  --ssh-pass CONTRASEÑA
                       Permite entrar por SSH con contraseña, además de con clave.
                       La contraseña la eliges tú (solo caracteres ASCII).
  --dry-run            Comprueba los datos y muestra lo que se haría, SIN crear nada
  --no-wait            No esperar a que cloud-init termine de configurar la máquina
  -h, --help           Muestra esta ayuda

En todas las máquinas:
  - Usuario 'administrador' con tu clave pública ($PUBKEY_PATH),
    sudo sin contraseña y contraseña de consola '${PASS_CONSOLA}'.
  - Usuario 'root' habilitado solo por consola, contraseña '${PASS_CONSOLA}'.
  - Consola gráfica activa (virt-viewer).
  - Por SSH se entra con clave; con contraseña solo si usas --ssh-pass.

Ejemplos:
  $0 server1                              # DHCP
  $0 --extra-disks server1 192.168.XXX.2  # SERVER1 del apartado A.3.1
  $0 --glusterfs glusterbase              # un nodo GlusterFS suelto
  $0 --gluster-cluster                    # infraestructura del apartado A.3.2
  $0 --dry-run --extra-disks server1 192.168.XXX.2   # solo comprobar
EOF
}

########################################
# Parseo de opciones
########################################
parse_args() {
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --extra-disks)     EXTRA_DISKS=true; shift ;;
            --glusterfs)       GLUSTERFS=true;   shift ;;
            --gluster-cluster) CLUSTER=true;     shift ;;
            --limpiar)         LIMPIAR=true;     shift ;;
            --dry-run)         DRY_RUN=true;     shift ;;
            --no-wait)         NO_WAIT=true;     shift ;;
            --red|--disco|--tam|--ram|--vcpus|--ssh-pass)
                if [[ $# -lt 2 ]]; then
                    error 11 "Falta el valor de la opción $1"
                fi
                case "$1" in
                    --red)      RED_OPT="$2"   ;;
                    --disco)    DISCO_OPT="$2" ;;
                    --tam)      TAM_DISCO="$2" ;;
                    --ram)      RAM_OPT="$2"   ;;
                    --vcpus)    VCPUS_OPT="$2" ;;
                    --ssh-pass) SSH_PASS="$2"  ;;
                esac
                shift 2
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            # Opciones de la versión anterior: se explica qué ha cambiado
            --enable-root)
                error 12 "La opción --enable-root ya no existe: root está siempre habilitado por consola (contraseña ${PASS_CONSOLA})."
                ;;
            --virt-viewer)
                error 12 "La opción --virt-viewer ya no existe: la consola gráfica está siempre activa."
                ;;
            --user-pass)
                error 12 "La opción --user-pass ha sido sustituida por --ssh-pass CONTRASEÑA.
Sin ella, 'administrador' ya tiene contraseña de consola (${PASS_CONSOLA}) y por SSH se entra con clave."
                ;;
            --)
                shift
                args+=("$@")
                break
                ;;
            -*)
                error 12 "Opción desconocida '$1'. Consulta la ayuda con -h."
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    ########################################
    # Parámetros posicionales
    ########################################
    if $CLUSTER; then
        if (( ${#args[@]} > 0 )); then
            error 10 "Con --gluster-cluster no se indica MAQUINA ni IP: los nombres (${CLUSTER_BASE}, ${CLUSTER_NODOS[*]}) y las IPs (.${CLUSTER_IP_INICIAL} en adelante) son fijos."
        fi
        if [[ -n "$DISCO_OPT" ]]; then
            error 10 "La opción --disco no se aplica a --gluster-cluster: los discos se llaman como los nodos."
        fi
    else
        if (( ${#args[@]} == 0 )); then
            error 10 "Falta el nombre de la máquina.
Uso: $0 [opciones] MAQUINA [IP]      (p.ej. $0 server1)
Consulta la ayuda con -h."
        fi
        if (( ${#args[@]} > 2 )); then
            error 10 "Sobran parámetros: '${args[*]}'.
Parece la sintaxis de la versión anterior. Ahora solo se indica el nombre corto
de la máquina y, opcionalmente, la IP; el disco y la red se deducen de tu usuario:
  $0 [opciones] MAQUINA [IP]      (p.ej. $0 --extra-disks server1 192.168.XXX.2)
Consulta la ayuda con -h."
        fi
        MAQUINA="${args[0]}"
        IP="${args[1]:-}"

        # De MAQUINA sale el hostname, así que solo se admiten caracteres válidos
        # en un nombre de host
        if ! [[ "$MAQUINA" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || (( ${#MAQUINA} > 63 )); then
            error 20 "El nombre de máquina '$MAQUINA' no es válido.
Solo letras, números y guiones, empezando por letra o número (p.ej. server1, gluster-base)."
        fi
    fi

    ########################################
    # Recursos: por defecto según el modo
    ########################################
    if $CLUSTER; then
        RAM_MB="${RAM_OPT:-$CLUSTER_RAM_MB}"
        VCPUS="${VCPUS_OPT:-$CLUSTER_VCPUS}"
    else
        RAM_MB="${RAM_OPT:-$RAM_MB_DEFECTO}"
        VCPUS="${VCPUS_OPT:-$VCPUS_DEFECTO}"
    fi

    if ! [[ "$RAM_MB" =~ ^[0-9]+$ ]] || (( RAM_MB < RAM_MB_MINIMO )); then
        error 13 "La memoria RAM '$RAM_MB' no es válida. Debe ser un número de MB igual o mayor que ${RAM_MB_MINIMO}."
    fi

    if ! [[ "$VCPUS" =~ ^[0-9]+$ ]] || (( VCPUS < 1 )); then
        error 13 "El número de vCPUs '$VCPUS' no es válido. Debe ser un número igual o mayor que 1."
    fi

    if ! [[ "$TAM_DISCO" =~ ^[0-9]+[MGT]$ ]]; then
        error 15 "El tamaño de disco '$TAM_DISCO' no es válido. Indícalo como 40G, 20G, 512M..."
    fi

    if [[ -n "$DISCO_OPT" ]] && ! [[ "$DISCO_OPT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        error 16 "El nombre de disco '$DISCO_OPT' no es válido. Indica solo el nombre del fichero (sin rutas), p.ej. server1.qcow2."
    fi

    # La contraseña se teclea en la consola de la máquina virtual, cuyo teclado
    # no tiene por qué corresponderse con el del alumno. El manual ya advierte
    # de no usar tildes ni caracteres del alfabeto español.
    if [[ -n "$SSH_PASS" ]] && grep -q '[^ -~]' <<< "$SSH_PASS"; then
        error 14 "La contraseña contiene caracteres no ASCII (tildes, ñ, etc.).
No podrías teclearla en la consola de la máquina virtual.
Usa solo letras sin tilde, números y signos básicos."
    fi

    ########################################
    # Derivados
    ########################################
    if ! $CLUSTER; then
        VM_NAME="${USUARIO}-${MAQUINA}"
        HOST_NAME="$MAQUINA"
        DISCO_MAIN="${SILO_DIR}/${DISCO_OPT:-${MAQUINA}.qcow2}"
    fi
}

########################################
# Aviso de known_hosts
#
# El DHCP reutiliza direcciones, así que es habitual que la IP de una máquina
# nueva ya figure en known_hosts con la clave de una máquina anterior. El
# resultado es el aviso alarmante del apartado B.2 del manual. Aquí solo se
# avisa y se da el comando: no se toca el known_hosts del usuario.
########################################
avisar_known_hosts() {
    local kh="$HOME/.ssh/known_hosts"
    local ip avisado=false

    if [[ ! -f "$kh" ]] || ! command -v ssh-keygen >/dev/null 2>&1; then
        return 0
    fi

    for ip in "$@"; do
        [[ -z "$ip" ]] && continue
        if ssh-keygen -F "$ip" -f "$kh" >/dev/null 2>&1; then
            if ! $avisado; then
                echo
                echo "AVISO: estas IPs ya figuran en tu known_hosts con la clave de otra máquina."
                echo "       Al conectar por SSH verás un aviso de seguridad. Para resolverlo:"
                avisado=true
            fi
            echo "         ssh-keygen -f \"$kh\" -R \"$ip\""
        fi
    done
}

########################################
# Construcción del comando virt-install
#   construir_comando NOMBRE RAM VCPUS DISCO_PRINCIPAL [DISCOS_EXTRA...]
# Usa los ficheros cloud-init generados justo antes (USER_DATA, META_DATA,
# NETWORK_DATA). Los discos se conectan en el orden dado: el primero es vda.
########################################
construir_comando() {
    local nombre="$1" ram="$2" vcpus="$3"
    shift 3
    local disco

    VIRT_INSTALL_CMD=(
        virt-install
        --quiet
        --name "$nombre"
        --ram "$ram"
        --vcpus "$vcpus"
        --import
    )

    for disco in "$@"; do
        VIRT_INSTALL_CMD+=( --disk "path=${disco},format=qcow2,bus=virtio" )
    done

    VIRT_INSTALL_CMD+=(
        --os-variant debian12
        --network "network=$NET_NAME"
        --cloud-init "user-data=$USER_DATA,meta-data=$META_DATA${NETWORK_DATA:+,network-config=$NETWORK_DATA}"
        --graphics spice
        --noautoconsole
    )
}

# Muestra el comando de forma legible, una opción por línea
imprimir_comando() {
    local i=1 n=${#VIRT_INSTALL_CMD[@]} arg siguiente

    printf '  virt-install \\\n'
    while (( i < n )); do
        arg="${VIRT_INSTALL_CMD[$i]}"
        siguiente="${VIRT_INSTALL_CMD[$(( i + 1 ))]:-}"

        if [[ "$arg" == --* && -n "$siguiente" && "$siguiente" != --* ]]; then
            printf '    %s %s' "$arg" "$siguiente"
            i=$(( i + 2 ))
        else
            printf '    %s' "$arg"
            i=$(( i + 1 ))
        fi

        if (( i < n )); then printf ' \\\n'; else printf '\n'; fi
    done
}

# Ejecuta virt-install y registra el dominio para poder deshacerlo
crear_dominio() {
    local nombre="$1"
    "${VIRT_INSTALL_CMD[@]}"
    DOMINIOS_CREADOS+=( "$nombre" )
}

servidor_fqdn() {
    local h
    h="$(hostname 2>/dev/null || echo SERVIDOR)"
    if [[ "$h" != *.* ]]; then
        h="${h}.lsi.us.es"
    fi
    printf '%s' "$h"
}

########################################
# Resumen final de una máquina suelta
########################################
print_summary() {
    local vm_ip="${IPS_DETECTADAS[$VM_NAME]:-}"
    local ip_mostrar

    if [[ -n "$IP" ]]; then
        ip_mostrar="$IP (fija)"
    elif [[ -n "$vm_ip" ]]; then
        ip_mostrar="$vm_ip (DHCP)"
    else
        ip_mostrar="(DHCP; consúltala con: virsh domifaddr $VM_NAME --source agent)"
    fi

    echo "-------------------------------------------"
    echo "Máquina      : $VM_NAME  (hostname: $HOST_NAME)"
    echo "Disco        : $DISCO_MAIN ($TAM_DISCO)"
    echo "Red          : $NET_NAME"
    echo "IP           : $ip_mostrar"
    echo "RAM / vCPUs  : ${RAM_MB} MB / ${VCPUS}"

    if $EXTRA_DISKS; then
        echo "Discos extra : ${UNIDADES_EXTRA[0]}..${UNIDADES_EXTRA[-1]} (${#UNIDADES_EXTRA[@]} × ${TAM_DISCO_EXTRA}), ver: virsh domblklist $VM_NAME"
    else
        echo "Discos extra : NO"
    fi

    if $GLUSTERFS; then
        echo "GlusterFS    : glusterfs-server instalado, glusterd habilitado, machine-id reseteado"
    else
        echo "GlusterFS    : NO"
    fi

    echo
    echo "Acceso:"
    echo "  ssh administrador@${IP:-${vm_ip:-IP}}        con tu clave pública"
    if [[ -n "$SSH_PASS" ]]; then
        echo "                                        (o con la contraseña: $SSH_PASS)"
    fi
    echo "  virsh console $VM_NAME"
    echo "      administrador o root, contraseña: $PASS_CONSOLA"
    echo "  virt-viewer --connect qemu+ssh://${USUARIO}@$(servidor_fqdn)/system $VM_NAME"
    echo "-------------------------------------------"
}

########################################
# Una máquina suelta
########################################
ejecutar_maquina() {
    local modo="normal"
    local -a extras=()
    local unidad disco

    if $GLUSTERFS; then
        modo="gluster"
    fi

    if $EXTRA_DISKS; then
        for unidad in "${UNIDADES_EXTRA[@]}"; do
            extras+=( "${SILO_DIR}/${MAQUINA}-${unidad}.qcow2" )
        done
    fi

    # Conflictos con lo que ya exista (y --limpiar, si se pidió)
    OBJ_DOMINIOS=( "$VM_NAME" )
    OBJ_FICHEROS=( "$DISCO_MAIN" ${extras[@]+"${extras[@]}"} )
    comprobar_conflictos

    generar_cloudinit "$VM_NAME" "$HOST_NAME" "$IP" "$modo"
    construir_comando "$VM_NAME" "$RAM_MB" "$VCPUS" "$DISCO_MAIN" ${extras[@]+"${extras[@]}"}

    ########################################
    # Modo simulación: nada de lo de abajo se ejecuta
    ########################################
    if $DRY_RUN; then
        echo "→ MODO SIMULACIÓN (--dry-run): no se creará ninguna máquina."
        echo
        echo "✔ Validaciones superadas."
        echo "    Usuario : $USUARIO"
        echo "    Red     : $NET_NAME (pasarela $NET_GATEWAY, prefijo /$NET_PREFIX)"
        if [[ -n "$IP" ]]; then
            echo "    IP      : $IP, disponible para asignación fija"
        else
            echo "    IP      : por DHCP"
        fi
        echo
        echo "✔ Ficheros cloud-init generados en $WORKDIR/"
        echo
        echo "Discos que se crearían en $SILO_DIR:"
        echo "    $(basename "$DISCO_MAIN")  (copia COW de $(basename "$BASE_IMG"), $TAM_DISCO)"
        for disco in ${extras[@]+"${extras[@]}"}; do
            echo "    $(basename "$disco")  ($TAM_DISCO_EXTRA)"
        done
        echo
        echo "Comando que se ejecutaría:"
        echo
        imprimir_comando
        echo
        echo "No se ha creado ni modificado ninguna máquina, disco ni red."
        return 0
    fi

    echo "→ Creando el disco $(basename "$DISCO_MAIN") (copia COW de $(basename "$BASE_IMG"), $TAM_DISCO)…"
    crear_disco_cow "$DISCO_MAIN" "$BASE_IMG" "$TAM_DISCO"

    for disco in ${extras[@]+"${extras[@]}"}; do
        echo "→ Creando el disco extra $(basename "$disco") ($TAM_DISCO_EXTRA)…"
        crear_disco_vacio "$disco" "$TAM_DISCO_EXTRA"
    done

    echo "→ Creando la máquina '$VM_NAME' con cloud-init…"
    crear_dominio "$VM_NAME"
    CREACION_COMPLETA=true
    echo "✔ Máquina creada y arrancada."
    echo "-------------------------------------------"

    if [[ -n "$IP" ]]; then
        IP_ESPERADA[$VM_NAME]="$IP"
    fi

    if $NO_WAIT; then
        echo "Omitiendo la espera (--no-wait activo)."
        echo "NOTA: la máquina sigue configurándose por dentro. No se expulsa el medio de"
        echo "      cloud-init; si vas a tomar instantáneas, apágala antes (apartado B.6 del manual)."
    else
        # Solo se expulsa el medio de cloud-init si consta que la máquina ya
        # terminó de configurarse: hacerlo antes podría interrumpir a cloud-init.
        if esperar_maquinas "$VM_NAME"; then
            eject_cloudinit_media "$VM_NAME"
        fi
    fi

    print_summary
    avisar_known_hosts "${IP:-${IPS_DETECTADAS[$VM_NAME]:-}}"
}

########################################
# MAIN
########################################
main() {
    parse_args "$@"
    validar_entorno

    if $CLUSTER; then
        ejecutar_cluster
    else
        ejecutar_maquina
    fi
}

main "$@"
