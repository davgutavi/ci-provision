########################################
# Asistente (--menu): menús de whiptail que construyen la línea de comandos y
# la ejecutan. Toda la lógica sigue en el mismo sitio: el asistente solo elige
# los argumentos, enseña el comando equivalente y lo lanza en otro proceso.
########################################

# Colores de los diálogos: la paleta clásica de newt (fondo azul, ventanas
# grises). Si el usuario tiene NEWT_COLORS definida, se respeta la suya.
PALETA_ASISTENTE='
root=white,blue
roottext=white,blue
helpline=white,blue
window=black,lightgray
border=black,lightgray
shadow=black,black
title=blue,lightgray
textbox=black,lightgray
label=black,lightgray
listbox=black,lightgray
actlistbox=white,blue
sellistbox=black,cyan
actsellistbox=white,blue
checkbox=black,lightgray
actcheckbox=white,blue
entry=black,cyan
button=black,cyan
actbutton=white,blue
compactbutton=black,lightgray
'

# Ejecuta whiptail y devuelve su selección por stdout (whiptail la escribe por
# stderr). Estado: 0 aceptar, 1 cancelar, 255 Esc. Va con locale UTF-8: con
# LC_ALL=C (la del resto del script) whiptail corta los textos en las tildes.
wt() {
    local out rc=0
    out="$(NEWT_COLORS="${NEWT_COLORS:-$PALETA_ASISTENTE}" LC_ALL="$LOCALE_UTF8" \
           whiptail --title "ci-provision $VERSION" "$@" 3>&1 1>&2 2>&3)" || rc=$?
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
        sel="$(wt --notags --menu $'¿Qué quieres hacer?\n(muévete con las flechas y elige con Enter)' 20 78 8 \
            basica   "Crear una máquina básica (boletín 1; Debian 12 propuesta)" \
            extra    "Crear una máquina con IP .2 y 6 discos extra (boletín 2, epígrafe 2.1)" \
            cluster  "Crear la infraestructura GlusterFS (boletín 2, epígrafe 2.4)" \
            base     "Crear solo la imagen base GlusterFS" \
            listar   "Mostrar mis máquinas virtuales" \
            eliminar "Eliminar una máquina virtual (y su almacenamiento)" \
            todo     "Eliminar todas mis máquinas virtuales (y su almacenamiento)" \
            salir    "Salir")" || salir_asistente
        case "$sel" in
            basica)   asistente_maquina basica ;;
            extra)    asistente_maquina extra ;;
            cluster)  asistente_cluster ;;
            base)     asistente_base ;;
            listar)   asistente_listar ;;
            eliminar) asistente_eliminar ;;
            todo)     ejecutar_asistente --eliminar-todo ;;
            *)        salir_asistente ;;
        esac
    done
}

# Opciones marcadas en un checklist → argumentos (la contraseña se pide aparte).
# Deja el resultado en OPCIONES_ARGS; devuelve 1 si se cancela. La contraseña
# no va en los argumentos (cualquier usuario del servidor la vería con 'ps'):
# se guarda en PASS_ASISTENTE y la orden lleva '--ssh-pass -'.
OPCIONES_ARGS=()
PASS_ASISTENTE=""
opciones_a_argumentos() {   # SALIDA_DEL_CHECKLIST
    local o pass
    OPCIONES_ARGS=()
    PASS_ASISTENTE=""
    for o in $(etiquetas "$1"); do
        if [[ "$o" == ssh-pass ]]; then
            pass="$(wt --passwordbox $'Contraseña para administrador\n(solo letras sin tilde, números y signos básicos):' 10 70)" || return 1
            if [[ -z "$pass" ]]; then return 1; fi
            PASS_ASISTENTE="$pass"
            OPCIONES_ARGS+=( --ssh-pass - )
        elif [[ "$o" == discos-crea-entorno ]]; then
            OPCIONES_ARGS+=( --discos-nodo "${#UNIDADES_POSIBLES_NODO[@]}" )
        else
            OPCIONES_ARGS+=( "--$o" )
        fi
    done
    return 0
}

