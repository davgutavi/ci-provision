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
EXIGIR_ESTADO_CI=false         # true: no vale asumir; hace falta leer el estado de cloud-init (la base GlusterFS)
declare -A IP_VISTA=()         # dominio → última IP que ha reportado el agente, esté lista o no

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
#
# Desde cloud-init 23.4 (Ubuntu 24.04), 'cloud-init status' escribe "done"
# aunque haya terminado con avisos; lo que lo distingue es el código de salida:
# 0 bien, 1 error, 2 terminado con avisos ("degraded"). Por eso se mira también.
cloudinit_status() {
    local vm="$1" r pid s exited datos i estado codigo

    r="$(virsh qemu-agent-command "$vm" --timeout 5 \
          '{"execute":"guest-exec","arguments":{"path":"/usr/bin/cloud-init","arg":["status"],"capture-output":true}}' \
          2>/dev/null || true)"
    pid="$(jq -r '.return.pid // empty' <<< "$r" 2>/dev/null || true)"

    if [[ -z "$pid" ]]; then
        return 1
    fi

    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        s="$(virsh qemu-agent-command "$vm" --timeout 5 \
              "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}" \
              2>/dev/null || true)"
        exited="$(jq -r '.return.exited // empty' <<< "$s" 2>/dev/null || true)"
        if [[ "$exited" == "true" ]]; then
            datos="$( { jq -r '.return."out-data" // empty' <<< "$s" | base64 -d; } 2>/dev/null || true)"
            codigo="$(jq -r '.return.exitcode // empty' <<< "$s" 2>/dev/null || true)"
            estado="$(awk '/^status:/ { sub(/^status: */, ""); print; exit }' <<< "$datos")"
            if [[ "$estado" == "done" && "$codigo" == "2" ]]; then
                estado="degraded done"
            fi
            printf '%s\n' "$estado"
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
    IP_VISTA[$vm]="$ip"

    # Si se pidió IP fija, se exige esa IP concreta
    if [[ -n "${IP_ESPERADA[$vm]:-}" && "$ip" != "${IP_ESPERADA[$vm]}" ]]; then
        return 1
    fi

    if estado="$(cloudinit_status "$vm")"; then
        FALLOS_CONSULTA[$vm]=0
        unset 'ASUMIDO_DESDE[$vm]'
        case "$estado" in
            done)
                IPS_DETECTADAS[$vm]="$ip"
                ESTADO_CI[$vm]="done"
                return 0
                ;;
            error|"degraded done")
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

    if (( n >= 3 )) && ! $EXIGIR_ESTADO_CI; then
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
                if [[ -n "${IP_VISTA[$vm]:-}" ]]; then
                    if [[ -n "${IP_ESPERADA[$vm]:-}" && "${IP_VISTA[$vm]}" != "${IP_ESPERADA[$vm]}" ]]; then
                        echo "         ($vm responde en ${IP_VISTA[$vm]} y no en la IP fija ${IP_ESPERADA[$vm]}: la configuración de red no se ha aplicado)" >&2
                    else
                        echo "         ($vm ya responde en ${IP_VISTA[$vm]}; cloud-init sigue trabajando)" >&2
                    fi
                fi
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
    virsh shutdown "$1" >/dev/null 2>&1 || true
    esperar_apagada "$1"
}

# Espera a que una máquina esté parada (a quien ya se le ha pedido apagarse)
esperar_apagada() {
    local vm="$1" inicio=$SECONDS estado
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
# Reinicio en frío al terminar
#
# Con --cloud-init, virt-install arranca la máquina con una definición "de
# instalación" que tiene on_reboot=destroy: cuenta con estar él presente en el
# primer reinicio para volver a arrancarla con la definición definitiva
# (on_reboot=restart). Como el script lo lanza con --noautoconsole, termina
# enseguida y nadie hace ese segundo arranque: el primer 'reboot' dentro de la
# máquina la apagaría. Y una instantánea tomada en caliente guardaría ese
# on_reboot=destroy, así que el problema volvería al revertirla.
#
# Apagándola y arrancándola desde fuera, pasa a ejecutarse con la definición
# persistente, que es la buena. Solo se hace cuando cloud-init ya ha terminado:
# antes lo interrumpiría.
########################################

# on_reboot de la definición con la que se está ejecutando la máquina
on_reboot_vivo() {   # DOMINIO
    local xml
    xml="$(virsh dumpxml "$1" 2>/dev/null || true)"
    sed -n 's:.*<on_reboot>\([a-z-]*\)</on_reboot>.*:\1:p' <<< "$xml"
}

# Aviso para cuando no se ha podido (o no se debía) reiniciar
aviso_on_reboot() {   # DOMINIO...
    echo "AVISO: tras crearlas, estas máquinas se apagan en su primer reinicio: $*" >&2
    echo "       Cuando terminen de configurarse, apágalas y arráncalas desde fuera:" >&2
    echo "         virsh shutdown NOMBRE   (y, cuando esté apagada)   virsh start NOMBRE" >&2
    echo "       Hazlo antes de tomar instantáneas." >&2
}

reiniciar_en_frio() {   # DOMINIO...
    local vm ip inicio
    local -a arrancadas=() fallidas=() pendientes restantes

    echo "→ Apagando y volviendo a arrancar ${#@} máquina(s), para que usen su configuración definitiva…"
    for vm in "$@"; do
        virsh shutdown "$vm" >/dev/null 2>&1 || true
    done
    for vm in "$@"; do
        if esperar_apagada "$vm" && virsh start "$vm" >/dev/null 2>&1; then
            arrancadas+=( "$vm" )
        else
            fallidas+=( "$vm" )
        fi
    done

    # Que vuelvan a responder (con su IP fija, si la tienen)
    inicio=$SECONDS
    pendientes=( ${arrancadas[@]+"${arrancadas[@]}"} )
    while (( ${#pendientes[@]} > 0 )); do
        restantes=()
        for vm in "${pendientes[@]}"; do
            ip="$(obtener_ip_agente "$vm")"
            if [[ -n "$ip" && ( -z "${IP_ESPERADA[$vm]:-}" || "$ip" == "${IP_ESPERADA[$vm]}" ) ]]; then
                IPS_DETECTADAS[$vm]="$ip"
            else
                restantes+=( "$vm" )
            fi
        done
        pendientes=( ${restantes[@]+"${restantes[@]}"} )
        if (( ${#pendientes[@]} == 0 )); then break; fi
        if (( SECONDS - inicio >= WAIT_TIMEOUT )); then
            echo "AVISO: no han vuelto a responder en ${WAIT_TIMEOUT}s: ${pendientes[*]}" >&2
            echo "       Comprueba su estado con: virsh list --all" >&2
            break
        fi
        sleep "$POLL_SECS"
    done

    for vm in ${arrancadas[@]+"${arrancadas[@]}"}; do
        if [[ "$(on_reboot_vivo "$vm")" == "restart" ]]; then
            echo "✔ $vm reiniciada: ya puedes reiniciarla desde dentro y tomar instantáneas."
        else
            fallidas+=( "$vm" )
        fi
    done
    if (( ${#fallidas[@]} > 0 )); then
        aviso_on_reboot "${fallidas[@]}"
    fi
}
