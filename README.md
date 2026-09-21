# 🚀 ci-provision
### Script para crear máquinas virtuales con cloud-init  
**Asignatura: Sistemas Operativos — Universidad de Sevilla**

---

# 1. 🧠 ¿Qué hace este script?

`ci-provision.sh` automatiza la **creación completa de máquinas virtuales**
basadas en **Debian 12 cloud**, usando `virt-install` y `cloud-init`, en el
servidor de la asignatura.

Todas las máquinas que crea tienen:

- Usuario `administrador` con tu clave pública SSH y `sudo` sin contraseña.
- Usuario `root` con contraseña `s1st3mas`, **solo para la consola**.
- Consola gráfica activa (`virt-viewer`).
- `qemu-guest-agent` instalado y zona horaria `Europe/Madrid`.

### ✔ Funcionalidades opcionales
- `--extra-disks`: crea y conecta 6 discos `vdb`..`vdg` (infraestructura del boletín 2, epígrafe 2.1).
- `--glusterfs`: construye una **imagen base GlusterFS**: instala `glusterfs-server`,
  habilita `glusterd`, vacía `/etc/machine-id` y, al terminar, apaga la máquina y
  elimina su dominio, dejando solo el disco `qcow2` listo para hacer copias.
- `--gluster-cluster`: construye **toda** la infraestructura del boletín 2, epígrafe 2.4
  (imagen base + `server1`..`server4`) en un solo comando.
- `--base`: usa como imagen de partida una que ya tengas en el silo (por ejemplo,
  tu imagen base GlusterFS), en lugar de `debian12.qcow2`.
- `--ssh-pass`: da una contraseña a `administrador` y permite entrar por SSH escribiéndola,
  en lugar de con tu clave pública.
- `--no-root`: no habilita al usuario `root`.
- `--no-virt-viewer`: no habilita la consola gráfica.
- `--limpiar`: elimina, antes de empezar, las máquinas y discos que el script vaya a crear
  si ya existen de una ejecución anterior.

---

# 2. 📌 Requisitos previos

## **1. Tener el silo creado**
Debe estar configurado en el trayecto:

```
$HOME/imagenesMV/
```

## **2. Tener una red virtual creada**
Con el nombre `TU_USUARIO-red`. Compruébalo con:

```bash
virsh net-list
```

