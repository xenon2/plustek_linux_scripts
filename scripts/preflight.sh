#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
cd "$PROJECT_ROOT"

# shellcheck source=load-config.sh
source "$SCRIPTS_DIR/load-config.sh"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    GREEN='\033[32m'
    RED='\033[31m'
    WHITE='\033[37m'
    RESET='\033[0m'
else
    GREEN=''
    RED=''
    WHITE=''
    RESET=''
fi

log() { printf '%b[check]%b %s%b\n' "$GREEN" "$WHITE" "$*" "$RESET"; }

status() {
    local name=$1 result=$2 color=$3 detail=${4:-}
    if [[ -n "$detail" ]]; then
        printf '%b[check]%b %s %b[%s]%b — %s\n' \
            "$GREEN" "$WHITE" "$name" "$color" "$result" "$RESET" "$detail"
    else
        printf '%b[check]%b %s %b[%s]%b\n' \
            "$GREEN" "$WHITE" "$name" "$color" "$result" "$RESET"
    fi
}

main() {
    local missing=0 scripts_missing=0 scanner_output module label
    local required_scripts=(
        raw-scan.sh process-scan.sh preview-scan.sh
        merge_multiscan.py estimate_offset.py detect_scratch.py inpaint.py gamma22.py preview.py
    )

    status "configuration" "OK" "$GREEN" "$CONFIG_FILE"

    if [[ ! "$MULTISCAN_COUNT" =~ ^[0-9]+$ ]] || \
        (( 10#$MULTISCAN_COUNT < 1 || 10#$MULTISCAN_COUNT > 16 )); then
        status "MULTISCAN_COUNT" "INVALID" "$RED" "must be from 1 through 16"
        missing=1
    fi

    for module in sed head awk tiffcrop; do
        if command -v "$module" >/dev/null 2>&1; then
            status "$module" "OK" "$GREEN"
        else
            status "$module" "MISSING" "$RED"
            missing=1
        fi
    done

    if [[ -x "$SCANIMAGE" ]] && "$SCANIMAGE" --version >/dev/null 2>&1; then
        status "scanimage" "OK" "$GREEN" "$SCANIMAGE"
        scanner_output=$("$SCANIMAGE" -L 2>&1 || true)
        if [[ "$scanner_output" == *"device \`"* ]]; then
            status "scanner" "OK" "$GREEN" "SANE device detected"
        else
            status "scanner" "MISSING" "$RED" "no SANE device detected"
            missing=1
        fi
    else
        status "scanimage" "MISSING" "$RED" "$SCANIMAGE"
        status "scanner" "MISSING" "$RED" "scanimage is unavailable"
        missing=1
    fi

    if [[ -x "$PYTHON" ]]; then
        status "Python" "OK" "$GREEN" "$PYTHON"
        for module in numpy cv2 tifffile; do
            case "$module" in
                numpy) label="NumPy" ;;
                cv2) label="OpenCV" ;;
                tifffile) label="TIFFFile" ;;
            esac
            if "$PYTHON" -c "import $module" >/dev/null 2>&1; then
                status "$label" "OK" "$GREEN"
            else
                status "$label" "MISSING" "$RED" "run ./scripts/setup.sh"
                missing=1
            fi
        done
    else
        status "Python environment" "MISSING" "$RED" "$PYTHON (run ./scripts/setup.sh)"
        missing=1
    fi

    for module in "${required_scripts[@]}"; do
        if [[ ! -r "$SCRIPTS_DIR/$module" ]] || \
            { [[ "$module" == *.sh ]] && [[ ! -x "$SCRIPTS_DIR/$module" ]]; }; then
            status "$module" "MISSING" "$RED" "$SCRIPTS_DIR/$module"
            missing=1
            scripts_missing=1
        fi
    done
    if (( scripts_missing == 0 )); then
        status "pipeline scripts" "OK" "$GREEN"
    fi

    for module in "$RAW_DIR" "$TMP_DIR" "$DONE_DIR"; do
        if mkdir -p -- "$module" 2>/dev/null && [[ -d "$module" && -w "$module" ]]; then
            status "directory $module" "OK" "$GREEN"
        else
            status "directory $module" "ERROR" "$RED" "cannot create or write"
            missing=1
        fi
    done

    if (( missing != 0 )); then
        log "ERROR: startup check failed"
        return 1
    fi
}

main "$@"
