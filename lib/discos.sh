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