Si tu red se llama de otra forma, el script la encontrará igualmente siempre que
empiece por tu nombre de usuario. Si tienes varias, o se llama de otro modo,
indícala con `--red NOMBRE` (ver [opciones avanzadas](#opciones-avanzadas)).

## **3. Imagen cloud de Debian 12**

Debe estar ubicada en el silo y llamarse **debian12.qcow2**:

```
$HOME/imagenesMV/debian12.qcow2
```

**Si no está, el script la descarga** (unos 430 MB) la primera vez que lo
ejecutes. Solo la guarda con ese nombre si la descarga termina bien y es una
imagen válida.

### Para obtenerla tú mismo, si lo prefieres:

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

## **4. Tu clave pública SSH**
En `$HOME/.ssh/id_rsa.pub`. Si no la tienes, créala con `ssh-keygen`.

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

### Todo en un comando

**wget:**
```bash
cd $HOME/imagenesMV && wget https://raw.githubusercontent.com/davgutavi/ci-provision/main/ci-provision.sh -O ci-provision.sh && chmod u+x ci-provision.sh
```

**curl:**
```bash
cd $HOME/imagenesMV && curl -L https://raw.githubusercontent.com/davgutavi/ci-provision/main/ci-provision.sh -o ci-provision.sh && chmod u+x ci-provision.sh
```

### Verificación
```bash
./ci-provision.sh -h
```

---

# 4. ⚙️ Funcionamiento

Ejecuta siempre desde tu silo:

```bash
./ci-provision.sh [opciones] MAQUINA [IP]
./ci-provision.sh [opciones] --gluster-cluster
```

De `MAQUINA` (por ejemplo `server1`) salen el nombre del dominio en libvirt
(`TU_USUARIO-server1`), el nombre de host (`server1`) y el disco principal
(`server1.qcow2`), que el script crea en el silo como copia COW de `debian12.qcow2`.

### Parámetros

| Parámetro | Descripción | Por defecto |
|-----------|-------------|-------------|
| `MAQUINA` | Nombre corto de la máquina: `server1`, `server2`, `glusterbase`... Solo letras, números y guiones | obligatorio |
| `IP` | IP fija dentro de tu red virtual | DHCP |

### Opciones

| Opción | Descripción |
|--------|-------------|
| `--extra-disks` | Crea y conecta 6 discos extra de 40G (`vdb`..`vdg`). Ver [SERVER1 del boletín 2](#caso-server1) |
| `--glusterfs` | Construye una imagen base GlusterFS y deja solo el disco. Ver [solo la imagen base](#caso-imagen-base) |
| `--gluster-cluster` | Construye la infraestructura completa del boletín 2, epígrafe 2.4. Ver [infraestructura GlusterFS](#caso-cluster) |
| `--base FICHERO` | Imagen del silo de la que hacer la copia, en lugar de `debian12.qcow2`. Con `--gluster-cluster`, los nodos parten de ella y no se construye la base. Ver [si ya tienes tu imagen base](#caso-base-propia) |
| `--ssh-pass CONTRASEÑA` | Da esa contraseña a `administrador` y permite entrar por SSH escribiéndola. La eliges tú; solo caracteres ASCII |
| `--no-root` | No habilita al usuario `root` |
| `--no-virt-viewer` | No habilita la consola gráfica. La consola de texto (`virsh console`) sigue funcionando |
| `--limpiar` | Si ya existen los dominios o discos que el script va a crear, los elimina antes, previa confirmación. **Solo esos** |
| `-h` | Ayuda |

Hay más opciones para casos particulares en [opciones avanzadas](#opciones-avanzadas).

### ⏳ Qué pasa al ejecutarlo

Tras crear la máquina, el script **espera a que termine de configurarse por
dentro** (instalación de paquetes y ajustes iniciales). Suele tardar entre uno y
tres minutos; mientras tanto verás un contador. Al terminar muestra un resumen con
los datos de la máquina y su IP.

### 🧹 Sobre `--limpiar`

El script siempre crea máquinas y discos **nuevos**. Si ya existe alguno de los
que va a crear, se detiene y te dice cuáles son y cómo eliminarlos. Con
`--limpiar` los elimina él, pero **únicamente esos**: nunca toca otro dominio ni
otro fichero de tu silo. Antes de hacerlo te enseña la lista y te pide
confirmación por teclado.

---

# 📘 Notas sobre los ejemplos

- **usuario** = tu usuario en el servidor  
- **192.168.XXX.Y** = una IP de tu red virtual privada  
- **soserver** = avantasia / warcry / megadeth  

---

<a id="casos-de-uso"></a>
# 5. 🧪 Casos de uso

---

## 🟦 **1️⃣ Máquina básica**

### **Con DHCP**

```bash
./ci-provision.sh server1
```

### **Con IP fija**

```bash
./ci-provision.sh server1 192.168.XXX.2
```

### **Permitiendo además entrar por SSH con contraseña**

```bash
./ci-provision.sh --ssh-pass Alumno2025 server1
```

---

<a id="caso-server1"></a>
## 🟩 **2️⃣ SERVER1 del boletín 2 — Epígrafe 2.1**

### **Máquina con IP fija y seis discos extra**

```bash
./ci-provision.sh --extra-disks server1 192.168.XXX.2
```

### **Si `server1` ya existía y quieres rehacerla desde cero**

```bash
./ci-provision.sh --limpiar --extra-disks server1 192.168.XXX.2
```

---

<a id="caso-cluster"></a>
## 🟥 **3️⃣ Infraestructura GlusterFS del boletín 2 — Epígrafe 2.4**

### **Todo en un comando**

```bash
./ci-provision.sh --gluster-cluster
```

Crea, en dos fases:

1. **Una imagen base** `glusterbase.qcow2`, con `glusterfs-server` instalado,
   `glusterd` habilitado y el `machine-id` vacío. Se construye en una máquina
   provisional (`usuario-glusterbase`) que, al terminar, se apaga y se elimina;
   el disco **se conserva**, porque los nodos son copias COW de él.
2. **Cuatro nodos** `usuario-server1`..`usuario-server4`, cada uno con:
   - IP fija `192.168.XXX.10`, `.11`, `.12` y `.13`
   - `/etc/hosts` con los cuatro nombres
   - 7 discos extra de 40G (`vdb`..`vdh`); `vdb`, `vdc` y `vdd` formateados en xfs
     y montados en `/gluster1`, `/gluster2` y `/gluster3` desde `/etc/fstab`
   - 1 vCPU y 1 GB de RAM

Los cuatro nodos arrancan en paralelo y el script espera a que todos terminen.
En total tarda unos tres minutos.

> ⚠️ **No borres `glusterbase.qcow2`** mientras existan los nodos.

### **Si ya tenías máquinas de otros ejercicios**

Si existen `usuario-server1`..`4` o sus discos, el script se detendrá y te lo
dirá. Para que los elimine él:

```bash
./ci-provision.sh --limpiar --gluster-cluster
```

<a id="caso-base-propia"></a>
### **Si ya tienes tu imagen base y solo quieres los nodos**

Con `--base` no se construye la base: los cuatro nodos se crean directamente
como copias de la imagen que indiques, que **no se toca** (ni siquiera con
`--limpiar`). Tarda alrededor de un minuto.

```bash
./ci-provision.sh --gluster-cluster --base glusterbase.qcow2
```

<a id="caso-imagen-base"></a>
### **Solo la imagen base**

```bash
./ci-provision.sh --glusterfs glusterbase
```

Deja `glusterbase.qcow2` en el silo, sin máquina. Después puedes crear los
nodos con el comando anterior, o hacerlo tú siguiendo los apartados a, b, c y d
del epígrafe 2.4 del boletín 2. Para crear una máquina suelta a partir de esa
imagen también sirve `--base`:

```bash
./ci-provision.sh --base glusterbase.qcow2 server1 192.168.XXX.10
```

---

# 6. 🔐 Accesos configurados

## Usuario `administrador`

| Acceso | Requisitos | Estado |
|--------|------------|--------|
| SSH con tu clave pública | Ninguno | ✔ Siempre |
| SSH escribiendo contraseña | `--ssh-pass` | ✔ con la contraseña que elijas |
| Consola (`virsh console` / virt-viewer) | `--ssh-pass` | ✔ con la contraseña que elijas |

## Usuario `root`

| Acceso | Requisitos | Estado |
|--------|------------|--------|
| SSH | – | ❌ Prohibido |
| Consola (`virsh console` / virt-viewer) | Ninguno | ✔ contraseña `s1st3mas` |

Con `--no-root`, el usuario `root` queda sin contraseña y no se puede entrar con
él por ningún medio. Con `--no-virt-viewer`, la máquina no tiene consola gráfica;
`virsh console` sigue funcionando.

### Ejemplos

```bash
ssh administrador@192.168.XXX.Y
virsh console usuario-server1
virt-viewer --connect qemu+ssh://usuario@soserver.lsi.us.es/system usuario-server1
```

> 💡 Si al conectar por SSH ves un aviso `REMOTE HOST IDENTIFICATION HAS CHANGED`,
> es que esa IP la tuvo antes otra máquina tuya. El script te avisa al terminar y
> te da el comando `ssh-keygen -R` para resolverlo.

> 💡 De `virsh console` se sale con `Ctrl+]`. En un teclado de Mac esa tecla es
> `⌥ Option + Shift + 9`, lo que resulta incómodo; puedes cambiar el carácter de
> escape al entrar, y salir entonces con `Ctrl+X`:
> ```bash
> virsh -e '^X' console usuario-server1
> ```

---

# 7. 🧩 Archivos generados

En el silo:

```
server1.qcow2                     disco principal (copia COW de debian12.qcow2)
server1-vdb.qcow2 … server1-vdg.qcow2   discos extra, si se pidieron
cloudinit-usuario-server1/
 ├── cip-user.yaml
 ├── cip-meta.yaml
 └── cip-net.yaml                 solo si hay IP estática
```

Los discos extra se llaman siempre `MAQUINA-vdX.qcow2`, que es el nombre que
usan los ejercicios del boletín (por ejemplo, `virsh detach-disk usuario-server1
$PWD/server1-vdb.qcow2`).

Con `--gluster-cluster` se genera un directorio `cloudinit-*` por máquina (la
base y cada nodo).

> ⚠️ Los ficheros `cloudinit-*` contienen las contraseñas en texto plano, así que
> el directorio se crea con permisos `700` (solo tú puedes leerlo). Recuerda que
> el servidor de la asignatura es compartido con el resto de la clase.

---

# 8. 🧨 Códigos de error

| Código | Descripción | Solución |
|--------|-------------|-----------|
| **10** | Faltan o sobran parámetros, u opciones incompatibles | Revisa la sintaxis: `MAQUINA [IP]` |
| **11** | Falta el valor de una opción | Añádelo |
| **12** | Opción desconocida (u obsoleta) | Consulta `-h` |
| **13** | RAM o vCPUs no válidas | Números; mínimo 512 MB y 1 vCPU |
| **14** | Contraseña con caracteres no ASCII | Sin tildes ni `ñ`: no podrías teclearla en la consola |
| **15** | Tamaño de disco no válido | Formato `40G`, `20G`, `512M` |
| **16** | Nombre de disco o de imagen no válido | Solo el nombre del fichero, sin rutas |
| **20** | Nombre de máquina no válido | Solo letras, números y guiones |
| **21** | Ya existe el dominio o algún disco | El mensaje indica cómo eliminarlos, o usa `--limpiar` |
| **30** | No existe el silo | Crear `$HOME/imagenesMV` y mapearlo en el hipervisor |
| **31** | No existe la clave pública | `ssh-keygen` |
| **37** | No se ha podido descargar la imagen base, o la que hay está corrupta | El mensaje indica el `wget` manual, o el `rm` para que el script la vuelva a descargar |
| **38** | Faltan herramientas (incluido `wget`/`curl` para descargar la imagen) o no hay conexión con libvirt | Avisar al profesor |
| **39** | La imagen indicada con `--base` no existe o no es un `qcow2` | Revisa el nombre; debe estar en el silo |
| **40** | No se encuentra tu red virtual | Créala con el nombre `TU_USUARIO-red`, o usa `--red` |
| **41** | IP no válida o fuera de tu red | El mensaje indica las IPs libres de tu red |
| **42** | IP ocupada por DHCP o reservada | El mensaje indica las IPs libres de tu red |
| **43** | No se puede interpretar la red | Revisar `virsh net-dumpxml TU_RED` |
| **44** | Tienes varias redes virtuales | Indica cuál con `--red` |
| **45** | Tu red virtual está inactiva | `virsh net-start TU_RED` |
| **70** | La imagen base GlusterFS no ha terminado o no se ha apagado | Reintentar; revisar la carga del servidor |
| **71** | cloud-init ha fallado en la imagen base GlusterFS | Revisar con `virsh console` |

---

<a id="opciones-avanzadas"></a>
# 9. 🔧 Opciones avanzadas

No las necesitas en los [casos de uso](#casos-de-uso).

| Opción | Descripción |
|--------|-------------|
| `--dry-run` | Comprueba los datos y muestra lo que se haría, **sin crear nada** |
| `--no-wait` | No espera a que la máquina termine de configurarse (no válida con `--glusterfs`) |
| `--red NOMBRE` | Red virtual a usar, si no se llama `TU_USUARIO-red` o tienes varias |
| `--disco NOMBRE` | Nombre del disco principal (por defecto `MAQUINA.qcow2`) |
| `--tam TAMAÑO` | Tamaño del disco principal (por defecto `40G`) |
| `--ram MB` | Memoria (por defecto 2048; en el clúster, 1024 por nodo) |
| `--vcpus N` | vCPUs (por defecto 2; en el clúster, 1 por nodo) |

### `--dry-run`

Ejecuta todas las comprobaciones, genera los ficheros cloud-init y muestra el
comando `virt-install` exacto que se lanzaría, pero **no crea la máquina, ni los
discos, ni modifica nada**. Sirve para comprobar que los datos son correctos
antes de invertir un par de minutos, y para ver el comando que hay detrás del
script.

```bash
./ci-provision.sh --dry-run --extra-disks server1 192.168.XXX.2
./ci-provision.sh --dry-run --gluster-cluster
```

Los ficheros de la simulación se escriben en `cloudinit-DOMINIO.dry-run/`, así
que nunca sobrescriben los de una máquina que ya exista. Combinado con
`--limpiar`, solo enumera lo que se eliminaría.

### `--no-wait`

Devuelve el control en cuanto la máquina está creada. Ten en cuenta que entonces
la máquina **seguirá configurándose por dentro** durante un rato: si entras
enseguida, puede que los paquetes instalados por cloud-init todavía no estén
disponibles.

---

# 10. 👨‍🏫 Autor

**David Gutiérrez Avilés**  
Profesor Titular de Universidad  
Departamento de Lenguajes y Sistemas Informáticos  
Universidad de Sevilla

Script utilizado en las prácticas de **Sistemas Operativos**.
