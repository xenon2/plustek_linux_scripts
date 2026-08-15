#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname -- "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

PYTHON=".venv/bin/python"
PREVIEW_DIR="TMP"

GAMMA_VALUE="2.2"
PREVIEW_EXPOSURE="0.0"
BLACK_PERCENTILE="1.0"
WHITE_PERCENTILE="99.0"

log() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        printf '\033[32m[preview]\033[37m %s\033[0m\n' "$*"
    else
        printf '[preview] %s\n' "$*"
    fi
}
die() { log "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; log "ERROR: command failed (exit=$rc)" >&2; exit "$rc"' ERR

mkdir -p "$PREVIEW_DIR"

[[ -x "$PYTHON" ]] || die "missing Python executable: $PYTHON (run ./scripts/setup.sh)"
[[ -x "$SCRIPT_DIR/raw-scan.sh" ]] || die "missing scan script: $SCRIPT_DIR/raw-scan.sh"

RAW="$PREVIEW_DIR/preview-raw.tif"
OUTPUT="$PREVIEW_DIR/preview.jpg"
rm -f "$RAW" "$OUTPUT"

"$SCRIPT_DIR/raw-scan.sh" --preview

log "convert negative, auto-level ${BLACK_PERCENTILE}/${WHITE_PERCENTILE}, gamma=${GAMMA_VALUE}"
"$PYTHON" "$SCRIPT_DIR/preview.py" "$RAW" "$OUTPUT" \
    --gamma "$GAMMA_VALUE" \
    --exposure "$PREVIEW_EXPOSURE" \
    --black-percentile "$BLACK_PERCENTILE" \
    --white-percentile "$WHITE_PERCENTILE"
rm -f "$RAW"

log "done output=$OUTPUT"

# Open the result when running in a desktop session. Failure to find a viewer
# must not turn an otherwise successful preview into an error.
if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$OUTPUT" >/dev/null 2>&1 &
fi
