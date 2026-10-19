########################################
# Ver y eliminar lo que ya existe: --listar, --eliminar y --eliminar-todo
#
# Todo parte de libvirt, no de los nombres: los discos de una máquina son los
# que dice 'virsh domblklist' (solo los que están en el silo). Nunca se borra
# un disco que use otra máquina ni una imagen de la que dependan otras copias
# (ver filtrar_borrables en limpieza.sh).
########################################

# Dominios del usuario (o del prefijo): los que empiezan por PREFIJO- y tienen
# sus discos en el silo. Los nombres de dominio son de todo el servidor: con
# --prefijo, otro usuario podría tener uno que empiece igual.
dominios_propios() {
    local lista d
    lista="$(virsh list --all --name 2>/dev/null || true)"
    while IFS= read -r d; do
        if [[ -n "$d" && "$d" == "${PREFIJO_DOMINIO}-"* ]] && dominio_en_silo "$d"; then
            echo "$d"
        fi
    done <<< "$lista" | sort
}

# Discos de un dominio que están en el silo (según su definición persistente)
discos_de_dominio() {   # DOMINIO
    local salida
    salida="$(virsh domblklist "$1" --inactive 2>/dev/null || true)"
    awk -v silo="$SILO_DIR/" 'NR > 2 && index($2, silo) == 1 { print $2 }' <<< "$salida"
}

estado_dominio() {   # DOMINIO
    local s
    s="$(virsh domstate "$1" 2>/dev/null || true)"
    case "$s" in
        running)    echo "en ejecución" ;;
        "shut off") echo "apagada" ;;
        paused)     echo "pausada" ;;
        "")         echo "?" ;;
        *)          echo "$s" ;;
    esac
}

# IP de una máquina en ejecución: la que reporta el agente o, si no, la del DHCP
ip_dominio() {   # DOMINIO
    local ip salida
    ip="$(obtener_ip_agente "$1")"
    if [[ -z "$ip" ]]; then
        salida="$(virsh domifaddr "$1" --source lease 2>/dev/null || true)"
        ip="$(awk '$3 == "ipv4" { split($4, a, "/"); print a[1]; exit }' <<< "$salida")"
    fi
    echo "${ip:--}"
}

# Imagen de la que es copia un fichero (solo el nombre), o nada. Usa el mapa
# de respaldos si ya está cargado; si no, pregunta solo por este fichero.
respaldo_de() {   # FICHERO
    local b
    if $RESPALDOS_CARGADOS; then
        b="${RESPALDO[$1]:-}"
    else
        b="$(leer_respaldo "$1")"
    fi
    if [[ -n "$b" ]]; then
        basename "$b"
    fi
}

# Copias del silo que dependen de un fichero: "a.qcow2, b.qcow2". Quien la
# llame muchas veces debe cargar antes el mapa (cargar_respaldos) en su propio
# proceso: dentro de $(...) no se conservaría entre llamadas.
copias_de() {   # FICHERO
    local c res=""
    while IFS= read -r c; do
        if [[ -n "$c" ]]; then res+="${res:+, }$(basename "$c")"; fi
    done < <(copias_directas "$1" | sort)
    echo "$res"
}

