# 🚀 ci-provision
### Script para crear máquinas virtuales con cloud-init  
**Asignatura: Sistemas Operativos — Universidad de Sevilla**

---

# 1. 🧠 ¿Qué hace este script?

`ci-provision.sh` automatiza la **creación completa de máquinas virtuales** basadas en **Debian 12 cloud**, usando `virt-install` y `cloud-init`.

El script permite:

### ✔ Configuración principal
- Crear una VM con nombre, disco, red virtual, RAM y vCPUs.
- Configurar la clave pública SSH del usuario `administrador`.
- Configurar red (DHCP o IP estática).
- Generar automáticamente los ficheros cloud-init necesarios.

### ✔ Funcionalidades opcionales
- `--user-pass`: añade contraseña al administrador.
- `--enable-root`: habilita root **solo por consola**.
- `--virt-viewer`: habilita consola gráfica.
- `--extra-disks`: crea y conecta discos vdb..vdg.
- `--glusterfs`: instala glusterfs-server, habilita glusterd y resetea `/etc/machine-id`.


---

# 2. 📌 Requisitos previos

## **1. Tener el silo creado**
Debe estar configurado en el trayecto:

```
$HOME/imagenesMV/
```

## **2. Tener una red virtual creada**
```bash
virsh net-list
```

## **3. Imagen cloud de Debian 12**

Debe estar ubicada en el silo y llamarse **debian12.qcow2**:

```
$HOME/imagenesMV/debian12.qcow2
```

### Para obtenerla:

**wget:**
```bash
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 \
     -O $HOME/imagenesMV/debian12.qcow2
```

**curl:**
```bash
curl -L https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 \
     -o $HOME/imagenesMV/debian12.qcow2
```

## **4. Crear el disco qcow2 para tu VM**
Debe ser **una copia COW** de **debian12.qcow2** y estar ubicada en el silo, por ejemplo:

```bash
qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 server1.qcow2 40G
```

---

# 3. 📥 Instalación del script

Siempre desde el silo:

```bash
cd $HOME/imagenesMV/
```

### Descargar

**wget:**
```bash
wget https://raw.githubusercontent.com/davgutavi/ci-provision/main/ci-provision.sh \
     -O ci-provision.sh
```

**curl:**
```bash
curl -L https://raw.githubusercontent.com/davgutavi/ci-provision/main/ci-provision.sh \
     -o ci-provision.sh
```

### Permisos
```bash
chmod u+x ci-provision.sh
```

### Verificación
```bash
./ci-provision.sh -h
```

---

# 4. ⚙️ Funcionamiento

Ejecuta siempre desde tu silo:

```bash
./ci-provision.sh [opciones] NOMBRE_VM DISCO HOSTNAME RED [IP] [RAM_MB] [VCPUS]
```

### Parámetros principales

| Parámetro | Descripción |
|----------|-------------|
| `NOMBRE_VM` | Nombre del dominio libvirt |
| `DISCO` | Archivo qcow2 dentro del silo |
| `HOSTNAME` | Nombre del sistema |
| `RED` | Nombre de la red virtual |

### Opcionales

| Parámetro | Descripción | Por defecto |
|-----------|-------------|-------------|
| `IP` | IP fija | DHCP |
| `RAM_MB` | Memoria | 2048 |
| `VCPUS` | Núcleos | 2 |

### Opciones

| Opción | Descripción |
|--------|-------------|
| `--user-pass PASS` | Añade contraseña al administrador |
| `--enable-root` | Root solo por consola |
| `--virt-viewer` | Consola gráfica SPICE |
| `--extra-disks` | Añade discos vdb..vdg |
| `--glusterfs` | Configura nodo GlusterFS |
| `-h` | Ayuda |

---

# 📘 Notas sobre los ejemplos

- **usuario** = tu usuario en el servidor  
- **Alumno2025** = contraseña de ejemplo  
- **192.168.XXX.Y** = una IP de tu red virtual privada  
- **soserver** = avantasia / warcry / megadeth  

---

# 5. 🧪 Casos de uso típicos

---

## 🟦 **1️⃣ SERVER1 del Boletín 1**

### **Caso base: máquina básica con DHCP**

```bash
./ci-provision.sh usuario-server1 server1.qcow2 server1 usuario-red
```

### **Caso base + usuario root**

```bash
./ci-provision.sh --enable-root \
    usuario-server1 server1.qcow2 server1 usuario-red
```

