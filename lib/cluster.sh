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
        echo "${SILO_DIR}/${PREFIJO_FICHERO}${host}-${u}.qcow2"
    done
}

# Disco de la imagen base del clúster: la que se construye en la fase 1 o,
# con --base, una que ya existe en el silo
disco_base_cluster() {
    if [[ -n "$BASE_OPT" ]]; then
        echo "${SILO_DIR}/${BASE_OPT}"
    else
        echo "${SILO_DIR}/${PREFIJO_FICHERO}${CLUSTER_BASE}.qcow2"
    fi
}

# Rellena OBJ_DOMINIOS y OBJ_FICHEROS con todo lo que crea el clúster
objetivos_cluster() {
    local host d
    OBJ_DOMINIOS=()
    OBJ_FICHEROS=()
    if [[ -z "$BASE_OPT" ]]; then
        OBJ_DOMINIOS+=( "${PREFIJO_DOMINIO}-${CLUSTER_BASE}" )
        OBJ_FICHEROS+=( "${SILO_DIR}/${PREFIJO_FICHERO}${CLUSTER_BASE}.qcow2" )
    fi
    for host in "${CLUSTER_NODOS[@]}"; do
        OBJ_DOMINIOS+=( "${PREFIJO_DOMINIO}-${host}" )
        OBJ_FICHEROS+=( "${SILO_DIR}/${PREFIJO_FICHERO}${host}.qcow2" )
        while IFS= read -r d; do
            OBJ_FICHEROS+=( "$d" )
        done < <(discos_extra_nodo "$host")
    done
}

########################################
# Base GlusterFS: crea la máquina, espera a que cloud-init termine, la apaga
# y elimina el dominio. Queda solo el disco, listo para hacer copias COW.
# Es lo que describen los pasos 3 a 5 del procedimiento del apéndice A.3.2,
# y lo usan tanto --glusterfs como la fase 1 de --gluster-cluster.
#   crear_base_gluster DOMINIO HOSTNAME DISCO
########################################
crear_base_gluster() {
    local vm="$1" host="$2" disco="$3"

    generar_cloudinit "$vm" "$host" "" gluster
    construir_comando "$vm" "$RAM_MB" "$VCPUS" "$disco"

    echo "→ Creando el disco $(basename "$disco") (copia COW de $(basename "$BASE_IMG"), $TAM_DISCO)…"
    crear_disco_cow "$disco" "$BASE_IMG" "$TAM_DISCO"

    echo "→ Creando la máquina '$vm' con cloud-init…"
    crear_dominio "$vm"

    # Para una base no vale "se da por terminada": si no se puede consultar
    # cloud-init, se sigue esperando hasta agotar el tiempo
    local lista=true acceso
    EXIGIR_ESTADO_CI=true
    esperar_maquinas "$vm" || lista=false
    EXIGIR_ESTADO_CI=false
    if ! $lista; then
        error 70 "No se ha podido confirmar que cloud-init haya terminado en '$vm' en ${WAIT_TIMEOUT}s.
Sin esa confirmación no puede servir de base. Comprueba la carga del servidor y vuelve a intentarlo."
    fi

    if [[ "${ESTADO_CI[$vm]}" != "done" ]]; then
        # Se conserva la máquina para poder examinarla
        CREACION_COMPLETA=true
        if $NO_ROOT; then
            acceso="ssh administrador@${IPS_DETECTADAS[$vm]:-IP}    (con tu clave)"
        else
            acceso="virsh console $vm    (root, contraseña ${PASS_CONSOLA})"
        fi
        error 71 "cloud-init ha terminado con errores en '$vm' (probablemente al instalar
glusterfs-server). Las copias heredarían el problema, así que se detiene aquí.
La máquina se conserva para que puedas examinarla:
  $acceso
  y dentro: cloud-init status --long
Cuando termines, repite el comando añadiendo --limpiar, o elimínala tú:
  virsh destroy $vm; virsh undefine $vm --snapshots-metadata; rm $disco"
    fi

    echo "→ Apagando '$vm'…"
    if ! apagar_maquina "$vm"; then
        error 70 "La máquina '$vm' no se ha apagado en ${SHUTDOWN_TIMEOUT}s.
