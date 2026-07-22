#!/bin/bash
# Fase A: pruebas de validación de ci-provision.sh en el servidor.
# NO crea máquinas ni discos: todos los casos deben terminar en error.
# Uso:  bash pruebas-fase-a.sh [ruta-al-script]   (por defecto ./ci-provision.sh)

SCRIPT="${1:-./ci-provision.sh}"
SILO="$HOME/imagenesMV"
RED="${RED:-$(id -un)-red}"     # exporta RED=otra-red si tu red se llama distinto
DISCO="${DISCO:-prueba-fase-a.qcow2}"
FALLOS=0

if [[ ! -x "$SCRIPT" && ! -f "$SCRIPT" ]]; then
    echo "No encuentro $SCRIPT"; exit 1
fi

# Disco COW limpio para las pruebas que deben llegar más allá de la fase de disco
cd "$SILO" || { echo "No existe el silo $SILO"; exit 1; }
if [[ ! -f "$DISCO" ]]; then
    qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 "$DISCO" 40G >/dev/null || exit 1
    CREADO=1
fi

caso() {
    local esperado="$1"; shift
    local desc="$1"; shift
    local salida rc
    salida="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    if [[ "$rc" == "$esperado" ]]; then
        printf '  \033[32m✔\033[0m [%s] %s\n' "$rc" "$desc"
    else
        printf '  \033[31m✘\033[0m %s → esperaba %s, obtuve %s\n' "$desc" "$esperado" "$rc"
        echo "$salida" | head -6 | sed 's/^/       | /'
        FALLOS=$(( FALLOS + 1 ))
    fi
}

ver() {   # muestra la salida completa de un caso, para revisar el mensaje
    echo
    echo "--- $1 ---"; shift
    bash "$SCRIPT" "$@" 2>&1 | sed 's/^/  /'
}

echo "Script : $SCRIPT"
echo "Silo   : $SILO"
echo "Red    : $RED"
echo "Disco  : $DISCO"
echo

echo "=== Parámetros y nombre de dominio ==="
caso 0  "ayuda con -h"                          -h
caso 10 "faltan parámetros"                     solo-uno
caso 12 "opción desconocida"                    --noexiste u-m "$DISCO" host "$RED"
caso 11 "--user-pass sin valor"                 --user-pass
caso 20 "nombre sin guión"                      miMvPruebas "$DISCO" host "$RED"
caso 20 "nombre con barra"                      ../fuera-x  "$DISCO" host "$RED"
caso 20 "nombre con espacio"                    "a b-c"     "$DISCO" host "$RED"

echo
echo "=== Disco ==="
caso 32 "disco inexistente"                     u-m noexiste.qcow2 host "$RED"
caso 33 "disco fuera del silo"                  u-m /etc/hostname  host "$RED"

echo
echo "=== Red e IP (con tu red '$RED') ==="
caso 40 "red inexistente"                       u-m "$DISCO" host red-que-no-existe-xyz
caso 41 "IP con octeto > 255"                   u-m "$DISCO" host "$RED" 192.168.1.999
caso 41 "IP que no es una IP"                   u-m "$DISCO" host "$RED" hola

echo
echo "=== Opciones ==="
caso 50 "--virt-viewer sin acceso por consola"  --virt-viewer u-m "$DISCO" host "$RED"

echo
echo "=================================================================="
echo " Revisa a mano los mensajes de abajo: deben ser claros y citar"
echo " la pasarela real y las IPs libres de TU red."
echo "=================================================================="

# Sustituye las IPs por unas de tu red real antes de ejecutar estas tres
GW="$(virsh net-dumpxml "$RED" | sed -n "s/.*<ip address='\([^']*\)'.*/\1/p" | head -1)"
BASE3="${GW%.*}"
ver "IP dentro del rango DHCP"   u-m "$DISCO" host "$RED" "${BASE3}.200"
ver "IP que es la pasarela"      u-m "$DISCO" host "$RED" "$GW"
ver "IP de otra subred"          u-m "$DISCO" host "$RED" 10.9.9.9

echo
echo "=== Redes reales con topología no estándar (solo si están en este servidor) ==="
for r in corchu-nat default; do
    if virsh net-info "$r" >/dev/null 2>&1; then
        ver "IP .2 en la red '$r'" u-m "$DISCO" host "$r" "$(virsh net-dumpxml "$r" | sed -n "s/.*<ip address='\([^']*\)'.*/\1/p" | head -1 | sed 's/\.[0-9]*$/.2/')"
    fi
done

echo
[[ -n "${CREADO:-}" ]] && rm -f "$SILO/$DISCO" && echo "(disco de prueba eliminado)"
if (( FALLOS == 0 )); then echo "FASE A: TODOS LOS CASOS OK"; else echo "FASE A: $FALLOS CASOS FALLIDOS"; fi
