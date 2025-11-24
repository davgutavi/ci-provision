
cd imagenesMV

# Test 1.1 -> OK

qemu-img create test11.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh davgutavi-test11 test11.qcow2 test11 davgutavi-red
# 	•	Verificar:
# 	•	El script no muestra errores.
# 	•	Se genera el directorio cloudinit-usuario-server1 con:
# 	•	cip-user.yaml
# 	•	cip-meta.yaml
# 	•	sin cip-net.yaml (porque no hemos dado IP).
ls 
ls cloudinit-davgutavi-test11
cat cloudinit-davgutavi-test11/cip-meta.yaml
cat cloudinit-davgutavi-test11/cip-user.yaml
# 	•	La VM aparece en virsh list --all.
virsh list --all | grep davgutavi-test11
# 	•	La VM obtiene IP vía DHCP.
virsh domifaddr davgutavi-test11 --source lease
# 	•	Se puede acceder por SSH como administrador usando la clave pública ~/.ssh/id_rsa.pub.
ssh administrador@192.168.2.176
# 	•	No hay contraseña para administrador (solo clave).
sudo apt update
virsh shutdown davgutavi-test11

# Test 1.2 -> OK
qemu-img create test12.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh davgutavi-test12 test12.qcow2 test12 davgutavi-red 192.168.2.20 
# 	•	Verificar:
# 	•	El script no muestra errores.
# 	•	Se genera el directorio cloudinit-usuario-server1 con:
# 	•	cip-user.yaml
# 	•	cip-meta.yaml
# 	•	sin cip-net.yaml (porque no hemos dado IP).
ls 
ls cloudinit-davgutavi-test12
cat cloudinit-davgutavi-test12/cip-meta.yaml
cat cloudinit-davgutavi-test12/cip-user.yaml
cat cloudinit-davgutavi-test12/cip-net.yaml
# 	•	La VM aparece en virsh list --all.
virsh list --all | grep davgutavi-test12
# 	•	La VM obtiene IP vía DHCP.
virsh domifaddr davgutavi-test12 --source arp
# 	•	Se puede acceder por SSH como administrador usando la clave pública ~/.ssh/id_rsa.pub.
ssh administrador@192.168.2.20
# 	•	No hay contraseña para administrador (solo clave).
sudo apt update
ip addr show
virsh shutdown davgutavi-test12

# Test 1.3 -> OK
qemu-img create test13.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh davgutavi-test13 test13.qcow2 test13 davgutavi-red 192.168.2.30 4096 4
# 	•	Verificar:
# 	•	El script no muestra errores.
# 	•	Se genera el directorio cloudinit-usuario-server1 con:
# 	•	cip-user.yaml
# 	•	cip-meta.yaml
# 	•	sin cip-net.yaml (porque no hemos dado IP).
ls 
ls cloudinit-davgutavi-test13
cat cloudinit-davgutavi-test13/cip-meta.yaml
cat cloudinit-davgutavi-test13/cip-user.yaml
cat cloudinit-davgutavi-test13/cip-net.yaml
# 	•	La VM aparece en virsh list --all.
virsh list --all | grep davgutavi-test13
# 	•	La VM obtiene IP vía DHCP.
virsh domifaddr davgutavi-test13 --source arp
# 	•	Se puede acceder por SSH como administrador usando la clave pública ~/.ssh/id_rsa.pub.
ssh administrador@192.168.2.30
# 	•	No hay contraseña para administrador (solo clave).
sudo apt update
virsh dominfo davgutavi-test13
virsh shutdown davgutavi-test13

# Test 1.4 -> OK
qemu-img create test14.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh --user-pass test davgutavi-test14 test14.qcow2 test14 davgutavi-red 

# 	•	Verificar:
ls 
ls cloudinit-davgutavi-test14
cat cloudinit-davgutavi-test14/cip-meta.yaml
cat cloudinit-davgutavi-test14/cip-user.yaml
cat cloudinit-davgutavi-test14/cip-net.yaml
virsh list --all | grep davgutavi-test14
virsh domifaddr davgutavi-test14 --source lease
ssh administrador@192.168.2.180
sudo apt update
ip addr show
virsh shutdown davgutavi-test12


# Test 1.5 -> OK
qemu-img create test15.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh --enable-root davgutavi-test15 test15.qcow2 test15 davgutavi-red 

# 	•	Verificar:

virsh domifaddr davgutavi-test15 --source lease
ssh administrador@192.168.2.204
sudo apt update
ssh root@192.168.2.204
# root@192.168.2.204: Permission denied (publickey).
virsh shutdown davgutavi-test15


# Test 1.1 -> OK
qemu-img create test16.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh --enable-root --user-pass test \
    davgutavi-test16 test16.qcow2 test16 davgutavi-red 192.168.2.40 1024 1
virsh domifaddr davgutavi-test15 --source lease
ssh administrador@192.168.2.204


# Test 2.1 -> ERROR disco no existe

qemu-img create -f qcow2 /tmp/err.qcow2 5G
./ci-provision.sh davgutavi-test21 /tmp/err.qcow2 test21 davgutavi-red

# Test 2.2 -> ERROR disco no existe
./ci-provision.sh davgutavi-test22 error.qcow2 test22 davgutavi-red

# Test 2.3. Disco sin qcow2
touch ~/imagenesMV/a.raw
./ci-provision.sh davgutavi-test23 ~/imagenesMV/a.raw test23 davgutavi-red


# 2.4. Disco qcow2 sin backing file debian12.qcow2
qemu-img create -f qcow2 ~/imagenesMV/vacio.qcow2 4G
./ci-provision.sh davgutavi-test24 ~/imagenesMV/vacio.qcow2 test24 davgutavi-red

# 2.5. Red inexistente
qemu-img create test25.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh davgutavi-test25 test25.qcow2 test25 davgutavi-fake

# 2.6. Falta de clave pública
mv ~/.ssh/id_rsa.pub ~/.ssh/id_rsa.pub.bak
qemu-img create test26.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh davgutavi-test26 test26.qcow2 test26 davgutavi-red
mv ~/.ssh/id_rsa.pub.bak ~/.ssh/id_rsa.pub  

# 2.7. Parámetros insuficientes
qemu-img create test27.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh davgutavi-test27 test27.qcow2 davgutavi-red

# 2.8. --user-pass sin contraseña
qemu-img create test28.qcow2 -f qcow2 -b debian12.qcow2 -F qcow2 40G
./ci-provision.sh --user-pass "" davgutavi-test28 test28.qcow2 test28 davgutavi-red
ERROR: Número incorrecto de parámetros
Use --help para más info







