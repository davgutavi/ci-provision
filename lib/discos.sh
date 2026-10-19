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

# Copia completa de una imagen de fuera del silo (ubuntu-base, que está en un
# directorio compartido): una copia COW dependería de un fichero que no es del
# alumno y que puede cambiar. Si se pide un tamaño mayor, se amplía.
#   crear_disco_copia RUTA IMAGEN TAMAÑO
crear_disco_copia() {
    local ruta="$1" origen="$2" tam="$3" vs n tam_b

    DISCOS_CREADOS+=( "$ruta" )
    cp "$origen" "$ruta"
    chmod u+w "$ruta"

    vs="$(qemu-img info --output=json "$ruta" 2>/dev/null | jq -r '."virtual-size" // empty' 2>/dev/null || true)"
    n="${tam%[MGT]}"
    case "${tam: -1}" in
        M) tam_b=$(( n * 1024 * 1024 )) ;;
        G) tam_b=$(( n * 1024 * 1024 * 1024 )) ;;
        T) tam_b=$(( n * 1024 * 1024 * 1024 * 1024 )) ;;
    esac
    if [[ "$vs" =~ ^[0-9]+$ ]] && (( tam_b > vs )); then
        qemu-img resize -q "$ruta" "$tam"
    fi
}

# El disco principal de una máquina: copia COW de una imagen del silo, o copia
# completa si la imagen está fuera de él (ubuntu-base)
#   crear_disco_principal RUTA IMAGEN TAMAÑO
crear_disco_principal() {
    if [[ "$(dirname "$2")" == "$SILO_DIR" ]]; then
        crear_disco_cow "$@"
    else
        crear_disco_copia "$@"
    fi
}

# Cómo se hace el disco principal a partir de una imagen, para los mensajes
origen_disco_principal() {   # IMAGEN
    if [[ "$(dirname "$1")" == "$SILO_DIR" ]]; then
        echo "copia COW de $(basename "$1")"
    else
        echo "copia completa de $1"
    fi
}

# Disco vacío (sin respaldo)
#   crear_disco_vacio RUTA TAMAÑO
crear_disco_vacio() {
    local ruta="$1" tam="$2"

    DISCOS_CREADOS+=( "$ruta" )
    qemu-img create -f qcow2 "$ruta" "$tam" >/dev/null
}

# Quita un fichero del registro de creados (cuando pasa a ser definitivo)
quitar_disco_creado() {
    quitar_de_lista DISCOS_CREADOS "$1"
}

# Quita VALOR del array cuyo nombre se indica (por referencia)
quitar_de_lista() {   # NOMBRE_ARRAY VALOR
    local -n lista_ref="$1"
    local quitar="$2" x
    local -a nuevos=()
    for x in ${lista_ref[@]+"${lista_ref[@]}"}; do
        if [[ "$x" != "$quitar" ]]; then
            nuevos+=( "$x" )
        fi
    done
    lista_ref=( ${nuevos[@]+"${nuevos[@]}"} )
}

# Rutas de los discos extra de una máquina, una por línea
#   discos_extra MAQUINA UNIDAD...
discos_extra() {
    local host="$1" u
    shift
    for u in "$@"; do
        echo "${SILO_DIR}/${PREFIJO_FICHERO}${host}-${u}.qcow2"
    done
}
