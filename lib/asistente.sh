########################################
# Asistente (--menu): menús de whiptail que construyen la línea de comandos y
# la ejecutan. Toda la lógica sigue en el mismo sitio: el asistente solo elige
# los argumentos, enseña el comando equivalente y lo lanza en otro proceso.
########################################

# Ejecuta whiptail y devuelve su selección por stdout (whiptail la escribe por
# stderr). Estado: 0 aceptar, 1 cancelar, 255 Esc. Va con locale UTF-8: con
# LC_ALL=C (la del resto del script) whiptail corta los textos en las tildes.
wt() {
    local out rc=0
    out="$(LC_ALL="$LOCALE_UTF8" whiptail --title "ci-provision $VERSION" "$@" 3>&1 1>&2 2>&3)" || rc=$?
    printf '%s' "$out"
    return "$rc"
}

# Convierte la salida de un --checklist ("a" "b") en etiquetas sueltas
etiquetas() {
    tr -d '"' <<< "$1"
}

# IPs libres de la red del usuario, para mostrarlas. Va en una subshell: si la
# red no se encuentra, el asistente sigue (ya lo dirá el script al ejecutar).
ips_libres_texto() {
    ( detectar_red >/dev/null 2>&1 && load_network_info >/dev/null 2>&1 && free_ip_blocks ) 2>/dev/null || true
}

# La IP número N de la red del usuario (la .2 de SERVER1), o nada
ip_de_la_red() {   # N
    ( detectar_red >/dev/null 2>&1 && load_network_info >/dev/null 2>&1 && int_to_ip $(( $(red_neti) + $1 )) ) 2>/dev/null || true
}

salir_asistente() {
    echo "Sin cambios."
    SALIDA_CONTROLADA=true
    exit 0
}

asistente() {
    local sel
    while true; do
        sel="$(wt --menu $'¿Qué quieres hacer?\n(muévete con las flechas y elige con Enter)' 20 76 8 \
            basica   "Crear una máquina" \
            server1  "Crear SERVER1 del boletín 2 (IP .2 y seis discos extra)" \
            cluster  "Crear la infraestructura GlusterFS del boletín 2" \
            base     "Crear solo la imagen base GlusterFS" \
            listar   "Ver lo que tengo" \
            eliminar "Eliminar máquinas" \
            todo     "Eliminar todas mis máquinas" \
            salir    "Salir")" || salir_asistente
        case "$sel" in
            basica)   asistente_maquina "" ;;
            server1)  asistente_maquina server1 ;;
            cluster)  asistente_cluster ;;
            base)     asistente_base ;;
            listar)   ejecutar_asistente --directo --listar ;;
            eliminar) asistente_eliminar ;;
            todo)     ejecutar_asistente --eliminar-todo ;;
            *)        salir_asistente ;;
        esac
    done
}

# Opciones marcadas en un checklist → argumentos (la contraseña se pide aparte).
# Deja el resultado en OPCIONES_ARGS; devuelve 1 si se cancela.
OPCIONES_ARGS=()
opciones_a_argumentos() {   # SALIDA_DEL_CHECKLIST
    local o pass
    OPCIONES_ARGS=()
    for o in $(etiquetas "$1"); do
        if [[ "$o" == ssh-pass ]]; then
            pass="$(wt --passwordbox $'Contraseña para administrador\n(solo letras sin tilde, números y signos básicos):' 10 70)" || return 1
            if [[ -z "$pass" ]]; then return 1; fi
            OPCIONES_ARGS+=( --ssh-pass "$pass" )
        else
            OPCIONES_ARGS+=( "--$o" )
        fi
    done
    return 0
}

asistente_maquina() {   # "" (nombre a elegir) o server1
    local preset="$1" nombre ip sugerida libres texto marcado sel
    local -a args=()

    if [[ -n "$preset" ]]; then
        nombre="$preset"
    else
        nombre="$(wt --inputbox $'Nombre corto de la máquina (letras, números y guiones).\nEl dominio será '"${PREFIJO_DOMINIO}"$'-NOMBRE y el disco NOMBRE.qcow2.' 11 70 server1)" || return 0
        if [[ -z "$nombre" ]]; then return 0; fi
    fi

    sugerida=""
    if [[ -n "$preset" ]]; then
        sugerida="$(ip_de_la_red 2)"
    fi
    libres="$(ips_libres_texto)"
    texto="IP fija dentro de tu red virtual. Déjala vacía para usar DHCP."
    if [[ -n "$libres" ]]; then
        texto+=$'\nIPs libres de tu red:\n'"$libres"
    fi
    ip="$(wt --inputbox "$texto" 16 70 "$sugerida")" || return 0

    marcado=off
    if [[ -n "$preset" ]]; then marcado=on; fi
    sel="$(wt --checklist $'Opciones (marca con la barra espaciadora):' 16 76 5 \
        extra-disks    "Seis discos extra vdb..vdg de ${TAM_DISCO_EXTRA}" "$marcado" \
        ssh-pass       "Contraseña para administrador y SSH por contraseña" off \
        no-root        "No habilitar al usuario root" off \
        no-virt-viewer "Sin consola gráfica (virt-viewer)" off \
        limpiar        "Eliminar antes lo que ya exista con esos nombres" off)" || return 0
    opciones_a_argumentos "$sel" || return 0

    args=( ${OPCIONES_ARGS[@]+"${OPCIONES_ARGS[@]}"} "$nombre" )
    if [[ -n "$ip" ]]; then args+=( "$ip" ); fi
    ejecutar_asistente "${args[@]}"
}

