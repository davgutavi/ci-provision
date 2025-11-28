########################################
# Adjuntar discos extra vdb..vdg
########################################
attach_extra_disks() {
    local dominio="$1"
    local maquina="${dominio#*-}"

    echo "Añadiendo discos extra al dominio: $dominio"
    echo "Prefijo: $maquina"
    echo "Silo: $SILO_DIR"
    echo

    for unidad in vdb vdc vdd vde vdf vdg; do
        local nombre_img="${maquina}-${unidad}.qcow2"
        local ruta_img="${SILO_DIR}/${nombre_img}"

        echo "→ Creando: $ruta_img"
        qemu-img create "$ruta_img" -f qcow2 40G

        echo "→ Adjuntando como $unidad"
        virsh attach-disk "$dominio" "$ruta_img" "$unidad" \
            --driver qemu --subdriver qcow2 --targetbus virtio \
            --persistent --live
        echo "Disk attached successfully"
        echo
    done

    echo "✔ Discos extra añadidos correctamente."
    echo
}