# on/off según si OPCION es la elegida (para los --radiolist)
marca() {   # OPCION ELEGIDA
    if [[ "$1" == "$2" ]]; then echo on; else echo off; fi
}

# Imagen de una máquina suelta. Deja --imagen en IMAGEN_ARGS (nada si es la
# de por defecto); devuelve 1 si se cancela.
IMAGEN_ARGS=()
elegir_imagen_maquina() {   # PRESELECCIONADA
    local img
    IMAGEN_ARGS=()
    img="$(wt --notags --radiolist $'Sistema de la máquina (marca con la barra espaciadora):' 11 76 2 \
        noble    "Ubuntu 24.04 (boletín 2)" "$(marca noble "$1")" \
        debian12 "Debian 12 (boletín 1)"    "$(marca debian12 "$1")")" || return 1
    if [[ -n "$img" && "$img" != "$IMAGEN_DEFECTO" ]]; then
        IMAGEN_ARGS=( --imagen "$img" )
    fi
}

# De qué imagen sale la base GlusterFS (mismo convenio que la anterior)
elegir_imagen_gluster() {
    local img
    IMAGEN_ARGS=()
    img="$(wt --notags --radiolist $'¿De qué imagen sale la base GlusterFS?\n(marca con la barra espaciadora)' 13 78 3 \
        noble       "Imagen cloud de Ubuntu 24.04, la misma que SERVER1 (recomendada)" on \
        ubuntu-base "ubuntu-base.qcow2 del boletín 1, como la construcción manual" off \
        debian12    "Imagen cloud de Debian 12" off)" || return 1
    if [[ -n "$img" && "$img" != "$IMAGEN_DEFECTO_GLUSTER" ]]; then
        IMAGEN_ARGS=( --imagen "$img" )
    fi
}

