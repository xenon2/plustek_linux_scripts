#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname -- "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

#
# ==========================================
# TWEAKABLE PARAMETERS
# ==========================================
#

PYTHON=".venv/bin/python"

RAW_DIR="RAW"
TMP_DIR="TMP"
DONE_DIR="DONE"

# detect_scratch.py
MASK_CHANNEL="0"
MASK_THRESHOLD_LOW="45000"
MASK_THRESHOLD_HIGH="53000"
MASK_DILATE="0"

# estimate_offset.py
AUTO_OFFSET="yes"
OFFSET_MAX_SHIFT="100"

# fallback if AUTO_OFFSET=no
MASK_OFFSET_X="0"
MASK_OFFSET_Y="-10"

# inpaint.py
INPAINT_RADIUS="2"
INPAINT_DILATE="1"
INPAINT_METHOD="telea"

# gamma22.py
GAMMA_VALUE="2.2"

# May be overridden by scan-loop.sh or the caller.
IR_ENABLED="${IR_ENABLED:-yes}"

# cleanup
KEEP_TMP="no"

#
# ==========================================
# END PARAMETERS
# ==========================================
#

print_log() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        printf '\033[32m[%s]\033[37m %s\033[0m\n' "$1" "$2"
    else
        printf '[%s] %s\n' "$1" "$2"
    fi
}

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+$ ]]; then
    print_log "process" "ERROR: usage: $0 <scan-number>" >&2
    exit 1
fi

NUM=$(printf "%03d" "$((10#$1))")
TAG="process ${NUM}"
log() { print_log "$TAG" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; log "ERROR: command failed (exit=$rc)" >&2; exit "$rc"' ERR

mkdir -p "$TMP_DIR" "$DONE_DIR"

RGB="$RAW_DIR/scan-${NUM}-rgb.tif"
IR="$RAW_DIR/scan-${NUM}-ir.tif"

GAMMA="$TMP_DIR/scan-${NUM}-gamma.tif"
FINAL="$DONE_DIR/scan-${NUM}.tif"

#
# validation
#

[[ -x "$PYTHON" ]] || die "missing Python executable: $PYTHON (run ./scripts/setup.sh)"
[[ -f "$RGB" ]] || die "missing RGB file: $RGB"
[[ "$IR_ENABLED" == "yes" || "$IR_ENABLED" == "no" ]] || \
    die "IR_ENABLED must be yes or no"
command -v tiffcrop >/dev/null 2>&1 || \
    die "missing tiffcrop (install package: libtiff-tools)"

if [[ "$IR_ENABLED" == "no" ]]; then
    log "start rgb=$RGB ir=disabled"
    log "1/2 apply gamma=${GAMMA_VALUE}"
    "$PYTHON" "$SCRIPT_DIR/gamma22.py" "$RGB" "$GAMMA" --gamma "$GAMMA_VALUE"

    log "2/2 mirror horizontally"
    tiffcrop -F horiz "$GAMMA" "$FINAL"

    [[ "$KEEP_TMP" == "yes" ]] || rm -f "$GAMMA"
    log "done output=$FINAL ir=disabled raw=preserved"
    exit 0
fi

[[ -f "$IR" ]] || die "missing IR file: $IR"
log "start rgb=$RGB ir=$IR"

# Estimate alignment once, then create conservative and aggressive variants.
if [[ "$AUTO_OFFSET" == "yes" ]]; then
    log "1/2 estimate RGB/IR offset"

    read -r MASK_OFFSET_X MASK_OFFSET_Y < <(
        "$PYTHON" "$SCRIPT_DIR/estimate_offset.py" \
            "$RGB" \
            "$IR" \
            --channel "$MASK_CHANNEL" \
            --max-shift "$OFFSET_MAX_SHIFT"
    )

    log "offset=(${MASK_OFFSET_X},${MASK_OFFSET_Y}) source=automatic"
else
    log "1/2 use fixed offset=(${MASK_OFFSET_X},${MASK_OFFSET_Y})"
fi

process_variant() {
    local label="$1"
    local threshold="$2"
    local mask="$TMP_DIR/scan-${NUM}-${label}-mask.png"
    local clean="$TMP_DIR/scan-${NUM}-${label}-clean.tif"
    local gamma="$TMP_DIR/scan-${NUM}-${label}-gamma.tif"
    local final="$DONE_DIR/scan-${NUM}-scratch-${label}.tif"

    log "2/2 variant=${label} threshold=${threshold}: detect defects"
    "$PYTHON" "$SCRIPT_DIR/detect_scratch.py" \
        "$IR" \
        "$mask" \
        --channel "$MASK_CHANNEL" \
        --threshold "$threshold" \
        --dilate "$MASK_DILATE"

    log "variant=${label}: inpaint"
    "$PYTHON" "$SCRIPT_DIR/inpaint.py" \
        "$RGB" \
        "$mask" \
        "$clean" \
        --dx "$MASK_OFFSET_X" \
        --dy "$MASK_OFFSET_Y" \
        --radius "$INPAINT_RADIUS" \
        --dilate "$INPAINT_DILATE" \
        --method "$INPAINT_METHOD"

    log "variant=${label}: apply gamma=${GAMMA_VALUE}"
    "$PYTHON" "$SCRIPT_DIR/gamma22.py" \
        "$clean" \
        "$gamma" \
        --gamma "$GAMMA_VALUE"

    log "variant=${label}: mirror horizontally"
    tiffcrop -F horiz "$gamma" "$final"

    if [[ "$KEEP_TMP" != "yes" ]]; then
        rm -f "$mask" "$clean" "$gamma"
    fi

    log "variant=${label} done output=$final"
}

process_variant "low" "$MASK_THRESHOLD_LOW"
process_variant "high" "$MASK_THRESHOLD_HIGH"

log "done outputs=$DONE_DIR/scan-${NUM}-scratch-{low,high}.tif temp=$([[ "$KEEP_TMP" == "yes" ]] && echo kept || echo removed) raw=preserved"
