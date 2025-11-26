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
- Configurar la red (DHCP o IP estática).
- Generar automáticamente los ficheros cloud-init necesarios.

### ✔ Funcionalidades opcionales
- `--user-pass`: añade contraseña al usuario administrador.
- `--enable-root`: habilita root **solo por consola**.
- `--virt-viewer`: habilita acceso gráfico mediante *virt-viewer*.
- `--extra-disks`: crea y conecta discos vdb..vdg.

### ✔ Operaciones automáticas dentro de la VM
En el primer arranque se realiza:

- Configuración de zona horaria  
- Actualización de índices de paquetes  
- Instalación y activación de `qemu-guest-agent`  

### ✔ Validaciones inteligentes
- Para usar `--virt-viewer`, debe activarse `--user-pass` **o** `--enable-root`.
- El disco debe estar dentro del silo.
- El nombre debe ser del tipo `usuario-nombre`.

---

# 2. 📌 Requisitos previos

## **1. Tener el silo creado**
Debe existir:

```
$HOME/imagenesMV/
```

## **2. Tener una red virtual creada**
```bash
virsh net-list
```

## **3. Imagen cloud de Debian 12**

Debe estar en:

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
```bash
qemu-img create -f qcow2 -b debian12.qcow2 -F qcow2 server1.qcow2 40G
```

---

# 3. 📥 Instalación del script

⚠️ Descarga siempre dentro del silo:

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

Ejecutar desde el silo:

```bash
./ci-provision.sh [opciones] NOMBRE_VM DISCO HOSTNAME RED [IP] [RAM_MB] [VCPUS]
```

### Parámetros principales

| Parámetro | Descripción |
|----------|-------------|
| `NOMBRE_VM` | Nombre de la VM |
| `DISCO` | Archivo qcow2 dentro del silo |
| `HOSTNAME` | Nombre interno |
| `RED` | Red virtual existente |

### Opcionales

| Parámetro | Descripción | Por defecto |
|-----------|-------------|-------------|
| `IP` | IP fija | DHCP |
| `RAM_MB` | Memoria | 2048 |
| `VCPUS` | Núcleos | 2 |

### Opciones

| Opción | Descripción |
|--------|-------------|
| `--user-pass PASS` | Contraseña para administrador |
| `--enable-root` | Habilita root solo por consola |
| `--virt-viewer` | Activa acceso gráfico mediante virt-viewer |
| `--extra-disks` | Añade discos vdb..vdg |
| `-h` | Ayuda |

---

## 📌 Ejemplos

Todos deben ejecutarse **desde el silo**:

### 1. VM con DHCP
```bash
./ci-provision.sh usuario-server1 server1.qcow2 server1 usuario-red
```

### 2. VM con IP estática
```bash
./ci-provision.sh usuario-server2 server2.qcow2 server2 usuario-red 192.168.2.20
```

### 3. Contraseña para administrador
```bash
./ci-provision.sh --user-pass 1234 usuario-server3 server3.qcow2 server3 usuario-red
```

### 4. Root habilitado SOLO por consola
```bash
./ci-provision.sh --enable-root usuario-server4 server4.qcow2 server4 usuario-red
```

---

## 🟩 **2️⃣ SERVER1 del Boletín 2 — Epígrafe 2.1**

### **Caso base** 
(IP fija + root + discos extra)
```bash
./ci-provision.sh --enable-root --extra-disks \
    usuario-server1 server1.qcow2 server1 usuario-red 192.168.XXX.2
```

### **Caso base con root + discos extra + virt-viewer**
```bash
./ci-provision.sh --enable-root --extra-disks --virt-viewer \
    usuario-server1 server1.qcow2 server1 usuario-red 192.168.XXX.2
```

### **Caso base con contraseña de usuario + discos extra + virt-viewer**
```bash
./ci-provision.sh --user-pass Alumno2025 --extra-disks --virt-viewer \
    usuario-server1 server1.qcow2 server1 usuario-red 192.168.XXX.2
```

---

# 6. 🔐 Accesos configurados

## Usuario `administrador`

| Acceso | Requisitos | Estado |
|--------|------------|--------|
| SSH por clave pública | Ninguno | ✔ Siempre |
| SSH por contraseña | `--user-pass` | ✔ Opcional |
| Consola de texto (`virsh console`) | Ninguno | ✔ Siempre |
| Acceso gráfico (`virt-viewer`) | `--virt-viewer` + (`--user-pass` o `--enable-root`) | ✔ Opcional |

### ✔ Ejemplos con el usuario administrador

#### SSH por clave pública
```bash
ssh administrador@192.168.XXX.Y
```

#### SSH por contraseña
(solo si activaste `--user-pass`)
```bash
ssh administrador@192.168.XXX.Y -o PreferredAuthentications=password
```

#### Consola de texto
```bash
virsh console usuario-server1
```

Salir:
```
Ctrl + ]
```

#### Acceso con virt-viewer
```bash
virt-viewer --connect qemu+ssh://usuario@soserver.lsi.us.es/system usuario-server1
```

---

## Usuario `root`

| Acceso | Requisitos | Estado |
|--------|------------|--------|
| SSH | – | ❌ Prohibido |
| Consola de texto | `--enable-root` | ✔ |
| Acceso mediante virt-viewer | `--enable-root` + `--virt-viewer` | ✔ |

### ✔ Ejemplos con root

#### Consola de texto
```bash
virsh console usuario-server1
```
Login:
```
root
s1st3mas
```

#### virt-viewer
```bash
virt-viewer --connect qemu+ssh://usuario@soserver.lsi.us.es/system usuario-server1
```

---

# 7. 🧩 Archivos generados por el script

El script genera:

```
cloudinit-NOMBRE_VM/
 ├── cip-user.yaml
 ├── cip-meta.yaml
 └── cip-net.yaml   (solo si has configurado IP estática)
```

---

# 8. 🆘 Problemas comunes

| Problema | Causa | Solución |
|----------|--------|----------|
| No puedo entrar por SSH | No tienes clave pública | `ssh-keygen` |
| Disco fuera del silo | El qcow2 no está en imágenesMV | Muévelo |
| virt-viewer no funciona | No activaste root o contraseña | Repite con opciones correctas |
| guest-agent no responde | Cloud-init tarda ~40s | Espera el arranque |
| Root no entra por SSH | Siempre está prohibido | Usa consola |

---

# 9. 👨‍🏫 Autor

**David Gutiérrez Avilés**  
Profesor Titular de Universidad  
Departamento de Lenguajes y Sistemas Informáticos  
Universidad de Sevilla

Script utilizado en las prácticas de **Sistemas Operativos**.