Se deshace lo creado en esta ejecución. Comprueba la carga del servidor (virsh list --all, uptime)
y vuelve a intentarlo. Si el dominio siguiera ahí: virsh destroy $vm; virsh undefine $vm --snapshots-metadata"
    fi

    # El dominio sobra: el disco se queda como respaldo de las copias
    virsh undefine "$vm" --snapshots-metadata >/dev/null
    quitar_dominio_creado "$vm"
    # A partir de aquí la base ya vale: si falla lo siguiente, se conserva
    quitar_disco_creado "$disco"
    BASE_CONSERVADA="$disco"
    echo "✔ Base lista: $(basename "$disco") (el dominio '$vm' se ha eliminado; el disco se conserva)."
}

mostrar_plan_cluster() {
    local base_vm="${PREFIJO_DOMINIO}-${CLUSTER_BASE}"
    local base_disco i host vm d comando_primero=""
    local -a extras=()
    base_disco="$(disco_base_cluster)"

    echo "→ MODO SIMULACIÓN (--dry-run): no se creará nada."
    echo
    echo "✔ Validaciones superadas."
    echo "    Usuario : $USUARIO"
    if [[ -n "$PREFIJO_OPT" ]]; then
        echo "    Prefijo : $PREFIJO_OPT (sustituye al usuario en los dominios y en los discos)"
    fi
    echo "    Red     : $NET_NAME (pasarela $NET_GATEWAY, prefijo /$NET_PREFIX)"
    echo "    Nodos   :"
    for i in "${!CLUSTER_NODOS[@]}"; do
        echo "      ${PREFIJO_DOMINIO}-${CLUSTER_NODOS[$i]}  →  ${CLUSTER_IPS[$i]}"
    done
    echo "    Recursos: ${RAM_MB} MB y ${VCPUS} vCPU por máquina"
    avisar_imagen_falta
    echo

    if [[ -n "$BASE_OPT" ]]; then
        echo "Fase 1: se omite. Los nodos partirán de la imagen que ya existe: $(basename "$base_disco")"
    else
        echo "Fase 1: base GlusterFS"
        echo "    Máquina $base_vm con disco $(basename "$base_disco") (COW de $(basename "$BASE_IMG"), $TAM_DISCO)."
        echo "    Instala glusterfs-server (y las herramientas para formatear en xfs), habilita glusterd, vacía el machine-id."
        echo "    Al terminar se apaga y se elimina el dominio; el disco se conserva como respaldo."
        generar_cloudinit "$base_vm" "$CLUSTER_BASE" "" gluster
        construir_comando "$base_vm" "$RAM_MB" "$VCPUS" "$base_disco"
        echo "    Ficheros cloud-init en $WORKDIR/"
        echo "    Comando:"
        imprimir_comando | sed 's/^/    /'
    fi
    echo

    echo "Fase 2: ${#CLUSTER_NODOS[@]} nodos, cada uno con ${#UNIDADES_CLUSTER[@]} discos extra de ${TAM_DISCO_EXTRA}"
    echo "    ${UNIDADES_CLUSTER[0]}, ${UNIDADES_CLUSTER[1]} y ${UNIDADES_CLUSTER[2]} en xfs, montados en ${CLUSTER_MONTAJES[*]}; el resto sin formatear."
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${PREFIJO_DOMINIO}-${host}"
        generar_cloudinit "$vm" "$host" "${CLUSTER_IPS[$i]}" nodo
        echo "    $vm: disco ${PREFIJO_FICHERO}${host}.qcow2 (COW de $(basename "$base_disco")), IP ${CLUSTER_IPS[$i]}, cloud-init en $WORKDIR/"
        if (( i == 0 )); then
            extras=()
            while IFS= read -r d; do extras+=( "$d" ); done < <(discos_extra_nodo "$host")
            construir_comando "$vm" "$RAM_MB" "$VCPUS" "${SILO_DIR}/${PREFIJO_FICHERO}${host}.qcow2" "${extras[@]}"
            comando_primero="$(imprimir_comando)"
        fi
    done
    echo
    echo "    Comando del primer nodo (los demás son iguales, con su nombre, IP y discos):"
    sed 's/^/    /' <<< "$comando_primero"
    echo
    echo "No se ha creado ni modificado ninguna máquina, disco ni red."
}

