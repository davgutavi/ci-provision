# Desarrollo de ci-provision

Esta guía es para quien modifique el script. Si eres alumno de la asignatura,
no necesitas nada de esto: lee el [README](README.md).

## Estructura

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

El primer test comprueba que `ci-provision.sh` está al día respecto a los
fuentes, así que no se puede olvidar.

## Tests locales (sin libvirt)

Usan [bats](https://github.com/bats-core/bats-core), incluido como submódulo,
con un `virsh`, un `virt-install` y un `wget` simulados (`test/mocks/`) y un
`HOME` de mentira. Clona con:

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

Los simuladores admiten variables de entorno para provocar situaciones
concretas (el agente que tarda en responder, cloud-init que falla, la descarga
que se corrompe, etc.); están documentadas en la cabecera de cada mock.

## Pruebas en un servidor de la asignatura

`tools/pruebas-servidor.sh` ejecuta el script de verdad contra libvirt, por fases:

```bash
bash tools/pruebas-servidor.sh a       # validaciones: no crea nada
bash tools/pruebas-servidor.sh b       # crea máquinas sueltas y las comprueba por SSH
bash tools/pruebas-servidor.sh c       # crea el clúster GlusterFS y lo comprueba
bash tools/pruebas-servidor.sh todas
```

Las fases B y C entran en las máquinas por SSH con tu clave, así que antes hay
que cargarla en el agente (`eval "$(ssh-agent -s)" && ssh-add`). Variables:

- `LIMPIAR=1`: en la fase C, pasa `--limpiar` al script si ya existen
  `server1`..`4` o `glusterbase` (el script enumera qué borra).
- `CONSERVAR=1`: no elimina las máquinas de prueba al terminar cada fase.

Cada ejecución deja un log completo en el silo (`pruebas-servidor-FECHA.log`).

## Lo que conviene saber antes de tocar el código

- `set -euo pipefail` está activo. Nada de tuberías hacia un `awk` o `head`
  que salga antes de tiempo: el productor muere con SIGPIPE y el script entero
  aborta. Recoge la salida en una variable y filtra con un here-string.
- `qemu-img info` sobre el disco de una máquina en ejecución necesita `-U`.
- `virsh change-media --eject` con `--live --config` a la vez falla en cuanto
  una de las dos definiciones ya está limpia; se hacen por separado y se
  decide por el estado final.
- El guest agent responde en cuanto la máquina arranca; para saber si
  cloud-init ha terminado se ejecuta `cloud-init status` dentro de la máquina
  con `virsh qemu-agent-command` (guest-exec). Está comprobado que funciona
  para un usuario normal en los servidores de la asignatura.
- Los nodos del clúster son copias COW de la base con un `instance-id`
  nuevo: eso es lo que hace que cloud-init los vuelva a configurar.
