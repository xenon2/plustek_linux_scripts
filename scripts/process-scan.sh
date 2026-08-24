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

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+$ ]]; then
    print_log "process" "ERROR: usage: $0 <scan-number>" >&2
    exit 1
fi

NUM=$(printf "%03d" "$((10#$1))")
TAG="process ${NUM}"
log() { print_log "$TAG" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

PENDING_FINAL=""
cleanup() {
    rm -f -- "$PENDING_FINAL"
}
publish_mirrored() {
    local input=$1
    local destination=$2

    [[ ! -e "$destination" ]] || die "output already exists: $destination"
    PENDING_FINAL="${destination%.tif}.tmp.$$.tif"
    [[ ! -e "$PENDING_FINAL" ]] || die "temporary output already exists: $PENDING_FINAL"

    tiffcrop -F horiz "$input" "$PENDING_FINAL"
    [[ -s "$PENDING_FINAL" ]] || die "processing produced no data: $destination"
    mv -n -- "$PENDING_FINAL" "$destination"
    [[ ! -e "$PENDING_FINAL" ]] || die "output appeared while processing: $destination"
    PENDING_FINAL=""
}
trap cleanup EXIT
trap 'rc=$?; log "ERROR: command failed (exit=$rc)" >&2; exit "$rc"' ERR

mkdir -p "$TMP_DIR" "$DONE_DIR"

RGB="$RAW_DIR/scan-${NUM}-rgb.tif"
IR="$RAW_DIR/scan-${NUM}-ir.tif"
CAPTURE_MANIFEST="$RAW_DIR/scan-${NUM}-capture.ini"
MERGED_RGB="$TMP_DIR/scan-${NUM}-rgb-merged.tif"
RGB_OFFSETS="$TMP_DIR/scan-${NUM}-rgb-offsets.tsv"

GAMMA="$TMP_DIR/scan-${NUM}-gamma.tif"
FINAL="$DONE_DIR/scan-${NUM}.tif"

manifest_value() {
    local wanted=$1 key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        if [[ "$key" == "$wanted" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$CAPTURE_MANIFEST"
    return 1
}

if [[ -f "$CAPTURE_MANIFEST" ]]; then
    [[ "$(manifest_value STATUS || true)" == "complete" ]] || \
        die "capture is incomplete: $CAPTURE_MANIFEST"
    MULTISCAN_COUNT="$(manifest_value MULTISCAN_COUNT || true)"
fi

#
# validation
#

[[ -x "$PYTHON" ]] || die "missing Python executable: $PYTHON (run ./scripts/setup.sh)"
if [[ ! "$MULTISCAN_COUNT" =~ ^[0-9]+$ ]] || \
    (( 10#$MULTISCAN_COUNT < 1 || 10#$MULTISCAN_COUNT > 16 )); then
    die "MULTISCAN_COUNT must be from 1 through 16"
fi
MULTISCAN_COUNT=$((10#$MULTISCAN_COUNT))
RGB_PHASES=("$RGB")
for (( phase = 2; phase <= MULTISCAN_COUNT; phase++ )); do
    RGB_PHASES+=("$RAW_DIR/scan-${NUM}-rgb-$(printf '%02d' "$phase").tif")
done
for phase_path in "${RGB_PHASES[@]}"; do
    [[ -f "$phase_path" ]] || die "missing RGB phase: $phase_path"
done
[[ "$IR_ENABLED" == "yes" || "$IR_ENABLED" == "no" ]] || \
    die "IR_ENABLED must be yes or no"
[[ "$SCRATCH_LEVEL" == "low" || "$SCRATCH_LEVEL" == "high" ]] || \
    die "SCRATCH_LEVEL must be low or high"
command -v tiffcrop >/dev/null 2>&1 || \
    die "missing tiffcrop (install package: libtiff-tools)"

if [[ "$IR_ENABLED" == "no" ]]; then
    OUTPUT="$FINAL"
else
    OUTPUT="$DONE_DIR/scan-${NUM}-scratch-${SCRATCH_LEVEL}.tif"
fi
[[ ! -e "$OUTPUT" ]] || die "output already exists: $OUTPUT"

RGB_INPUT="$RGB"
if (( MULTISCAN_COUNT > 1 )); then
    log "multiscan: align and average ${MULTISCAN_COUNT} RGB captures"
    rm -f -- "$MERGED_RGB"
    "$PYTHON" "$SCRIPT_DIR/merge_multiscan.py" \
        "${RGB_PHASES[@]}" \
        --output "$MERGED_RGB" \
        --offsets-file "$RGB_OFFSETS" \
        --max-shift "$RGB_ALIGN_MAX_SHIFT" \
        --min-response "$RGB_ALIGN_MIN_RESPONSE" \
        --proxy-size "$RGB_ALIGN_PROXY_SIZE" \
        --strip-rows "$RGB_MERGE_STRIP_ROWS"
    RGB_INPUT="$MERGED_RGB"
fi

if [[ "$IR_ENABLED" == "no" ]]; then
    log "start rgb=$RGB_INPUT phases=${MULTISCAN_COUNT} ir=disabled"
    log "1/2 apply gamma=${GAMMA_VALUE}"
    "$PYTHON" "$SCRIPT_DIR/gamma22.py" "$RGB_INPUT" "$GAMMA" --gamma "$GAMMA_VALUE"

    log "2/2 mirror horizontally"
    publish_mirrored "$GAMMA" "$FINAL"

    [[ "$KEEP_TMP" == "yes" ]] || rm -f "$GAMMA" "$MERGED_RGB" "$RGB_OFFSETS"
    log "done output=$FINAL ir=disabled raw=preserved"
    exit 0
fi

[[ -f "$IR" ]] || die "missing IR file: $IR"
log "start rgb=$RGB_INPUT phases=${MULTISCAN_COUNT} ir=$IR"

# Estimate alignment once, then create the selected scratch-removal variant.
if [[ "$AUTO_OFFSET" == "yes" ]]; then
    log "1/2 estimate RGB/IR offset"

    read -r MASK_OFFSET_X MASK_OFFSET_Y < <(
        "$PYTHON" "$SCRIPT_DIR/estimate_offset.py" \
            "$RGB_INPUT" \
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
    local local_threshold="$MASK_LOCAL_THRESHOLD_LOW"
    local inpaint_radius="$INPAINT_RADIUS"
    local inpaint_dilate="$INPAINT_DILATE"
    local mask="$TMP_DIR/scan-${NUM}-${label}-mask.png"

    if [[ "$label" == "high" ]]; then
        local_threshold="$MASK_LOCAL_THRESHOLD_HIGH"
        inpaint_radius="$INPAINT_RADIUS_HIGH"
        inpaint_dilate="$INPAINT_DILATE_HIGH"
    fi
    local clean="$TMP_DIR/scan-${NUM}-${label}-clean.tif"
    local gamma="$TMP_DIR/scan-${NUM}-${label}-gamma.tif"
    local repaired_percent_file="$TMP_DIR/scan-${NUM}-${label}-repaired-percent.txt"
    local final="$DONE_DIR/scan-${NUM}-scratch-${label}.tif"

    log "2/2 variant=${label} threshold=${threshold}: detect defects"
    "$PYTHON" "$SCRIPT_DIR/detect_scratch.py" \
        "$IR" \
        "$mask" \
        --channel "$MASK_CHANNEL" \
        --threshold "$threshold" \
        --dilate "$MASK_DILATE" \
        --local-radius "$MASK_LOCAL_RADIUS" \
        --local-threshold "$local_threshold" \
        --local-min-area "$MASK_LOCAL_MIN_AREA"

    log "variant=${label}: inpaint"
    "$PYTHON" "$SCRIPT_DIR/inpaint.py" \
        "$RGB_INPUT" \
        "$mask" \
        "$clean" \
        --dx "$MASK_OFFSET_X" \
        --dy "$MASK_OFFSET_Y" \
        --radius "$inpaint_radius" \
        --dilate "$inpaint_dilate" \
        --method "$INPAINT_METHOD" \
        --repaired-percent-file "$repaired_percent_file"

    [[ -s "$repaired_percent_file" ]] || \
        die "inpainting did not report repaired percentage for variant=${label}"
    REPAIRED_PERCENT=$(<"$repaired_percent_file")
    if awk -v value="$REPAIRED_PERCENT" -v limit="$REPAIR_WARNING_PERCENT" \
        'BEGIN { exit !(value > limit) }'; then
        log "WARNING: variant=${label} repaired ${REPAIRED_PERCENT}% of the image (limit=${REPAIR_WARNING_PERCENT}%)"
    fi

    log "variant=${label}: apply gamma=${GAMMA_VALUE}"
    "$PYTHON" "$SCRIPT_DIR/gamma22.py" \
        "$clean" \
        "$gamma" \
        --gamma "$GAMMA_VALUE"

    log "variant=${label}: mirror horizontally"
    publish_mirrored "$gamma" "$final"

    if [[ "$KEEP_TMP" != "yes" ]]; then
        rm -f "$mask" "$clean" "$gamma" "$repaired_percent_file"
    fi

    log "variant=${label} done output=$final"
}

if [[ "$SCRATCH_LEVEL" == "low" ]]; then
    MASK_THRESHOLD="$MASK_THRESHOLD_LOW"
else
    MASK_THRESHOLD="$MASK_THRESHOLD_HIGH"
fi

process_variant "$SCRATCH_LEVEL" "$MASK_THRESHOLD"
SELECTED_REPAIRED_PERCENT="$REPAIRED_PERCENT"

if [[ "$SCRATCH_LEVEL" == "high" ]] && \
    awk -v value="$SELECTED_REPAIRED_PERCENT" -v limit="$REPAIR_WARNING_PERCENT" \
        'BEGIN { exit !(value > limit) }'; then
    LOW_OUTPUT="$DONE_DIR/scan-${NUM}-scratch-low.tif"
    if [[ -e "$LOW_OUTPUT" ]]; then
        log "WARNING: conservative fallback already exists, not replacing: $LOW_OUTPUT"
    else
        log "high repair coverage detected; generating conservative low variant from the same raw files"
        process_variant "low" "$MASK_THRESHOLD_LOW"
    fi
fi

if [[ "$KEEP_TMP" != "yes" ]]; then
    rm -f "$MERGED_RGB" "$RGB_OFFSETS"
fi
log "done output=$DONE_DIR/scan-${NUM}-scratch-${SCRATCH_LEVEL}.tif temp=$([[ "$KEEP_TMP" == "yes" ]] && echo kept || echo removed) raw=preserved"
