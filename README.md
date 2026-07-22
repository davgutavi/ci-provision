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
| `--dry-run` | Comprueba los datos y muestra lo que se haría, **sin crear nada** |
| `--no-wait` | No espera a que la máquina termine de configurarse |
| `-h` | Ayuda |

### 🔍 Sobre `--dry-run`

Ejecuta todas las comprobaciones, genera los ficheros cloud-init y muestra el
comando `virt-install` exacto que se lanzaría, pero **no crea la máquina, ni
los discos extra, ni modifica nada**.

Es útil para comprobar que los datos son correctos antes de invertir un par de
minutos, y para ver el comando que hay detrás del script.

```bash
./ci-provision.sh --dry-run usuario-server1 server1.qcow2 server1 usuario-red 192.168.XXX.2
```

Los ficheros de la simulación se escriben en `cloudinit-NOMBRE_VM.dry-run/`,
así que nunca sobrescriben los de una máquina que ya exista.

### ⏳ Sobre la espera

Tras crear la máquina, el script **espera a que cloud-init termine** de
instalar los paquetes y ejecutar su configuración, consultando periódicamente
al agente invitado. Puede tardar entre uno y tres minutos, y al terminar
muestra la IP de la máquina.

`--no-wait` omite esa espera y devuelve el control de inmediato. Ten en cuenta
que en ese caso la máquina **seguirá configurándose por dentro** durante un
rato: si entras enseguida, puede que los paquetes instalados por cloud-init
(por ejemplo `glusterfs-server`) todavía no estén disponibles.

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

Con `--dry-run` el directorio es `cloudinit-NOMBRE_VM.dry-run/`.

> ⚠️ Estos ficheros contienen las contraseñas en texto plano, así que el
> directorio se crea con permisos `700` (solo tú puedes leerlo). Recuerda que
> el servidor de la asignatura es compartido con el resto de la clase.

---

# 8. 🧨 Códigos de error

| Código | Descripción | Solución |
|--------|-------------|-----------|
| **10** | Faltan parámetros obligatorios | Revisa el comando |
| **11** | Falta valor tras `--user-pass` | Añade contraseña |
| **12** | Opción desconocida | Consulta `-h` |
| **13** | RAM o vCPUs no numéricas | Deben ser números (mínimo 512 MB y 1 vCPU) |
| **14** | Contraseña con caracteres no ASCII | Sin tildes ni `ñ`: no podrías teclearla en la consola |
| **20** | Nombre inválido | Formato `usuario-maquina`, solo letras, números, `_` y `-` |
| **21** | Dominio ya existe | `virsh destroy + undefine` |
| **30** | No existe el silo | Crear `$HOME/imagenesMV` |
| **31** | No existe la clave pública | `ssh-keygen` |
| **32** | No existe el qcow2 | Revisa nombre |
| **33** | qcow2 fuera del silo | Mover al silo |
| **34** | No es qcow2 o no es COW | Crear disco COW |
| **35** | Backing file incorrecto | Debe ser `debian12.qcow2` |
| **36** | Disco reutilizado (>1 MiB) | Crear disco nuevo |
| **37** | No existe la imagen base | Descargar `debian12.qcow2` en el silo |
| **38** | Faltan herramientas en el servidor | Avisar al profesor |
| **40** | Red virtual no existe | Revisar `virsh net-list` |
| **41** | IP inválida o fuera de tu red | El mensaje indica las IPs libres de tu red |
| **42** | IP ocupada por DHCP o reservada | El mensaje indica las IPs libres de tu red |
| **43** | No se puede interpretar la red | Revisar `virsh net-dumpxml TU_RED` |
| **50** | virt-viewer sin acceso válido | Añadir contraseña o root |
| **60** | Disco extra ya existe | Eliminar archivo o usar otro nombre |

> 💡 Los errores **41** y **42** se comprueban contra la configuración real de
> tu red virtual (pasarela, máscara, rango DHCP y reservas), no contra unos
> valores fijos. Si tu red no sigue el esquema del manual, el mensaje te dirá
> cuáles son sus valores reales y qué direcciones te quedan libres.

Si el script se interrumpe por un fallo inesperado después de haber creado la
máquina, deshace lo que había hecho: elimina el dominio y los discos extra
creados **en esa ejecución**. Tu disco principal nunca se toca.

---

# 9. 🛠️ Desarrollo

> Esta sección es para quien modifique el script. Si eres alumno de la
> asignatura, no necesitas nada de esto.

El script que se distribuye (`ci-provision.sh`) **se genera**, no se edita a
mano. El código vive separado en módulos:

```
src/main.sh          Parseo de opciones, flujo principal y resumen
lib/validations.sh   Validaciones de entorno, disco, red e IP
lib/cloudinit.sh     Generación de los ficheros cloud-init
lib/extra_disks.sh   Creación y enganche de los discos extra
lib/espera.sh        Espera activa a que cloud-init termine
```

Tras modificar cualquiera de ellos, regenera el script distribuible:

```bash
bash tools/build.sh
```

Los tests usan [bats](https://github.com/bats-core/bats-core), incluido como
submódulo, así que hay que clonar con:

```bash
git clone --recurse-submodules https://github.com/davgutavi/ci-provision.git
```

Si ya lo habías clonado sin los submódulos:

```bash
git submodule update --init --recursive
```

Para comprobar las validaciones en un servidor **sin crear ninguna máquina**:

```bash
bash tools/pruebas-fase-a.sh ./ci-provision.sh
```

---

# 10. 👨‍🏫 Autor

**David Gutiérrez Avilés**  
Profesor Titular de Universidad  
Departamento de Lenguajes y Sistemas Informáticos  
Universidad de Sevilla

Script utilizado en las prácticas de **Sistemas Operativos**.