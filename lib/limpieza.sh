########################################
# Conflictos con lo que ya existe, y --limpiar
#
# El script siempre crea dominios y discos nuevos. Si alguno de los que va a
# crear ya existe, se detiene y lo dice; con --limpiar los elimina antes, pero
# solo exactamente esos: nunca otro dominio ni otro fichero del silo.
#
# Aquí están también las comprobaciones que comparten --limpiar, --eliminar y
# --eliminar-todo para no borrar nunca lo que no se debe:
#   - un disco que use cualquier máquina del servidor que no se vaya a eliminar;
#   - una imagen de la que dependa (directa o indirectamente) una copia que se
#     conserva;
#   - las imágenes cloud de partida;
#   - un dominio cuyos discos no están en el silo (no lo ha creado el alumno
#     con este script, aunque su nombre lo parezca: p.ej. con --prefijo).
########################################

# Los rellena quien llama: qué dominios y qué ficheros va a crear (o eliminar)
OBJ_DOMINIOS=()
OBJ_FICHEROS=()

# ¿Está VALOR entre los demás argumentos?
en_lista() {   # VALOR [ELEMENTO...]
    local x="$1" e
    shift
    for e in "$@"; do
        if [[ "$e" == "$x" ]]; then return 0; fi
    done
    return 1
}

# Pregunta sí/no por teclado. Con --si se da por contestada que sí. Sin
# terminal y sin --si no se puede preguntar, y eliminar sin confirmación sería
# peligroso (p.ej. desde un ssh sin sesión): se detiene con el error 23.
confirmar() {   # PREGUNTA
    if $SI; then
        echo "$1 [s/N] s   (--si)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        error 23 "Hace falta confirmar («$1») y no hay terminal para preguntarte.
No se ha eliminado nada. Si de verdad quieres hacerlo sin preguntas (p.ej. desde
otro script), repite el comando añadiendo --si."
    fi
    local respuesta
    read -r -p "$1 [s/N] " respuesta || { respuesta=""; echo; }
    case "$respuesta" in
        s|S|si|sí|Si|Sí|SI|SÍ) return 0 ;;
        *) return 1 ;;
    esac
}

########################################
# Quién usa cada disco
########################################

# Dominios "vecinos": TODOS los del servidor que no son objetivo de esta
# ejecución. Cualquiera de ellos podría estar usando un fichero de este silo
# (una máquina hecha a mano con otro nombre, otro prefijo, otro usuario...).
# De cada uno se anotan sus discos, para saber quién usa cada fichero.
declare -A DISCO_USADO_POR=()   # fichero → dominio vecino que lo usa
cargar_dominios_vecinos() {
    local lista d f salida
    DISCO_USADO_POR=()
    lista="$(virsh list --all --name 2>/dev/null || true)"
    while IFS= read -r d; do
        if [[ -z "$d" ]]; then continue; fi
        if en_lista "$d" ${OBJ_DOMINIOS[@]+"${OBJ_DOMINIOS[@]}"}; then continue; fi
        salida="$(virsh domblklist "$d" --inactive 2>/dev/null || true)"
        while IFS= read -r f; do
            if [[ -n "$f" && -z "${DISCO_USADO_POR[$f]:-}" ]]; then
                DISCO_USADO_POR[$f]="$d"
            fi
        done < <(awk 'NR > 2 && $2 ~ /^\// { print $2 }' <<< "$salida")
    done <<< "$lista"
}

# ¿Usa este fichero como disco alguna máquina vecina? Devuelve su nombre.
dominio_que_usa_disco() {   # FICHERO
    local d="${DISCO_USADO_POR[$1]:-}"
    if [[ -z "$d" ]]; then return 1; fi
    echo "$d"
}