# Nombre corto válido para el asistente: si no lo es, lo dice y devuelve 1
# (un nombre que empezara por '-' se tomaría además por una opción)
nombre_valido_asistente() {   # NOMBRE
    if [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] && (( ${#1} <= 63 )); then
        return 0
    fi
    wt --msgbox "El nombre '$1' no es válido: solo letras, números y guiones, empezando
por letra o número (p.ej. server1)." 9 72 || true
    return 1
}

asistente_maquina() {   # basica | extra (IP .2 sugerida y discos extra marcados)
    local modo="$1" nombre ip sugerida libres texto marcado sel
    local -a args=()

    nombre="$(wt --inputbox $'Nombre corto de la máquina (letras, números y guiones).\nEl dominio será '"${PREFIJO_DOMINIO}"$'-NOMBRE y el disco NOMBRE.qcow2.' 11 70 server1)" || return 0
    if [[ -z "$nombre" ]]; then return 0; fi
    nombre_valido_asistente "$nombre" || return 0

    sugerida=""
    if [[ "$modo" == extra ]]; then
        sugerida="$(ip_de_la_red 2)"
    fi
    libres="$(ips_libres_texto)"
    texto="IP fija dentro de tu red virtual. Déjala vacía para usar DHCP."
    if [[ -n "$libres" ]]; then
        texto+=$'\nIPs libres de tu red:\n'"$libres"
    fi
    ip="$(wt --inputbox "$texto" 16 70 "$sugerida")" || return 0

    # El boletín 1 usa Debian 12; el 2, Ubuntu 24.04
    if [[ "$modo" == basica ]]; then
        elegir_imagen_maquina debian12 || return 0
    else
        elegir_imagen_maquina noble || return 0
    fi

    marcado=off
    if [[ "$modo" == extra ]]; then marcado=on; fi
    sel="$(wt --checklist $'Opciones (marca con la barra espaciadora):' 16 76 5 \
        extra-disks    "Seis discos extra vdb..vdg de ${TAM_DISCO_EXTRA}" "$marcado" \
        ssh-pass       "Contraseña para administrador y SSH por contraseña" off \
        no-root        "No habilitar al usuario root" off \
        no-virt-viewer "Sin consola gráfica (virt-viewer)" off \
        limpiar        "Eliminar antes lo que ya exista con esos nombres" off)" || return 0
    opciones_a_argumentos "$sel" || return 0

    args=( ${IMAGEN_ARGS[@]+"${IMAGEN_ARGS[@]}"} ${OPCIONES_ARGS[@]+"${OPCIONES_ARGS[@]}"} "$nombre" )
    if [[ -n "$ip" ]]; then args+=( "$ip" ); fi
    ejecutar_asistente "${args[@]}"
}

asistente_cluster() {
    local base sel usar_base=false
    local -a args=( --gluster-cluster )

    base="$(disco_base_cluster)"
    if [[ -f "$base" ]]; then
        if wt --yesno "Ya tienes $(basename "$base") en el silo."$'\n¿Quieres usarla como imagen base, sin volver a construirla?' 10 70; then
            args+=( --base "$(basename "$base")" )
            usar_base=true
        fi
    fi
    if ! $usar_base; then
        elegir_imagen_gluster || return 0
        args+=( ${IMAGEN_ARGS[@]+"${IMAGEN_ARGS[@]}"} )
    fi

    sel="$(wt --checklist $'Opciones (marca con la barra espaciadora):' 15 78 5 \
        limpiar             "Eliminar antes los nodos y la imagen base si ya existen" off \
        discos-crea-entorno "${#UNIDADES_POSIBLES_NODO[@]} discos por nodo (vdb..vdh), como crea-entorno.sh" off \
        ssh-pass            "Contraseña para administrador y SSH por contraseña" off \
        no-root             "No habilitar al usuario root" off \
        no-virt-viewer      "Sin consola gráfica (virt-viewer)" off)" || return 0
    opciones_a_argumentos "$sel" || return 0

    args+=( ${OPCIONES_ARGS[@]+"${OPCIONES_ARGS[@]}"} )
    ejecutar_asistente "${args[@]}"
}

asistente_base() {
    local nombre
    local -a args=( --glusterfs )

    nombre="$(wt --inputbox $'Nombre de la imagen base.\nQuedará NOMBRE.qcow2 en el silo, sin máquina, lista para hacer copias.' 11 70 "$CLUSTER_BASE")" || return 0
    if [[ -z "$nombre" ]]; then return 0; fi
    nombre_valido_asistente "$nombre" || return 0
    elegir_imagen_gluster || return 0
    args+=( ${IMAGEN_ARGS[@]+"${IMAGEN_ARGS[@]}"} )
    if wt --defaultno --yesno $'Si ya existe una máquina o un disco con ese nombre,\n¿eliminarlos antes (--limpiar)?' 9 70; then
        args+=( --limpiar )
    fi
    args+=( "$nombre" )
    ejecutar_asistente "${args[@]}"
}

# Lista de máquinas y discos sueltos; al elegir uno se abre su ficha
asistente_listar() {
    local d f sel estado ip lista n tipo
    local -a items=()

    cargar_respaldos

    while IFS= read -r d; do
        if [[ -z "$d" ]]; then continue; fi
        estado="$(estado_dominio "$d")"
        ip="-"
        if [[ "$estado" == "en ejecución" ]]; then ip="$(ip_dominio "$d")"; fi
        lista="$(discos_de_dominio "$d")"
        n=0
        if [[ -n "$lista" ]]; then n="$(grep -c . <<< "$lista" || true)"; fi
        items+=( "m:$d" "$(rellenar "${d#"${PREFIJO_DOMINIO}-"}" 14) $(rellenar "$estado" 12) $(rellenar "$ip" 15) $n disco(s)" )
    done < <(dominios_propios)

    while IFS= read -r f; do
        if [[ -z "$f" ]]; then continue; fi
        tipo="sin máquina"
        if imagen_protegida "$f"; then tipo="imagen cloud"; fi
        items+=( "d:$f" "$(rellenar "$(basename "$f")" 14) $(rellenar "$tipo" 12) $(descripcion_disco_suelto "$f")" )
    done < <(discos_sin_maquina)

    if (( ${#items[@]} == 0 )); then
        wt --msgbox "No tienes máquinas ni discos en el silo." 8 60 || true
        return 0
    fi

    while true; do
        sel="$(wt --notags --menu $'Mis máquinas virtuales y los discos del silo.\nElige una entrada para ver su ficha; Cancelar para volver.' 22 78 12 "${items[@]}")" || return 0
        case "$sel" in
            m:*) ficha_maquina "${sel#m:}" ;;
            d:*) ficha_disco "${sel#d:}" ;;
        esac
    done
}

ficha_maquina() {   # DOMINIO
    local d="$1" estado ip lista f resp texto n=4
    estado="$(estado_dominio "$d")"
    ip="-"
    if [[ "$estado" == "en ejecución" ]]; then ip="$(ip_dominio "$d")"; fi
    texto="Máquina : $d   (hostname: ${d#"${PREFIJO_DOMINIO}-"})"$'\n'"Estado  : $estado"$'\n'"IP      : $ip"$'\n'"Discos  :"
    lista="$(discos_de_dominio "$d")"
    if [[ -z "$lista" ]]; then
        texto+=" (ninguno en el silo)"
    fi
    while IFS= read -r f; do
        if [[ -n "$f" ]]; then
            resp="$(respaldo_de "$f")"
            texto+=$'\n'"          $(basename "$f")${resp:+ (copia de $resp)}"
            n=$(( n + 1 ))
        fi
    done <<< "$lista"
    if [[ "$ip" != "-" ]]; then
        texto+=$'\n'"Acceso  : ssh administrador@$ip"
        n=$(( n + 1 ))
    fi
    texto+=$'\n'"Consola : virsh console $d"
    texto+=$'\n\n'"Para eliminarla con sus discos: $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--eliminar ${d#"${PREFIJO_DOMINIO}-"}"
    n=$(( n + 3 ))
    wt --msgbox "$texto" $(( n + 6 )) 78 || true
}

ficha_disco() {   # FICHERO
    local f="$1" vs texto
    vs="$(tam_virtual "$f")"
    texto="Disco   : $(basename "$f")"$'\n'"Ruta    : $f"
    if [[ "$vs" =~ ^[0-9]+$ ]]; then
        texto+=$'\n'"Tamaño  : $(bytes_a_gib "$vs") GiB (virtual)"
    fi
    texto+=$'\n'"Qué es  : $(descripcion_disco_suelto "$f")"
    wt --msgbox "$texto" 11 78 || true
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
        wt --msgbox "No tienes máquinas (dominios ${PREFIJO_DOMINIO}-*)."$'\nLos discos sueltos del silo se ven en "Mostrar mis máquinas virtuales"\ny se eliminan con "Eliminar todas mis máquinas virtuales".' 11 76 || true
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
    # Con --menu --dry-run, todo lo que se lance es también una simulación; con
    # --menu --si, sin preguntas
    if $SI; then
        set -- --si "$@"
    fi
    if $DRY_RUN; then
        set -- --dry-run "$@"
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
    if [[ -n "$PASS_ASISTENTE" ]]; then
        CI_PROVISION_SSH_PASS="$PASS_ASISTENTE" bash "$0" "$@" || rc=$?
    else
        bash "$0" "$@" || rc=$?
    fi
    PASS_ASISTENTE=""
    trap 'INTERRUMPIDO=true; exit 130' INT
    echo
    if (( rc != 0 )); then
        echo "(el comando ha terminado con el código $rc)"
    fi
    read -r -p "Pulsa Enter para volver al menú… " pausa || true
}
