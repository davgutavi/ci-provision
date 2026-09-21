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
- `--ssh-pass`: da una contraseña a `administrador` y permite entrar por SSH escribiéndola,
  en lugar de con tu clave pública.
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
indícala con `--red NOMBRE` (ver opciones avanzadas).

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
| `--extra-disks` | Crea y conecta 6 discos extra de 40G (`vdb`..`vdg`) |
| `--glusterfs` | Construye una imagen base GlusterFS y deja solo el disco (ver sección 5) |
| `--gluster-cluster` | Construye la infraestructura completa del boletín 2, epígrafe 2.4 (ver sección 5) |
| `--ssh-pass CONTRASEÑA` | Da esa contraseña a `administrador` y permite entrar por SSH escribiéndola. La eliges tú; solo caracteres ASCII |
| `--limpiar` | Si ya existen los dominios o discos que el script va a crear, los elimina antes. **Solo esos** |
| `-h` | Ayuda |

Hay más opciones para casos particulares en la sección 9, *Opciones avanzadas*.

### ⏳ Qué pasa al ejecutarlo

Tras crear la máquina, el script **espera a que cloud-init termine** de instalar
los paquetes y aplicar la configuración; para saberlo, consulta el estado de
cloud-init dentro de la máquina a través del agente invitado. Suele tardar entre
uno y tres minutos, y al terminar muestra un resumen con la IP de la máquina.

### 🧹 Sobre `--limpiar`

El script siempre crea máquinas y discos **nuevos**. Si ya existe alguno de los
que va a crear, se detiene y te dice cuáles son y cómo eliminarlos. Con
`--limpiar` los elimina él, pero **únicamente esos**: nunca toca otro dominio ni
otro fichero de tu silo. Antes de hacerlo enumera lo que va a eliminar y espera
5 segundos por si quieres cancelar con `Ctrl-C`.

---

# 📘 Notas sobre los ejemplos

- **usuario** = tu usuario en el servidor  
- **192.168.XXX.Y** = una IP de tu red virtual privada  
- **soserver** = avantasia / warcry / megadeth  

---

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

## 🟩 **2️⃣ SERVER1 del boletín 2 — Epígrafe 2.1**

### **Máquina con IP fija y seis discos extra**

```bash
./ci-provision.sh --extra-disks server1 192.168.XXX.2
```

Root ya está habilitado por consola: no hace falta pedirlo.

Cuando el script termine, toma la instantánea `inicio` **con la máquina apagada**:

```bash
virsh shutdown usuario-server1
virsh snapshot-create-as usuario-server1 --atomic --name inicio
virsh start usuario-server1
```

### **Si `server1` ya existía y quieres rehacerla desde cero**

```bash
./ci-provision.sh --limpiar --extra-disks server1 192.168.XXX.2
```

---

## 🟥 **3️⃣ Infraestructura GlusterFS del boletín 2 — Epígrafe 2.4**

### **Todo en un comando**

```bash
./ci-provision.sh --gluster-cluster
```

Crea, en dos fases:

1. **Una imagen base** `glusterbase.qcow2`, con `glusterfs-server` y `xfsprogs`
   instalados, `glusterd` habilitado y el `machine-id` vacío. Se construye en
   una máquina provisional (`usuario-glusterbase`) que, al terminar, se apaga y
   se elimina; el disco **se conserva**, porque los nodos son copias COW de él.
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

### **Solo la imagen base, para hacer las copias tú**

```bash
./ci-provision.sh --glusterfs glusterbase
```

Deja `glusterbase.qcow2` en el silo, sin máquina. A partir de ahí puedes crear los
nodos a mano siguiendo los apartados a, b, c y d del epígrafe 2.4 del boletín 2:

