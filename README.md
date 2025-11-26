# 🚀 ci-provision
### Script para crear máquinas virtuales con cloud-init  
**Asignatura: Sistemas Operativos — Universidad de Sevilla**

---

# 🧭 ¿Cómo instalar y preparar el script?

Ejecuta estos pasos **dentro de tu cuenta en el servidor de la asignatura**.

⚠️ **IMPORTANTE: Descarga el script directamente dentro de tu silo**
(hará más fácil usarlo y mantener los archivos del laboratorio ordenados)

Primero entra en tu silo:

```bash
cd $HOME/imagenesMV/
```

### **1. Descarga el script desde GitHub**

Con **wget**:
```bash
wget https://raw.githubusercontent.com/davgutavi/ci-provision/main/ci-provision.sh \
     -O ci-provision.sh
```

Con **curl**:
```bash
curl -L https://raw.githubusercontent.com/davgutavi/ci-provision/main/ci-provision.sh \
     -o ci-provision.sh
```

### **2. Añade permisos de ejecución**
```bash
chmod u+x ci-provision.sh
```

### **3. Comprueba que funciona**
```bash
./ci-provision.sh -h
```

---

# ℹ️ ¿Qué hace este script?

`ci-provision.sh` automatiza la creación de máquinas virtuales basadas en **Debbian 12 cloud** usando `virt-install` y `cloud-init`.  
Configura automáticamente:

- el usuario **administrador** con tu clave pública SSH,
- la red (IP estática o DHCP),
- la memoria y las vCPUs,

Opcionalmente se puede configurar:
- una contraseña para el usuario **administrador**.
- la habilitación del usuario **root** para su acceso **solo por consola** (para prácticas de rescate).
- el acceso a la máquina virtual a través de **virt-viewer**.
- la conexión de **cinco discos extra**.

---

## ✅ Requisitos previos

### **1. Tener el silo construido**
Debe existir y estar montado correctamente en:
```
$HOME/imagenesMV/
```

### **2. Tener una red virtual creada**
Comprueba las redes disponibles:
```bash
virsh net-list 
```

### **3. Tener en el silo la imagen cloud de Debian 12**

Debes guardar la imagen dentro de:
```
$HOME/imagenesMV/debian12.qcow2
```

Ejemplos de descarga:

Con **wget**:
```bash
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 \
     -O $HOME/imagenesMV/debian12.qcow2
```

Con **curl**:
```bash
curl -L https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 \
     -o $HOME/imagenesMV/debian12.qcow2
```

### **4. Tener creado el disco de la nueva máquina virtual ubicado en el silo ($HOME/imagenesMV/)**
Debe ser una copia COW de la imagen cloud.

Por ejemplo:

```bash
qemu-img create -f qcow2  -b debian12.qcow2 -F qcow2 server1.qcow2 40G
```

---

## 🛠 Uso

Desde tu silo:

```bash
./ci-provision.sh [opciones] NOMBRE_VM DISCO HOSTNAME RED [IP] [RAM_MB] [VCPUS]
```

### Parámetros principales

| Parámetro | Descripción |
|----------|-------------|
| `NOMBRE_VM` | Nombre de la VM en libvirt |
| `DISCO` | Debe estar en `$HOME/imagenesMV` |
| `HOSTNAME` | Nombre interno del sistema |
| `RED` | Red virtual existente |

### Parámetros opcionales

| Parámetro | Descripción | Por defecto |
|-----------|-------------|-------------|
| `IP` | IP estática | DHCP |
| `RAM_MB` | Memoria | 2048 |
| `VCPUS` | Núcleos | 2 |

---

## ⚙️ Opciones

| Opción | Descripción |
|--------|-------------|
| `--user-pass PASS` | Añade contraseña para el usuario `administrador` |
| `--enable-root` | Habilita root **solo por consola** |
| `-h` | Muestra ayuda |

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

## 📌 Ejemplo completo (IP + root + user-pass)

Este comando crea una VM con:

- IP estática  
- Contraseña para el usuario `administrador`  
- Root habilitado **solo por consola**  

```bash
./ci-provision.sh --enable-root --user-pass s3gur1t4 \
    usuario-server5 server5.qcow2 server5 usuario-red 192.168.2.50 2048 2
```

---

## 🔐 Accesos configurados

### Usuario `administrador`
- SSH por **clave pública** (siempre)
- SSH por **contraseña** (solo si usas `--user-pass`)

### Usuario `root`
- ❌ No puede entrar por SSH  
- ✔ Solo funciona por **consola**

#### Métodos de acceso por consola:

### **1. Usando virt-manager**
- Abrir *virt-manager*  
- Abrir la consola de tu VM  
- Entrar como:
  ```
  root
  s1st3mas
  ```

### **2. Usando virt-viewer (recomendado para acceso remoto)**
```bash
virt-viewer --connect qemu+ssh://usuario@soserver.lsi.us.es/system usuario-serverX
```

Donde `usuario-serverX` es el nombre de tu máquina virtual.

---

## 🧩 Archivos generados por VM

Cada provisión crea:

```
cloudinit-NOMBRE_VM/
 ├── cip-meta.yaml
 ├── cip-user.yaml
 └── cip-net.yaml   (sólo si usaste IP estática)
```

---

## 🆘 Problemas comunes

| Problema | Causa | Solución |
|----------|--------|----------|
| No puedo hacer SSH | No tienes clave pública | `ssh-keygen` |
| Error “El disco debe estar en imágenesMV” | Disco fuera del silo | Mueve el fichero |
| Root no funciona por SSH | Comportamiento esperado | Usa `virt-manager` o `virt-viewer` |

---

## 👨‍🏫 Autor
David Gutiérrez Avilés — Profesor Titular de Universidad  
Departamento de Lenguajes y Sistemas Informáticos — Universidad de Sevilla

Este script se utiliza en las prácticas de la asignatura **Sistemas Operativos**.