asistente_cluster() {
    local base sel
    local -a args=( --gluster-cluster )

    base="${SILO_DIR}/${PREFIJO_FICHERO}${CLUSTER_BASE}.qcow2"
    if [[ -f "$base" ]]; then
        if wt --yesno "Ya tienes $(basename "$base") en el silo."$'\n¿Quieres usarla como imagen base, sin volver a construirla?' 10 70; then
            args+=( --base "$(basename "$base")" )
        fi
    fi

    sel="$(wt --checklist $'Opciones (marca con la barra espaciadora):' 14 76 4 \
        limpiar        "Eliminar antes ${CLUSTER_NODOS[*]} si ya existen" off \
        ssh-pass       "Contraseña para administrador y SSH por contraseña" off \
        no-root        "No habilitar al usuario root" off \
        no-virt-viewer "Sin consola gráfica (virt-viewer)" off)" || return 0
    opciones_a_argumentos "$sel" || return 0

    args+=( ${OPCIONES_ARGS[@]+"${OPCIONES_ARGS[@]}"} )
    ejecutar_asistente "${args[@]}"
}

asistente_base() {
    local nombre
    local -a args=( --glusterfs )

    nombre="$(wt --inputbox $'Nombre de la imagen base.\nQuedará NOMBRE.qcow2 en el silo, sin máquina, lista para hacer copias.' 11 70 "$CLUSTER_BASE")" || return 0
    if [[ -z "$nombre" ]]; then return 0; fi
    if wt --defaultno --yesno $'Si ya existe una máquina o un disco con ese nombre,\n¿eliminarlos antes (--limpiar)?' 9 70; then
        args+=( --limpiar )
    fi
    args+=( "$nombre" )
    ejecutar_asistente "${args[@]}"
}

asistente_eliminar() {
    local d sel o
    local -a items=() args=( --eliminar )

    while IFS= read -r d; do
        if [[ -n "$d" ]]; then
            items+=( "${d#"${PREFIJO_DOMINIO}-"}" "$(estado_dominio "$d")" off )
        fi
    done < <(dominios_propios)

    if (( ${#items[@]} == 0 )); then
        wt --msgbox "No tienes máquinas (dominios ${PREFIJO_DOMINIO}-*)."$'\nLos discos sueltos del silo se ven en "Ver lo que tengo" y se eliminan\ncon "Eliminar todas mis máquinas".' 11 72 || true
        return 0
    fi

    sel="$(wt --checklist $'Marca las máquinas a eliminar (con sus discos y sus ficheros cloud-init):' 18 72 8 "${items[@]}")" || return 0
    for o in $(etiquetas "$sel"); do
        args+=( "$o" )
    done
    if (( ${#args[@]} == 1 )); then return 0; fi
    ejecutar_asistente "${args[@]}"
}

# Enseña el comando equivalente, pide confirmación y lo ejecuta en un proceso
# aparte (este mismo script con esos argumentos). Con --directo no pregunta.
ejecutar_asistente() {   # [--directo] ARGUMENTO...
    local directo=false mostrar a prev="" rc=0 pausa
    if [[ "${1:-}" == "--directo" ]]; then
        directo=true
        shift
    fi
    if [[ -n "$PREFIJO_OPT" ]]; then
        set -- --prefijo "$PREFIJO_OPT" "$@"
    fi

    mostrar="$0"
    for a in "$@"; do
        if [[ "$prev" == "--ssh-pass" ]]; then
            mostrar+=" ••••••"
        else
            mostrar+=" $a"
        fi
        prev="$a"
    done

    if ! $directo; then
        if ! wt --yesno $'Se va a ejecutar:\n\n  '"$mostrar"$'\n\n¿Adelante?' 12 76; then
            return 0
        fi
    fi

    clear 2>/dev/null || true
    echo "→ $mostrar"
    echo
    # Ctrl+C lo atiende el proceso hijo, que deshace lo suyo; aquí se ignora
    trap '' INT
    bash "$0" "$@" || rc=$?
    trap 'INTERRUMPIDO=true; exit 130' INT
    echo
    if (( rc != 0 )); then
        echo "(el comando ha terminado con el código $rc)"
    fi
    read -r -p "Pulsa Enter para volver al menú… " pausa || true
}
