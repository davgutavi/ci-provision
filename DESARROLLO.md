# Desarrollo de ci-provision

Esta guía es para quien modifique el script. Si eres alumno de la asignatura,
no necesitas nada de esto: lee el [README](README.md).

## Estructura

El script que se distribuye (`ci-provision.sh`) **se genera**, no se edita a
mano. El código vive separado en módulos:

```
src/main.sh          Opciones, flujo principal, rollback y resumen
lib/validations.sh   Entorno, elección de la red, validación de IPs, imagen de partida (--imagen)
lib/limpieza.sh      Conflictos con lo que ya existe y --limpiar
lib/cloudinit.sh     Ficheros cloud-init y expulsión del medio
lib/discos.sh        Creación de discos
lib/espera.sh        Espera a que cloud-init termine
lib/cluster.sh       Imagen base GlusterFS y --gluster-cluster
lib/gestion.sh       --listar, --eliminar y --eliminar-todo
lib/asistente.sh     Asistente con menús (--menu), sobre whiptail
```

Tras modificar cualquiera de ellos, regenera el script distribuible:

```bash
bash tools/build.sh
```

El primer test comprueba que `ci-provision.sh` está al día respecto a los
fuentes, así que no se puede olvidar.

## Tests locales (sin libvirt)

Usan [bats](https://github.com/bats-core/bats-core), incluido como submódulo,
con `virsh`, `virt-install`, `wget`, `curl` y `whiptail` simulados (`test/mocks/`) y un
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

Necesitan `qemu-img` y `jq` (en macOS: `brew install qemu jq`). En el silo de
mentira están ya las dos imágenes cloud (pequeñas), y en un directorio
compartido de mentira (`CI_PROVISION_DIR_COMPARTIDO`) una `ubuntu-base.qcow2`
de 64G vacía. También hay mocks de `ping` (responde a las IPs de
`$MOCK_STATE/ping_responde`) y de las sumas de las descargas, y la función
`definir_dominio` de `test/helpers.bash` crea máquinas "ajenas" (hechas a mano,
de otro usuario) para probar que el script no las toca.

Variables de entorno que lee el script (solo para pruebas y desarrollo; todas
con el prefijo `CI_PROVISION_` para no recoger por accidente las de un alumno):
`CI_PROVISION_WAIT_TIMEOUT`, `_POLL_SECS`, `_GRACE_SECS`, `_SHUTDOWN_TIMEOUT`,
`_DIR_COMPARTIDO`, `_PUBKEY`, `_LIBVIRT_URI` y, internamente entre el asistente
y el proceso que lanza, `_SSH_PASS`.

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

- **A**: códigos de error y `--dry-run` (imagen por defecto, `--imagen`, base del clúster).
- **B**: SERVER1 de Ubuntu con DHCP y con IP fija y seis discos, con las
  instantáneas internas `--atomic` del boletín (en caliente, en frío,
  `detach-disk` de `vdb` y reversiones); Debian 12 con `--ssh-pass` y `--no-root`;
  `--glusterfs` desde Noble y desde ubuntu-base; `--listar` y `--eliminar`.
- **C**: el clúster por defecto, comprobado nodo a nodo; `gluster peer probe`;
  vDisperso montado en `server4` con MySQL en Podman encima (epígrafe 2.9), y
  los nodos rehechos con `--base gluster-base.qcow2 --discos-nodo 7`.

Para entrar en las máquinas, las fases B y C usan una **clave de usar y tirar**:
la batería la genera al empezar (en `~/.ci-provision-pruebas.XXXXXX`, sin frase
de paso), se la da a las máquinas con `CI_PROVISION_PUBKEY` y la borra al
terminar, pase lo que pase. No se usa ninguna clave tuya ni ningún agente SSH:
si esa clave se filtrara, solo abriría las máquinas de prueba.

Al terminar **no queda ninguna máquina en marcha**: B y C eliminan todo lo que
crean. Variables:

- `LIMPIAR=1`: en la fase C, pasa `--limpiar` al script si ya existen
  `server1`..`4` o `gluster-base` (el script enumera qué borra).
- `CONSERVAR=1`: no elimina las máquinas ni el clúster al terminar. Como la
  clave de pruebas se borra, solo se podrá entrar en ellas por consola.
- `SIN_MYSQL=1`: en la fase C, omite la prueba de MySQL (unos 3 minutos).

Se puede lanzar sin terminal (`ssh servidor 'bash …/pruebas-servidor.sh b'`):
la batería fija `LIBVIRT_DEFAULT_URI=qemu:///system`, porque sin una sesión de
login `virsh` se conectaría a `qemu:///session` y no vería nada.

Cada ejecución deja un log completo en el silo (`pruebas-servidor-FECHA.log`).

## Lo que conviene saber antes de tocar el código

- `set -euo pipefail` está activo. Nada de tuberías hacia un `awk` o `head`
  que salga antes de tiempo: el productor muere con SIGPIPE y el script entero
  aborta. Recoge la salida en una variable y filtra con un here-string.
- `qemu-img info` sobre el disco de una máquina en ejecución necesita `-U`.
- El script fija `LIBVIRT_DEFAULT_URI=qemu:///system`: sin sesión de login, o
  con la variable heredada (el libvirt de Homebrew pone `qemu:///session`),
  virsh no vería las máquinas y todo parecería suelto.
- Las confirmaciones (`confirmar`) no se dan por buenas sin terminal: hace
  falta `--si` (error 23). La batería lo pasa siempre.
- Qué se puede borrar lo decide `filtrar_borrables` (limpieza.sh), común a
  `--limpiar`, `--eliminar` y `--eliminar-todo`: nunca un disco de cualquier
  dominio del servidor que no se elimine, ni una imagen de la que dependa (por
  una cadena de cualquier longitud) una copia que se conserva, ni una imagen
  cloud. El mapa de respaldos se lee una vez (`cargar_respaldos`); cargarlo
  dentro de `$(...)` no sirve, porque se pierde al salir de la subshell.
- Un dominio solo se trata como del alumno si sus discos están en el silo
  (`dominio_en_silo`): los nombres de dominio son de todo el servidor.
- Con `--cloud-init`, virt-install arranca la máquina con una definición "de
  instalación" con `on_reboot=destroy` (la persistente tiene `restart`) y
  espera estar presente en el primer reinicio para volver a arrancarla. Con
  `--noautoconsole` no lo está: el primer `reboot` dentro de la máquina la
  apagaría, y una instantánea en caliente guardaría ese `destroy`. Por eso,
  cuando cloud-init termina, el script la apaga y la arranca desde fuera
  (`reiniciar_en_frio`, espera.sh) y comprueba `on_reboot` en `virsh dumpxml`.
  Detectado al grabar el boletín 2 (19-oct-2026).
- `virsh change-media --eject` con `--live --config` a la vez falla en cuanto
  una de las dos definiciones ya está limpia; se hacen por separado y se
  decide por el estado final.
- El guest agent responde en cuanto la máquina arranca; para saber si
  cloud-init ha terminado se ejecuta `cloud-init status` dentro de la máquina
  con `virsh qemu-agent-command` (guest-exec). Está comprobado que funciona
  para un usuario normal en los servidores de la asignatura.
- Los nodos del clúster son copias COW de la base con un `instance-id`
  nuevo: eso es lo que hace que cloud-init los vuelva a configurar. Con
  `--imagen ubuntu-base` funciona igual: esa imagen trae cloud-init con NoCloud.
- En el user-data solo van claves vigentes en el cloud-init de Ubuntu 24.04
  (`chpasswd: users:`, `ssh_authorized_keys`). Una obsoleta (`chpasswd: list:`,
  `ssh-authorized-keys`) deja el estado en `degraded done`, que el script trata
  como error. Debian 12 (cloud-init 22.4) también acepta la sintaxis nueva.
- Con `--base`, el tipo de imagen (y con él la variante de SO y cómo queda
  `administrador`) se deduce de la última imagen de su cadena de respaldo
  (`deducir_imagen_de_base`); un fichero sin respaldo se trata como una copia
  de ubuntu-base.
- Las imágenes cloud (`imagen_protegida`) no se borran nunca, ni con
  `--limpiar` ni con `--eliminar`/`--eliminar-todo`.
- `tools/build.sh` concatena las librerías **antes** de `src/main.sh` y solo
  elimina de este las líneas `source …/lib/*.sh`: nada de las librerías puede
  ejecutarse a nivel superior dependiendo de variables de `main.sh`, y ningún
  otro texto de `main.sh` debe empezar por `source `.
- El flujo de `main` es `parse_args` → `validar_opciones` →
  `calcular_derivados` → `validar_entorno` → modo. Toda máquina (suelta, base
  GlusterFS o nodo) se crea con `crear_maquina`, que registra lo creado para
  el rollback.
