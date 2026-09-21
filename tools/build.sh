#!/bin/bash
set -euo pipefail

# Directorio raíz del repositorio (subimos un nivel desde tools/)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Se puede indicar otra salida (lo usan los tests para comprobar que el
# script distribuible está al día respecto a los fuentes)
OUT="${1:-$ROOT_DIR/ci-provision.sh}"

# Librerías, en el orden en que las carga src/main.sh
LIBS=(validations limpieza cloudinit discos espera cluster)

echo "Generando script standalone en: $OUT"

# Cabecera
{
    echo "#!/bin/bash"
    echo "set -euo pipefail"
    echo
} > "$OUT"

# Librerías (solo funciones, sin shebang)
for lib in "${LIBS[@]}"; do
    cat "$ROOT_DIR/lib/$lib.sh" >> "$OUT"
    echo >> "$OUT"
done

# Script principal, sin shebang, sin 'set -euo pipefail' y sin 'source ...'
grep -vE '^#!/bin/bash|^set -euo pipefail|^source ' \
    "$ROOT_DIR/src/main.sh" >> "$OUT"

chmod +x "$OUT"

echo "✔ Script standalone generado correctamente."
echo "   Ahora puedes subir 'ci-provision.sh' a tu repositorio (rama main)."
