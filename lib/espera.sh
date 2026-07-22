########################################
# Espera activa a que cloud-init termine
#
# El script instala qemu-guest-agent con cloud-init y lo arranca al final de
# 'runcmd'. Por lo tanto, que el agente conteste implica que la instalación de
# paquetes ha terminado y que el resto de runcmd ya se ha ejecutado: es una
# señal fiable de que la máquina está realmente operativa, y bastante mejor
# que una espera de duración fija.
########################################

# Devuelve por stdout la primera IPv4 no local que reporte el guest agent.
# Cadena vacía si el agente no responde todavía.
obtener_ip_agente() {
    local vm="$1"
    virsh domifaddr "$vm" --source agent 2>/dev/null \
        | awk '$3 == "ipv4" && $4 !~ /^127\./ { split($4, a, "/"); print a[1]; exit }'
}

# ¿Está la máquina lista? Si se pidió IP fija, se exige esa IP concreta.
# Deja la IP detectada en VM_IP.
maquina_lista() {
    local vm="$1" ip
    ip="$(obtener_ip_agente "$vm")"

    if [[ -z "$ip" ]]; then
        return 1
    fi

    if [[ -n "$IP" && "$ip" != "$IP" ]]; then
        return 1
    fi

    VM_IP="$ip"
    return 0
}

# Espera hasta que la máquina esté operativa o se agote WAIT_TIMEOUT.
# Devuelve 0 si está lista, 1 si se agotó el tiempo.
esperar_maquina() {
    local vm="$1"
    local inicio transcurrido
    inicio=$SECONDS

    echo "Esperando a que cloud-init termine de configurar la máquina."
    echo "Se están instalando paquetes: puede tardar entre uno y tres minutos."

    while true; do
        if maquina_lista "$vm"; then
            transcurrido=$(( SECONDS - inicio ))
            if [[ -t 1 ]]; then
                printf '\r\033[K'
            fi
            echo "✔ Máquina operativa tras ${transcurrido}s. IP: ${VM_IP}"
            # Margen para las últimas órdenes de runcmd, que son instantáneas.
            sleep "$GRACE_SECS"
            return 0
        fi

        transcurrido=$(( SECONDS - inicio ))

        if (( transcurrido >= WAIT_TIMEOUT )); then
            if [[ -t 1 ]]; then
                printf '\r\033[K'
            fi
            echo "AVISO: la máquina no ha respondido en ${WAIT_TIMEOUT}s." >&2
            echo "       Puede que siga instalando paquetes. Comprueba su estado con:" >&2
            echo "         virsh domifaddr $vm --source agent" >&2
            echo "       Si no responde, entra por consola con: virsh console $vm" >&2
            return 1
        fi

        if [[ -t 1 ]]; then
            printf '\r  ... %ss' "$transcurrido"
        fi

        sleep "$POLL_SECS"
    done
}
