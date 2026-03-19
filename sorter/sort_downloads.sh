#!/usr/bin/env bash
# sort_downloads.sh — wrapper for sort_downloads.py
# Installs missing Python deps, then runs the sorter.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/sort_downloads.py"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[sort]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

# ── Check Python 3.11+ ────────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    error "python3 not found. Install it with: sudo apt install python3"
    exit 1
fi

PYVER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PYMAJ=$(python3 -c "import sys; print(sys.version_info.major)")
PYMIN=$(python3 -c "import sys; print(sys.version_info.minor)")

if [[ "$PYMAJ" -lt 3 ]] || [[ "$PYMAJ" -eq 3 && "$PYMIN" -lt 11 ]]; then
    error "Python 3.11+ required for built-in tomllib. You have Python $PYVER."
    exit 1
fi

info "Using Python $(python3 --version) — tomllib built-in, no extra config deps needed."

# ── Install pip if missing ────────────────────────────────────────────────────
if ! python3 -m pip --version &>/dev/null; then
    warn "pip not found — installing..."
    sudo apt-get install -y python3-pip
fi

# ── Install content-extraction libraries ─────────────────────────────────────
# Note: pyyaml is no longer needed — TOML is built into Python 3.11+
declare -A DEPS=(
    [pdfplumber]="pdfplumber"
    [docx]="python-docx"
    [openpyxl]="openpyxl"
    [odf]="odfpy"
)

for import_name in "${!DEPS[@]}"; do
    pip_name="${DEPS[$import_name]}"
    if ! python3 -c "import $import_name" &>/dev/null 2>&1; then
        info "Installing $pip_name..."
        python3 -m pip install --quiet "$pip_name" --break-system-packages
    fi
done

info "All dependencies ready."
echo ""

# ── Run the sorter ────────────────────────────────────────────────────────────
exec python3 "$PYTHON_SCRIPT" "$@"
