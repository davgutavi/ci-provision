#!/bin/bash
set -euo pipefail

# Directorio raíz del repositorio (subimos un nivel desde tools/)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/ci-provision.sh"

echo "Generando script standalone en: $OUT"

# Cabecera
{
    echo "#!/bin/bash"
    echo "set -euo pipefail"
    echo
} > "$OUT"

# Librerías (solo funciones, sin shebang)
cat "$ROOT_DIR/lib/validations.sh" >> "$OUT"
echo >> "$OUT"
cat "$ROOT_DIR/lib/cloudinit.sh" >> "$OUT"
echo >> "$OUT"
cat "$ROOT_DIR/lib/extra_disks.sh" >> "$OUT"
echo >> "$OUT"

# Script principal, sin shebang, sin 'set -euo pipefail' y sin 'source ...'
grep -vE '^#!/bin/bash|^set -euo pipefail|^source ' \
    "$ROOT_DIR/src/ci-provision-main.sh" >> "$OUT"

chmod +x "$OUT"

echo "✔ Script standalone generado correctamente."
echo "   Ahora puedes subir 'ci-provision.sh' a tu repositorio (rama main)."