print_summary_cluster() {
    local i host vm ip base_disco
    base_disco="$(disco_base_cluster)"
    echo "-------------------------------------------"
    echo "Infraestructura GlusterFS creada (boletín 2, epígrafe 2.4)"
    echo
    echo "Red          : $NET_NAME"
    echo "Nodos        :"
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${PREFIJO_DOMINIO}-${host}"
        ip="${IPS_DETECTADAS[$vm]:-${CLUSTER_IPS[$i]}}"
        printf '  %-28s %-16s hostname %s\n' "$vm" "$ip" "$host"
    done
    echo "RAM / vCPUs  : ${RAM_MB} MB / ${VCPUS} por nodo"
    echo "Discos       : ${UNIDADES_CLUSTER[0]}..${UNIDADES_CLUSTER[-1]} (${#UNIDADES_CLUSTER[@]} × ${TAM_DISCO_EXTRA}) en cada nodo"
    echo "               ${UNIDADES_CLUSTER[0]}, ${UNIDADES_CLUSTER[1]} y ${UNIDADES_CLUSTER[2]} en xfs, montados en ${CLUSTER_MONTAJES[*]}"
    echo "GlusterFS    : glusterfs-server instalado y glusterd habilitado en todos"
    echo "/etc/hosts   : con los ${#CLUSTER_NODOS[@]} nombres, en todos"
    echo
    echo "Acceso (igual en todos los nodos, con la IP de cada uno):"
    vm="${PREFIJO_DOMINIO}-${CLUSTER_NODOS[0]}"
    bloque_acceso "$vm" "${IPS_DETECTADAS[$vm]:-${CLUSTER_IPS[0]}}"
    echo
    echo "IMPORTANTE: no borres $base_disco."
    echo "            Los discos de los ${#CLUSTER_NODOS[@]} nodos dependen de él."
    echo
    echo "Para eliminar la infraestructura entera (nodos${BASE_OPT:+ }${BASE_OPT:-e imagen base}):"
    echo "  $0 ${PREFIJO_OPT:+--prefijo $PREFIJO_OPT }--eliminar ${CLUSTER_NODOS[*]}${BASE_OPT:+}${BASE_OPT:- $CLUSTER_BASE}"
    echo "-------------------------------------------"
}

ejecutar_cluster() {
    local base_vm="${PREFIJO_DOMINIO}-${CLUSTER_BASE}"
    local base_disco i host vm ip disco d
    local -a extras nodos_vm=()
    base_disco="$(disco_base_cluster)"

    comprobar_conflictos

    if $DRY_RUN; then
        mostrar_plan_cluster
        return 0
    fi

    ########################################
    # Fase 1: base
    ########################################
    if [[ -n "$BASE_OPT" ]]; then
        echo "═══ Fase 1 de 2: se omite; los nodos parten de $(basename "$base_disco") ═══"
    else
        echo "═══ Fase 1 de 2: base GlusterFS ($base_vm) ═══"
        crear_base_gluster "$base_vm" "$CLUSTER_BASE" "$base_disco"
    fi
    echo

    ########################################
    # Fase 2: nodos
    ########################################
    echo "═══ Fase 2 de 2: ${#CLUSTER_NODOS[@]} nodos ═══"
    for i in "${!CLUSTER_NODOS[@]}"; do
        host="${CLUSTER_NODOS[$i]}"
        vm="${PREFIJO_DOMINIO}-${host}"
        ip="${CLUSTER_IPS[$i]}"
        disco="${SILO_DIR}/${PREFIJO_FICHERO}${host}.qcow2"
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