# ¿Es el dominio de este silo? Todos sus discos tienen que estar en el silo
# (salvo el CD-ROM de cloud-init que deja virt-install), y al menos uno. Un
# dominio con discos en otro sitio no lo ha creado el script para este alumno,
# aunque se llame como si lo fuera.
dominio_en_silo() {   # DOMINIO
    local salida f n=0
    salida="$(virsh domblklist "$1" --inactive 2>/dev/null || true)"
    while IFS= read -r f; do
        case "$f" in
            "$SILO_DIR"/*)  n=$(( n + 1 )) ;;
            *cloudinit.iso) ;;
            *)              return 1 ;;
        esac
    done < <(awk 'NR > 2 && NF >= 2 && $2 != "-" { print $2 }' <<< "$salida")
    (( n > 0 ))
}

########################################
# Quién depende de cada imagen
#
# Se lee una sola vez la imagen base de cada qcow2 del silo (con un qemu-img
# por fichero), y todo lo demás se calcula sobre ese mapa.
########################################
declare -A RESPALDO=()     # fichero del silo → ruta de su imagen base
RESPALDOS_CARGADOS=false

cargar_respaldos() {
    if $RESPALDOS_CARGADOS; then return 0; fi
    local f
    for f in "$SILO_DIR"/*.qcow2 "$SILO_DIR"/*.img; do
        [[ -f "$f" ]] || continue
        RESPALDO[$f]="$(leer_respaldo "$f")"
    done
    RESPALDOS_CARGADOS=true
}

# Imagen base de un fichero (ruta completa), o nada. Las rutas relativas son
# relativas al directorio del propio fichero, como las interpreta qemu.
leer_respaldo() {   # FICHERO
    local b
    b="$(qemu-img info -U --output=json "$1" 2>/dev/null | jq -r '."backing-filename" // empty' 2>/dev/null || true)"
    if [[ -z "$b" ]]; then return 0; fi
    if [[ "$b" != /* ]]; then
        b="$(dirname "$1")/$b"
    fi
    printf '%s' "$b"
}

# Copias del silo cuya imagen base es este fichero, una por línea
copias_directas() {   # FICHERO
    local c
    cargar_respaldos
    for c in "${!RESPALDO[@]}"; do
        if [[ "${RESPALDO[$c]}" == "$1" ]]; then echo "$c"; fi
    done
}

# Decide cuáles de estos ficheros se pueden eliminar. Se conservan:
#   - las imágenes cloud de partida;
#   - los que use una máquina que no se va a eliminar;
#   - aquellos de los que dependa una copia que se conserva, aunque sea a
#     través de otra (si una copia se queda, se queda toda su cadena).
# Deja el resultado en BORRABLES y en CONSERVADOS ("nombre: motivo").
# Antes hay que llamar a cargar_dominios_vecinos.
BORRABLES=()
CONSERVADOS=()
filtrar_borrables() {   # FICHERO...
    local -A cand=()
    local f c otro cambio=true
    BORRABLES=()
    CONSERVADOS=()
    cargar_respaldos

    for f in "$@"; do
        if imagen_protegida "$f"; then
            CONSERVADOS+=( "$(basename "$f"): es una imagen cloud de partida (nunca se borra)" )
        elif otro="$(dominio_que_usa_disco "$f")"; then
            CONSERVADOS+=( "$(basename "$f"): lo usa la máquina '$otro'" )
        else
            cand[$f]=1
        fi
    done

    # Lo que se conserva por depender de ello una copia que se queda. Se repite
    # hasta que no cambia nada, para recorrer cadenas de cualquier longitud.
    while $cambio; do
        cambio=false
        for f in "${!cand[@]}"; do
            for c in "${!RESPALDO[@]}"; do
                if [[ "${RESPALDO[$c]}" == "$f" && -z "${cand[$c]:-}" ]]; then
                    unset 'cand[$f]'
                    CONSERVADOS+=( "$(basename "$f"): es la imagen base de $(basename "$c"), que se conserva" )
                    cambio=true
                    break
                fi
            done
        done
    done

    for f in "$@"; do
        if [[ -n "${cand[$f]:-}" ]]; then BORRABLES+=( "$f" ); fi
    done
}

########################################
# Conflictos con lo que el script va a crear
########################################
comprobar_conflictos() {   # [solo-detectar]
    local modo="${1:-}"
    local -a dominios=() ficheros=()
    local d f

    for d in ${OBJ_DOMINIOS[@]+"${OBJ_DOMINIOS[@]}"}; do
        if virsh dominfo "$d" >/dev/null 2>&1; then
            # Un dominio que se llama como los que crea el script pero tiene
            # sus discos fuera del silo es de otra persona (o hecho a mano):
            # ni se elimina ni se aconseja eliminarlo
            if ! dominio_en_silo "$d"; then
                error 21 "Ya existe una máquina llamada '$d', pero sus discos no están en tu silo:
no la ha creado este script para ti (puede ser de otro usuario del servidor), así que no se toca.
Elige otro nombre de máquina, u otro --prefijo."
            fi
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

    # Un fichero que ya existe puede ser el disco de otra máquina (hecha a mano
    # con otro nombre, o de otro prefijo) o el respaldo de otras copias.
    # Entonces ni se elimina ni se aconseja eliminarlo.
    if (( ${#ficheros[@]} > 0 )); then
        local msg x
        cargar_dominios_vecinos
        filtrar_borrables "${ficheros[@]}"
        if (( ${#CONSERVADOS[@]} > 0 )); then
            msg="Algunos de los discos que este script tendría que crear ya existen y no se pueden eliminar:"
            for x in "${CONSERVADOS[@]}"; do msg+=$'\n'"  $x"; done
            msg+=$'\n'"Elige otro nombre de máquina (o de disco, con --disco), u otro --prefijo."
            error 21 "$msg"
        fi
    fi

    # En la pasada previa a la descarga solo se avisa; con --limpiar, la
    # eliminación se hace en la pasada definitiva
    if [[ "$modo" == solo-detectar ]] && $LIMPIAR; then
        return 0
    fi

    if ! $LIMPIAR; then
        local msg="Ya existen elementos que este script tendría que crear:"
        for d in ${dominios[@]+"${dominios[@]}"}; do msg+=$'\n'"  dominio  $d"; done
        for f in ${ficheros[@]+"${ficheros[@]}"}; do msg+=$'\n'"  disco    $f"; done
        msg+=$'\n\n'"El script siempre crea máquinas y discos nuevos. Tienes estas opciones:"
        msg+=$'\n'"  a) Eliminarlos tú:"
        for d in ${dominios[@]+"${dominios[@]}"}; do
            msg+=$'\n'"       virsh destroy $d; virsh undefine $d --snapshots-metadata"
        done
        if (( ${#dominios[@]} > 0 )); then
            msg+=$'\n'"       (si la máquina ya está apagada, 'virsh destroy' dará un error; es normal)"
        fi
        for f in ${ficheros[@]+"${ficheros[@]}"}; do
            msg+=$'\n'"       rm $f"
        done
        msg+=$'\n'"  b) Repetir el comando añadiendo --limpiar, que elimina exactamente eso y nada más."
        if $CLUSTER && [[ -z "$BASE_OPT" ]] && en_lista "$(disco_base_cluster)" ${ficheros[@]+"${ficheros[@]}"}; then
            msg+=$'\n'"  c) Reutilizar la imagen base que ya tienes, sin volver a construirla:"
            msg+=$'\n'"       $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--gluster-cluster --base $(basename "$(disco_base_cluster)")"
            msg+=$'\n'"     (añade --limpiar si además existen los nodos)"
        fi
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

    if ! confirmar "¿Eliminar estos elementos?"; then
        echo "Cancelado: no se ha eliminado nada."
        echo "No se ha creado nada. Usa otro nombre de máquina (o --prefijo) para no pisar lo que ya tienes."
        SALIDA_CONTROLADA=true
        exit 0
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
