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

# Dominios del usuario (o del prefijo) que NO son objetivo de esta ejecución:
# son los que pueden tener discos en este silo
DOMINIOS_VECINOS=()
cargar_dominios_vecinos() {
    local lista d x pref1="${USUARIO,,}" pref2="${PREFIJO_DOMINIO,,}"
    DOMINIOS_VECINOS=()
    lista="$(virsh list --all --name 2>/dev/null || true)"
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        [[ "${d,,}" == "$pref1"* || "${d,,}" == "$pref2"* ]] || continue
        for x in ${OBJ_DOMINIOS[@]+"${OBJ_DOMINIOS[@]}"}; do
            [[ "$x" == "$d" ]] && continue 2
        done
        DOMINIOS_VECINOS+=( "$d" )
    done <<< "$lista"
}

# ¿Usa este fichero como disco alguna máquina que no se va a eliminar?
# Devuelve su nombre por stdout.
dominio_que_usa_disco() {   # FICHERO
    local f="$1" d salida
    for d in ${DOMINIOS_VECINOS[@]+"${DOMINIOS_VECINOS[@]}"}; do
        salida="$(virsh domblklist "$d" --inactive 2>/dev/null || true)"
        if awk -v f="$f" '$2 == f { ok = 1 } END { exit !ok }' <<< "$salida"; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

# ¿Es este fichero el respaldo (imagen base) de otro qcow2 del silo que se
# conserva? Devuelve ese otro fichero por stdout.
copia_que_depende() {   # FICHERO
    local f="$1" o b x
    for o in "$SILO_DIR"/*.qcow2; do
        [[ -f "$o" && "$o" != "$f" ]] || continue
        for x in ${OBJ_FICHEROS[@]+"${OBJ_FICHEROS[@]}"}; do
            [[ "$x" == "$o" ]] && continue 2
        done
        b="$(qemu-img info -U --output=json "$o" 2>/dev/null | jq -r '."backing-filename" // empty' 2>/dev/null || true)"
        if [[ -n "$b" && "$(basename "$b")" == "$(basename "$f")" ]]; then
            echo "$o"
            return 0
        fi
    done
    return 1
}

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

    # Un fichero que ya existe puede ser el disco de otra máquina (hecha a mano
    # con otro nombre) o el respaldo de otras copias. Entonces ni se elimina
    # ni se aconseja eliminarlo.
    if (( ${#ficheros[@]} > 0 )); then
        local otro
        cargar_dominios_vecinos
        for f in "${ficheros[@]}"; do
            if otro="$(dominio_que_usa_disco "$f")"; then
                error 21 "El disco $f ya existe y lo usa la máquina '$otro', que este script no va a crear ni a eliminar.
Elige otro nombre de máquina (o de disco, con --disco). Si lo que quieres es deshacerte de '$otro':
  virsh destroy $otro; virsh undefine $otro --snapshots-metadata; rm $f"
            fi
            if otro="$(copia_que_depende "$f")"; then
                error 21 "El disco $f ya existe y es la imagen base de $(basename "$otro"), que dejaría de arrancar sin él.
Elige otro nombre de máquina (o de disco, con --disco), o elimina antes esa copia."
            fi
        done
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

    # Confirmación por teclado. Si no hay terminal (uso desde otro script),
    # --limpiar ya es una petición explícita y se sigue adelante.
    if [[ -t 0 ]]; then
        local respuesta
        read -r -p "¿Eliminar estos elementos? [s/N] " respuesta || { respuesta=""; echo; }
        case "$respuesta" in
            s|S|si|sí|Si|Sí|SI|SÍ) ;;
            *)
                echo "Cancelado: no se ha eliminado nada."
                SALIDA_CONTROLADA=true
                exit 0
                ;;
        esac
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
