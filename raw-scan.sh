#!/usr/bin/env bash

set -euo pipefail

#
# =========================
# TWEAKABLE PARAMETERS
# =========================
#

SCANIMAGE="/usr/local/bin/scanimage"
RAW_DIR="RAW"

SOURCE_RGB="Transparency Adapter"
SOURCE_IR="Transparency Adapter Infrared"

MODE_RGB="Color"
MODE_IR="Color"

DEPTH="16"
# May be overridden by scan-loop.sh or the caller.
RESOLUTION="${RESOLUTION:-3600}"
IR_ENABLED="${IR_ENABLED:-yes}"

LEFT_MM="1"
TOP_MM="0"
WIDTH_MM="35"
HEIGHT_MM="24"

CUSTOM_GAMMA="no"

#
# =========================
# END PARAMETERS
# =========================
#

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
    RESOLUTION="900"
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
trap 'rc=$?; log "ERROR: command failed (exit=$rc)" >&2; exit "$rc"' ERR

mkdir -p "$RAW_DIR" "$(dirname "$RGB")"

[[ -x "$SCANIMAGE" ]] || die "missing scanimage executable: $SCANIMAGE"

DEVICE="$("$SCANIMAGE" -L | sed -n "s/.*device \`\([^']*\)'.*/\1/p" | head -1)"
[[ -n "$DEVICE" ]] || die "scanner not found"

if [[ "$1" == "--preview" ]]; then
    rm -f "$RGB"
elif [[ -e "$RGB" || ( "$IR_ENABLED" == "yes" && -e "$IR" ) ]]; then
    die "output already exists for scan $NUM"
fi

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
    -o "$RGB"

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
        -o "$IR"

    log "done rgb=$RGB ir=$IR"
else
    log "done rgb=$RGB ir=disabled"
fi