# Discos del silo (los qcow2 y la imagen cloud de Ubuntu, que es un .img) que
# no usa ninguna de las máquinas del usuario
discos_sin_maquina() {
    local f d usados=""
    for d in $(dominios_propios); do
        usados+="$(discos_de_dominio "$d")"$'\n'
    done
    for f in "$SILO_DIR"/*.qcow2 "$SILO_DIR/$IMAGEN_NOBLE"; do
        if [[ -f "$f" ]] && ! grep -qxF "$f" <<< "$usados"; then
            echo "$f"
        fi
    done
}

# Rellena con espacios hasta ANCHO caracteres. printf cuenta bytes, y con las
# tildes (dos bytes) las columnas se desalinean.
rellenar() {   # TEXTO ANCHO
    local n
    n="$(LC_ALL="$LOCALE_UTF8" wc -m <<< "$1")"
    n=$(( n - 1 ))
    if (( n >= $2 )); then
        printf '%s' "$1"
    else
        printf '%s%*s' "$1" $(( $2 - n )) ''
    fi
}

# "server1.qcow2 (copia de X) + N discos extra", a partir de los discos de un
# dominio (uno por línea)
descripcion_discos() {   # LISTA
    local lista="$1" n principal resp desc
    if [[ -z "$lista" ]]; then
        echo "sin discos en el silo"
        return 0
    fi
    n="$(grep -c . <<< "$lista" || true)"
    principal="${lista%%$'\n'*}"
    desc="$(basename "$principal")"
    resp="$(respaldo_de "$principal")"
    if [[ -n "$resp" ]]; then desc+=" (copia de $resp)"; fi
    if (( n > 1 )); then desc+=" + $(( n - 1 )) discos extra"; fi
    echo "$desc"
}

# Qué es un disco del silo que no usa ninguna máquina
descripcion_disco_suelto() {   # FICHERO
    local f="$1" resp dep desc=""
    if [[ "$f" == "$SILO_DIR/$IMAGEN_NOBLE" ]]; then
        echo "imagen cloud de Ubuntu 24.04: de ella salen las máquinas (no la borres)"
        return 0
    elif [[ "$f" == "$SILO_DIR/$IMAGEN_DEBIAN" ]]; then
        echo "imagen cloud de Debian 12: de ella salen las máquinas (no la borres)"
        return 0
    fi
    resp="$(respaldo_de "$f")"
    if [[ -n "$resp" ]]; then desc="copia de $resp"; fi
    dep="$(copias_de "$f")"
    if [[ -n "$dep" ]]; then desc+="${desc:+; }imagen base de: $dep"; fi
    if [[ -z "$desc" ]]; then desc="disco suelto"; fi
    echo "$desc"
}

########################################
# --listar
########################################
listar_maquinas() {
    local d estado ip f
    local -a doms=() sueltos=()

    cargar_respaldos

    while IFS= read -r d; do
        if [[ -n "$d" ]]; then doms+=( "$d" ); fi
    done < <(dominios_propios)

    if (( ${#doms[@]} == 0 )); then
        echo "No tienes máquinas (dominios que empiecen por ${PREFIJO_DOMINIO}-)."
    else
        echo "Máquinas ${PREFIJO_DOMINIO}-* (${#doms[@]}):"
        for d in "${doms[@]}"; do
            estado="$(estado_dominio "$d")"
            ip="-"
            if [[ "$estado" == "en ejecución" ]]; then
                ip="$(ip_dominio "$d")"
            fi
            printf '  %s %s %s %s\n' "$(rellenar "$d" 26)" "$(rellenar "$estado" 13)" "$(rellenar "$ip" 16)" "$(descripcion_discos "$(discos_de_dominio "$d")")"
        done
    fi

    while IFS= read -r f; do
        if [[ -n "$f" ]]; then sueltos+=( "$f" ); fi
    done < <(discos_sin_maquina)

    if (( ${#sueltos[@]} > 0 )); then
        echo
        echo "Discos del silo sin máquina:"
        for f in "${sueltos[@]}"; do
            printf '  %s %s\n' "$(rellenar "$(basename "$f")" 26)" "$(descripcion_disco_suelto "$f")"
        done
    fi
}

########################################
# --eliminar y --eliminar-todo
########################################

# Lo que se eliminaría y lo que se conserva (con el motivo)
ELIM_DOMINIOS=()
ELIM_FICHEROS=()
ELIM_DIRS=()
ELIM_CONSERVADOS=()
ELIM_SIN_NADA=()

# Rellena las listas anteriores para las máquinas indicadas por su nombre corto
planificar_eliminacion() {   # NOMBRE...
    local m vm f d habia
    local -a ficheros=()
    ELIM_DOMINIOS=(); ELIM_FICHEROS=(); ELIM_DIRS=(); ELIM_CONSERVADOS=(); ELIM_SIN_NADA=()

    for m in "$@"; do
        vm="${PREFIJO_DOMINIO}-${m}"
        habia=false
        if virsh dominfo "$vm" >/dev/null 2>&1 && ! dominio_en_silo "$vm"; then
            # Se llama como las tuyas, pero sus discos no están en tu silo
            ELIM_CONSERVADOS+=( "máquina $vm: sus discos no están en tu silo (no la ha creado este script para ti)" )
            habia=true
        elif virsh dominfo "$vm" >/dev/null 2>&1; then
            ELIM_DOMINIOS+=( "$vm" )
            habia=true
            while IFS= read -r f; do
                if [[ -n "$f" ]] && ! en_lista "$f" ${ficheros[@]+"${ficheros[@]}"}; then
                    ficheros+=( "$f" )
                fi
            done < <(discos_de_dominio "$vm")
        fi
        # También los discos que llevan su nombre aunque no estén conectados
        # (una imagen base hecha con --glusterfs, restos de otra ejecución)
        for f in "$SILO_DIR/$(disco_de "$m")" "$SILO_DIR/${PREFIJO_FICHERO}${m}"-vd?.qcow2; do
            if [[ -f "$f" ]] && ! en_lista "$f" ${ficheros[@]+"${ficheros[@]}"}; then
                ficheros+=( "$f" )
                habia=true
            fi
        done
        for d in "$SILO_DIR/cloudinit-${vm}" "$SILO_DIR/cloudinit-${vm}.dry-run"; do
            if [[ -d "$d" ]]; then
                ELIM_DIRS+=( "$d" )
                habia=true
            fi
        done
        if ! $habia; then
            ELIM_SIN_NADA+=( "$m" )
        fi
    done

    # Lo que use otra máquina, o de lo que dependan copias que se conservan,
    # se conserva
    OBJ_DOMINIOS=( ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"} )
    OBJ_FICHEROS=( ${ficheros[@]+"${ficheros[@]}"} )
    cargar_dominios_vecinos
    if (( ${#ficheros[@]} > 0 )); then
        filtrar_borrables "${ficheros[@]}"
        ELIM_FICHEROS=( ${BORRABLES[@]+"${BORRABLES[@]}"} )
        ELIM_CONSERVADOS+=( ${CONSERVADOS[@]+"${CONSERVADOS[@]}"} )
    fi
}

hay_algo_que_eliminar() {
    (( ${#ELIM_DOMINIOS[@]} + ${#ELIM_FICHEROS[@]} + ${#ELIM_DIRS[@]} > 0 ))
}

mostrar_plan_eliminacion() {
    local d f x
    if hay_algo_que_eliminar; then
        echo "Se va a eliminar:"
        for d in ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"}; do
            echo "  máquina  $d ($(estado_dominio "$d"))"
        done
        for f in ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"}; do
            echo "  disco    $f"
        done
        for x in ${ELIM_DIRS[@]+"${ELIM_DIRS[@]}"}; do
            echo "  ficheros $x/"
        done
    fi
    if (( ${#ELIM_CONSERVADOS[@]} > 0 )); then
        echo "Se conserva:"
        for x in "${ELIM_CONSERVADOS[@]}"; do
            echo "  $x"
        done
    fi
    for x in ${ELIM_SIN_NADA[@]+"${ELIM_SIN_NADA[@]}"}; do
        echo "  (de '$x' no hay nada: ni la máquina ${PREFIJO_DOMINIO}-$x ni discos con ese nombre)"
    done
}

ejecutar_eliminacion() {
    local d f x
    for d in ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"}; do
        virsh destroy "$d" >/dev/null 2>&1 || true
        if ! virsh undefine "$d" --snapshots-metadata >/dev/null 2>&1; then
            error 22 "No se ha podido eliminar la máquina '$d'. Inténtalo a mano:
  virsh destroy $d; virsh undefine $d --snapshots-metadata"
        fi
        echo "  ✔ máquina $d eliminada"
    done
    for f in ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"}; do
        rm -f "$f"
        echo "  ✔ disco $f eliminado"
    done
    for x in ${ELIM_DIRS[@]+"${ELIM_DIRS[@]}"}; do
        rm -rf "$x"
        echo "  ✔ ficheros $x eliminados"
    done
}

cancelar_eliminacion() {
    echo "Cancelado: no se ha eliminado nada."
    SALIDA_CONTROLADA=true
    exit 0
}

eliminar_maquinas() {   # NOMBRE...
    local x msg
    planificar_eliminacion "$@"

    if ! hay_algo_que_eliminar; then
        msg="No hay nada que eliminar."
        for x in ${ELIM_SIN_NADA[@]+"${ELIM_SIN_NADA[@]}"}; do
            msg+=$'\n'"  '$x': no existe la máquina ${PREFIJO_DOMINIO}-$x ni discos con ese nombre."
        done
        for x in ${ELIM_CONSERVADOS[@]+"${ELIM_CONSERVADOS[@]}"}; do
            msg+=$'\n'"  $x (se conserva)."
        done
        msg+=$'\n'"Para ver lo que tienes: $0 --listar"
        error 22 "$msg"
    fi

    mostrar_plan_eliminacion
    if $DRY_RUN; then
        echo "  (--dry-run: no se elimina nada)"
        return 0
    fi
    if ! confirmar "¿Eliminar?"; then
        cancelar_eliminacion
    fi
    ejecutar_eliminacion
}

eliminar_todo() {
    local d f
    local -a nombres=() candidatos=() sueltos=()

    while IFS= read -r d; do
        if [[ -n "$d" ]]; then nombres+=( "${d#"${PREFIJO_DOMINIO}-"}" ); fi
    done < <(dominios_propios)

    if (( ${#nombres[@]} > 0 )); then
        planificar_eliminacion "${nombres[@]}"
    else
        ELIM_DOMINIOS=(); ELIM_FICHEROS=(); ELIM_DIRS=(); ELIM_CONSERVADOS=(); ELIM_SIN_NADA=()
    fi

    # Directorios cloud-init que quedaran de máquinas que ya no existen
    for d in "$SILO_DIR"/cloudinit-"${PREFIJO_DOMINIO}"-*; do
        if [[ -d "$d" ]] && ! en_lista "$d" ${ELIM_DIRS[@]+"${ELIM_DIRS[@]}"}; then
            ELIM_DIRS+=( "$d" )
        fi
    done

    # Discos del silo que quedarían sin máquina, salvo las imágenes cloud.
    # Se comprueba contra todos los dominios del servidor y contra todas las
    # copias del silo. Los discos de las máquinas ya están decididos (si el
    # alumno dice que no a estos, sus copias se quedan y no pueden perder su
    # imagen base); aquí solo se decide qué otros se pueden ofrecer.
    for f in "$SILO_DIR"/*.qcow2; do
        if [[ ! -f "$f" ]] || imagen_protegida "$f"; then continue; fi
        if en_lista "$f" ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"}; then continue; fi
        if [[ -n "$PREFIJO_OPT" && "$(basename "$f")" != "${PREFIJO_OPT}-"* ]]; then continue; fi
        candidatos+=( "$f" )
    done
    if (( ${#candidatos[@]} > 0 )); then
        echo "Comprobando qué discos del silo usa alguna máquina…"
        OBJ_DOMINIOS=( ${ELIM_DOMINIOS[@]+"${ELIM_DOMINIOS[@]}"} )
        cargar_dominios_vecinos
        filtrar_borrables ${ELIM_FICHEROS[@]+"${ELIM_FICHEROS[@]}"} "${candidatos[@]}"
        for f in ${BORRABLES[@]+"${BORRABLES[@]}"}; do
            if en_lista "$f" "${candidatos[@]}"; then sueltos+=( "$f" ); fi
        done
        for f in ${CONSERVADOS[@]+"${CONSERVADOS[@]}"}; do
            ELIM_CONSERVADOS+=( "$f" )
        done
    fi

    if ! hay_algo_que_eliminar && (( ${#sueltos[@]} == 0 )); then
        error 22 "No hay nada que eliminar: ni máquinas ${PREFIJO_DOMINIO}-* ni discos sin máquina en $SILO_DIR
(aparte de las imágenes cloud $IMAGEN_NOBLE y $IMAGEN_DEBIAN, que se conservan siempre)."
    fi

    mostrar_plan_eliminacion
    if (( ${#sueltos[@]} > 0 )); then
        echo "Discos del silo sin máquina (se preguntará aparte):"
        for f in "${sueltos[@]}"; do
            echo "  disco    $f"
        done
    fi
    if $DRY_RUN; then
        echo "  (--dry-run: no se elimina nada)"
        return 0
    fi

    if hay_algo_que_eliminar; then
        if ! confirmar "¿Eliminar las máquinas con sus discos?"; then
            cancelar_eliminacion
        fi
        ejecutar_eliminacion
    fi
    if (( ${#sueltos[@]} > 0 )); then
        if confirmar "¿Eliminar también los ${#sueltos[@]} discos sin máquina?"; then
            for f in "${sueltos[@]}"; do
                rm -f "$f"
                echo "  ✔ disco $f eliminado"
            done
        else
            echo "Los discos sin máquina se conservan."
        fi
    fi
}
