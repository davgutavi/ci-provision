#!/bin/bash

########################################
# Validaciones generales (entorno, disco, red, opciones)
########################################
validate_environment() {

    # Silo existente
    if [[ ! -d "$SILO_DIR" ]]; then
        error 30 "No existe el silo en: $SILO_DIR"
    fi

    # Imagen base existente
    if [[ ! -f "$BASE_IMG" ]]; then
        error 37 "No se encuentra la imagen base '$BASE_IMG'.
Descárgala y guárdala como debian12.qcow2 en el silo."
    fi

    # Clave pública existente
    if [[ ! -f "$PUBKEY_PATH" ]]; then
        error 31 "No existe la clave pública en $PUBKEY_PATH. Genera una con: ssh-keygen"
    fi

    # Disco en silo (resolver ruta)
    if [[ "$DISK_ARG" = /* ]]; then
        DISK_PATH="$DISK_ARG"
    else
        DISK_PATH="$SILO_DIR/$DISK_ARG"
    fi

    if [[ ! -f "$DISK_PATH" ]]; then
        error 32 "El disco no existe: $DISK_PATH"
    fi

    case "$DISK_PATH" in
        "$SILO_DIR"/*) ;;
        *)
            error 33 "El disco debe estar dentro del silo: $SILO_DIR"
            ;;
    esac

    # Comprobar qcow2, backing file, backing format y disco reutilizado
    local TMP_LOG
    TMP_LOG="$(mktemp /tmp/ci-provision-qemu-img.XXXXXX)"

    if ! qemu-img info "$DISK_PATH" &>"$TMP_LOG"; then
        rm -f "$TMP_LOG"
        error 34 "No se ha podido obtener información con 'qemu-img info' sobre $DISK_PATH"
    fi

    # Formato de fichero
    local FILE_FMT
    FILE_FMT="$(grep -E '^file format:' "$TMP_LOG" | awk '{print $3}')"
    if [[ "$FILE_FMT" != "qcow2" ]]; then
        rm -f "$TMP_LOG"
        error 34 "El disco $DISK_PATH no es qcow2 (file format: $FILE_FMT)."
    fi

    # Backing file y formato
    local BACKING_LINE BACKING_FMT BACKING_NAME
    BACKING_LINE="$(grep -E '^backing file:' "$TMP_LOG" || true)"

    if [[ -z "$BACKING_LINE" ]]; then
        rm -f "$TMP_LOG"
        error 34 "El disco $DISK_PATH no parece ser una copia COW (no tiene 'backing file')."
    fi

    BACKING_FMT="$(grep -E '^backing file format:' "$TMP_LOG" | awk '{print $4}')"
    if [[ "$BACKING_FMT" != "qcow2" ]]; then
        rm -f "$TMP_LOG"
        error 34 "El disco $DISK_PATH no parece una copia COW de otra imagen qcow2 (backing file format: $BACKING_FMT)."
    fi

    # Extraer solo el nombre base del backing file, sin '(actual path: …)'
    BACKING_NAME="$(echo "$BACKING_LINE" | sed 's/^backing file: //; s/ (actual path: .*//')"

    if [[ "$BACKING_NAME" != "$(basename "$BASE_IMG")" ]]; then
        rm -f "$TMP_LOG"
        error 35 "El disco $DISK_PATH no está haciendo COW sobre $(basename "$BASE_IMG").
Backing actual: $BACKING_NAME
Esperado: $(basename "$BASE_IMG")

Vuelve a crear el disco con:
  qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 NOMBRE.qcow2 40G"
    fi

    # Comprobación de disco reutilizado (disk size)
    local DISK_SIZE_LINE SIZE_NUM SIZE_UNIT SIZE_KIB
    DISK_SIZE_LINE="$(grep -E '^disk size:' "$TMP_LOG" | sed 's/\r//')"
    SIZE_NUM="$(echo "$DISK_SIZE_LINE" | awk '{print $3}')"
    SIZE_UNIT="$(echo "$DISK_SIZE_LINE" | awk '{print $4}')"

    SIZE_KIB=0
    case "$SIZE_UNIT" in
        KiB)
            SIZE_KIB="${SIZE_NUM%.*}"
            ;;
        MiB)
            SIZE_KIB=$(printf "%.0f" "$(echo "$SIZE_NUM * 1024" | bc -l)")
            ;;
        GiB)
            SIZE_KIB=$(printf "%.0f" "$(echo "$SIZE_NUM * 1024 * 1024" | bc -l)")
            ;;
        *)
            SIZE_KIB=0
            ;;
    esac

    if (( SIZE_KIB > DISK_REUSE_MAX_KIB )); then
        rm -f "$TMP_LOG"
        error 36 "El disco $DISK_PATH parece reutilizado: su 'disk size' es mayor de 1 MiB.
Línea de 'disk size' actual:
  $DISK_SIZE_LINE

Crea un disco nuevo con:
  qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 NOMBRE.qcow2 40G"
    fi

    rm -f "$TMP_LOG"

    # Red existente
    if ! virsh net-info "$NET_NAME" &>/dev/null; then
        error 40 "La red '$NET_NAME' no existe."
    fi

    # Validación básica de IP y rango DHCP si se especifica IP estática
    if [[ -n "$IP" ]]; then
        if ! [[ "$IP" =~ ^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            error 41 "La IP '$IP' no es válida. Debe ser del tipo 192.168.XXX.YYY."
        fi

        local OCT3 OCT4
        OCT3="$(echo "$IP" | awk -F. '{print $3}')"
        OCT4="$(echo "$IP" | awk -F. '{print $4}')"

        # Rango DHCP configurado: 128–254 → no se permite en IP fija
        if (( OCT4 >= 128 && OCT4 <= 254 )); then
            error 42 "La IP '$IP' está en el rango DHCP (128–254). Usa una IP fija fuera de ese rango."
        fi
    fi

    # VALIDACIÓN LÓGICA: virt-viewer requiere contraseña de admin o root habilitado
    if $ENABLE_GRAPHICS; then
        if [[ -z "$USER_PASS" && $ENABLE_ROOT = false ]]; then
            error 50 "Para usar --virt-viewer debes habilitar acceso por consola.
Usa al menos una de estas opciones:
  --user-pass PASSWORD
  --enable-root"
        fi
    fi

    # Pre-check de discos extra: si se van a crear, comprobar que no existan
    if $EXTRA_DISKS; then
        local maquina
        maquina="${VM_NAME#*-}"
        for unidad in vdb vdc vdd vde vdf vdg; do
            local ruta_extra="${SILO_DIR}/${maquina}-${unidad}.qcow2"
            if [[ -e "$ruta_extra" ]]; then
                error 60 "El disco extra '$ruta_extra' ya existe. Elimínalo o usa otro nombre de dominio."
            fi
        done
    fi
}