### **Caso base + usuario root + virt-viewer**

```bash
./ci-provision.sh --enable-root --virt-viewer \
    usuario-server1 server1.qcow2 server1 usuario-red
```

### **Caso base + contraseña de usuario + virt-viewer**

```bash
./ci-provision.sh --user-pass Alumno2025 --virt-viewer \
    usuario-server1 server1.qcow2 server1 usuario-red
```

---

## 🟩 **2️⃣ SERVER1 del Boletín 2 — Epígrafe 2.1**

### **Caso base: máquina con IP fija, usuario root y discos extra**

```bash
./ci-provision.sh --enable-root --extra-disks \
    usuario-server1 server1.qcow2 server1 usuario-red 192.168.XXX.2
```

### **Caso base + virt-viewer**

```bash
./ci-provision.sh --enable-root --extra-disks --virt-viewer \
    usuario-server1 server1.qcow2 server1 usuario-red 192.168.XXX.2
```

---

## 🟥 **3️⃣ GLUSTER-BASE del Boletín 2 — Epígrafe 2.4**

### **Caso base: máquina con glusterfs-server y machine-id reseteado**

```bash
./ci-provision.sh --glusterfs \
    usuario-glusterbase gluster-base.qcow2 glusterbase usuario-red
```

### **Caso base + root**

```bash
./ci-provision.sh --glusterfs --enable-root \
    usuario-glusterbase gluster-base.qcow2 glusterbase usuario-red
```

### **Caso base + root + virt-viewer**

```bash
./ci-provision.sh --glusterfs --enable-root --virt-viewer \
    usuario-glusterbase gluster-base.qcow2 glusterbase usuario-red
```

---

# 6. 🔐 Accesos configurados

## Usuario `administrador`

| Acceso | Requisitos | Estado |
|--------|------------|--------|
| SSH por clave pública | Ninguno | ✔ Siempre |
| SSH por contraseña | `--user-pass` | ✔ |
| Consola virsh | Ninguno | ✔ |
| virt-viewer | `--virt-viewer` + (`--user-pass` o `--enable-root`) | ✔ |

### Ejemplos

```bash
ssh administrador@192.168.XXX.Y
virsh console usuario-server1
virt-viewer --connect qemu+ssh://usuario@soserver.lsi.us.es/system usuario-server1
```

---

## Usuario `root`

| Acceso | Requisitos | Estado |
|--------|------------|--------|
| SSH | – | ❌ Prohibido |
| Consola texto | `--enable-root` | ✔ |
| virt-viewer | `--enable-root` + `--virt-viewer` | ✔ |

---

# 7. 🧩 Archivos generados

```
cloudinit-NOMBRE_VM/
 ├── cip-user.yaml
 ├── cip-meta.yaml
 └── cip-net.yaml   (solo si hay IP estática)
```

---

# 8. 🧨 Códigos de error

| Código | Descripción | Solución |
|--------|-------------|-----------|
| **10** | Faltan parámetros obligatorios | Revisa el comando |
| **11** | Falta valor tras `--user-pass` | Añade contraseña |
| **12** | Opción desconocida | Consulta `-h` |
| **20** | Nombre inválido | Formato `usuario-maquina` |
| **21** | Dominio ya existe | `virsh destroy + undefine` |
| **30** | No existe el silo | Crear `$HOME/imagenesMV` |
| **31** | No existe la clave pública | `ssh-keygen` |
| **32** | No existe el qcow2 | Revisa nombre |
| **33** | qcow2 fuera del silo | Mover al silo |
| **34** | No es qcow2 o no es COW | Crear disco COW |
| **35** | Backing file incorrecto | Debe ser `debian12.qcow2` |
| **36** | Disco reutilizado (>1 MiB) | Crear disco nuevo |
| **40** | Red virtual no existe | Revisar `virsh net-list` |
| **41** | IP inválida | Debe ser `192.168.XXX.YYY` |
| **42** | IP en rango DHCP | Usar IP fuera de 128–254 |
| **50** | virt-viewer sin acceso válido | Añadir contraseña o root |
| **60** | Disco extra ya existe | Eliminar archivo o usar otro nombre |

---

# 9. 👨‍🏫 Autor

**David Gutiérrez Avilés**  
Profesor Titular de Universidad  
Departamento de Lenguajes y Sistemas Informáticos  
Universidad de Sevilla

Script utilizado en las prácticas de **Sistemas Operativos**.