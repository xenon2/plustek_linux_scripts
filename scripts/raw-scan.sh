#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname -- "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# shellcheck source=load-config.sh
source "$SCRIPT_DIR/load-config.sh"

print_log() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        printf '\033[32m[%s]\033[37m %s\033[0m\n' "$1" "$2"
    else
        printf '[%s] %s\n' "$1" "$2"
    fi
}

if [[ $# -ne 1 || ( "$1" != "--preview" && ! "$1" =~ ^[0-9]+$ ) ]]; then
    print_log "scan" "ERROR: usage: $0 <scan-number>|--preview" >&2
    exit 1
fi

if [[ "$1" == "--preview" ]]; then
    TAG="preview scan"
    RESOLUTION="$PREVIEW_RESOLUTION"
    IR_ENABLED="no"
    RGB="TMP/preview-raw.tif"
    IR=""
else
    if [[ "$RESOLUTION" != "3600" && "$RESOLUTION" != "7200" ]]; then
        print_log "scan" "ERROR: resolution must be 3600 or 7200 dpi" >&2
        exit 1
    fi
    if [[ "$IR_ENABLED" != "yes" && "$IR_ENABLED" != "no" ]]; then
        print_log "scan" "ERROR: IR_ENABLED must be yes or no" >&2
        exit 1
    fi

    NUM=$(printf "%03d" "$((10#$1))")
    TAG="scan ${NUM}"
    RGB="$RAW_DIR/scan-${NUM}-rgb.tif"
    IR="$RAW_DIR/scan-${NUM}-ir.tif"
fi

log() { print_log "$TAG" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

RGB_TMP=""
IR_TMP=""
cleanup() {
    rm -f -- "$RGB_TMP" "$IR_TMP"
}
publish() {
    local temporary=$1
    local destination=$2

    [[ -s "$temporary" ]] || die "scan produced no data: $destination"
    # -n prevents a concurrent scan from replacing an output created after the
    # initial existence check. A successful move removes the temporary file.
    mv -n -- "$temporary" "$destination"
    [[ ! -e "$temporary" ]] || die "output appeared while scanning: $destination"
}
trap cleanup EXIT
trap 'rc=$?; log "ERROR: command failed (exit=$rc)" >&2; exit "$rc"' ERR

mkdir -p "$RAW_DIR" "$(dirname "$RGB")"

[[ -x "$SCANIMAGE" ]] || die "missing scanimage executable: $SCANIMAGE"

DEVICE="$("$SCANIMAGE" -L | sed -n "s/.*device \`\([^']*\)'.*/\1/p" | head -1)"
[[ -n "$DEVICE" ]] || die "scanner not found"

if [[ "$1" == "--preview" ]]; then
    rm -f "$RGB"
elif [[ -e "$RGB" || -e "$IR" ]]; then
    die "output already exists for scan $NUM"
fi

# Scan into the destination directory so publishing with mv is atomic. Failed
# scans are removed by the EXIT trap and never become visible in RAW/.
RGB_TMP="${RGB%.tif}.tmp.$$.tif"
if [[ "$IR_ENABLED" == "yes" ]]; then
    IR_TMP="${IR%.tif}.tmp.$$.tif"
fi
[[ ! -e "$RGB_TMP" && ( -z "$IR_TMP" || ! -e "$IR_TMP" ) ]] || \
    die "temporary scan output already exists"

log "start device=$DEVICE resolution=${RESOLUTION}dpi depth=${DEPTH}-bit area=${WIDTH_MM}x${HEIGHT_MM}mm ir=$IR_ENABLED"
log "$([[ "$IR_ENABLED" == "yes" ]] && echo 1/2 || echo 1/1) RGB -> $RGB"

"$SCANIMAGE" \
    -d "$DEVICE" \
    --source "$SOURCE_RGB" \
    --mode "$MODE_RGB" \
    --depth "$DEPTH" \
    --resolution "$RESOLUTION" \
    -l "$LEFT_MM" \
    -t "$TOP_MM" \
    -x "$WIDTH_MM" \
    -y "$HEIGHT_MM" \
    --custom-gamma="$CUSTOM_GAMMA" \
    --format=tiff \
    -o "$RGB_TMP"

if [[ "$IR_ENABLED" == "yes" ]]; then
    log "2/2 IR -> $IR"

    "$SCANIMAGE" \
        -d "$DEVICE" \
        --source "$SOURCE_IR" \
        --mode "$MODE_IR" \
        --depth "$DEPTH" \
        --resolution "$RESOLUTION" \
        -l "$LEFT_MM" \
        -t "$TOP_MM" \
        -x "$WIDTH_MM" \
        -y "$HEIGHT_MM" \
        --custom-gamma="$CUSTOM_GAMMA" \
        --format=tiff \
        -o "$IR_TMP"

    publish "$RGB_TMP" "$RGB"
    RGB_TMP=""
    publish "$IR_TMP" "$IR"
    IR_TMP=""
    log "done rgb=$RGB ir=$IR"
else
    publish "$RGB_TMP" "$RGB"
    RGB_TMP=""
    log "done rgb=$RGB ir=disabled"
fi