```bash
qemu-img create -f qcow2 -b glusterbase.qcow2 -F qcow2 server1.qcow2 40G
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

Al terminar, el script **expulsa el medio de cloud-init** de la máquina, de modo
que las instantáneas que tomes después no heredan la referencia a esa ISO temporal
(que es lo que provoca el error `Cannot access storage file` al revertirlas).

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
| **16** | Nombre de disco no válido | Solo el nombre del fichero, sin rutas |
| **20** | Nombre de máquina no válido | Solo letras, números y guiones |
| **21** | Ya existe el dominio o algún disco | El mensaje indica cómo eliminarlos, o usa `--limpiar` |
| **30** | No existe el silo | Crear `$HOME/imagenesMV` y mapearlo en el hipervisor |
| **31** | No existe la clave pública | `ssh-keygen` |
| **37** | No se ha podido descargar la imagen base, o la que hay está corrupta | El mensaje indica el `wget` manual, o el `rm` para que el script la vuelva a descargar |
| **38** | Faltan herramientas (incluido `wget`/`curl` para descargar la imagen) o no hay conexión con libvirt | Avisar al profesor |
| **40** | No se encuentra tu red virtual | Créala con el nombre `TU_USUARIO-red`, o usa `--red` |
| **41** | IP no válida o fuera de tu red | El mensaje indica las IPs libres de tu red |
| **42** | IP ocupada por DHCP o reservada | El mensaje indica las IPs libres de tu red |
| **43** | No se puede interpretar la red | Revisar `virsh net-dumpxml TU_RED` |
| **44** | Tienes varias redes virtuales | Indica cuál con `--red` |
| **45** | Tu red virtual está inactiva | `virsh net-start TU_RED` |
| **70** | La imagen base GlusterFS no ha terminado o no se ha apagado | Reintentar; revisar la carga del servidor |
| **71** | cloud-init ha fallado en la imagen base GlusterFS | Revisar con `virsh console` |

> 💡 Los errores **41** y **42** se comprueban contra la configuración real de
> tu red virtual (pasarela, máscara, rango DHCP y reservas), no contra unos
> valores fijos. Si tu red no sigue el esquema habitual, el mensaje te dirá
> cuáles son sus valores reales y qué direcciones te quedan libres.

Si el script se interrumpe por un fallo inesperado (o con `Ctrl-C`) antes de
terminar de crear las máquinas, deshace lo que había hecho: elimina los dominios
y los discos creados **en esa ejecución**. Nada que existiera antes se toca.

---

# 9. 🔧 Opciones avanzadas

No las necesitas en los casos de uso de la sección 5.

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
disponibles, y no se expulsa el medio de cloud-init (apaga la máquina antes de
tomar instantáneas).

---

# 10. 🛠️ Desarrollo

> Esta sección es para quien modifique el script. Si eres alumno de la
> asignatura, no necesitas nada de esto.

El script que se distribuye (`ci-provision.sh`) **se genera**, no se edita a
mano. El código vive separado en módulos:

```
src/main.sh          Opciones, flujo principal, rollback y resumen
lib/validations.sh   Entorno, elección de la red, validación de IPs, imagen base
lib/limpieza.sh      Conflictos con lo que ya existe y --limpiar
lib/cloudinit.sh     Ficheros cloud-init y expulsión del medio
lib/discos.sh        Creación de discos
lib/espera.sh        Espera a que cloud-init termine
lib/cluster.sh       Imagen base GlusterFS y --gluster-cluster
```

Tras modificar cualquiera de ellos, regenera el script distribuible:

```bash
bash tools/build.sh
```

### Tests locales (sin libvirt)

Usan [bats](https://github.com/bats-core/bats-core), incluido como submódulo,
con un `virsh`, un `virt-install` y un `wget` simulados (`test/mocks/`). Clona con:

```bash
git clone --recurse-submodules https://github.com/davgutavi/ci-provision.git
```

o, si ya lo habías clonado:

```bash
git submodule update --init
```

y ejecuta:

```bash
test_helper/bats-core/bin/bats test/
```

Necesitan `qemu-img` y `jq` (en macOS: `brew install qemu jq`).

### Pruebas en un servidor de la asignatura

`tools/pruebas-servidor.sh` ejecuta el script de verdad contra libvirt, por fases:

```bash
bash tools/pruebas-servidor.sh a       # validaciones: no crea nada
bash tools/pruebas-servidor.sh b       # crea máquinas sueltas y las comprueba por SSH
bash tools/pruebas-servidor.sh c       # crea el clúster GlusterFS y lo comprueba
bash tools/pruebas-servidor.sh todas
```

---

# 11. 👨‍🏫 Autor

**David Gutiérrez Avilés**  
Profesor Titular de Universidad  
Departamento de Lenguajes y Sistemas Informáticos  
Universidad de Sevilla

Script utilizado en las prácticas de **Sistemas Operativos**.
