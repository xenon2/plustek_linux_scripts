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

PREVIEW=no
if [[ "$1" == "--preview" ]]; then
    PREVIEW=yes
    TAG="preview scan"
    RESOLUTION="$PREVIEW_RESOLUTION"
    IR_ENABLED="no"
    MULTISCAN_COUNT=1
    RGB="TMP/preview-raw.tif"
    IR=""
    MANIFEST=""
else
    if [[ "$RESOLUTION" != "3600" && "$RESOLUTION" != "7200" ]]; then
        print_log "scan" "ERROR: resolution must be 3600 or 7200 dpi" >&2
        exit 1
    fi
    if [[ "$IR_ENABLED" != "yes" && "$IR_ENABLED" != "no" ]]; then
        print_log "scan" "ERROR: IR_ENABLED must be yes or no" >&2
        exit 1
    fi
    if [[ ! "$MULTISCAN_COUNT" =~ ^[0-9]+$ ]] || \
        (( 10#$MULTISCAN_COUNT < 1 || 10#$MULTISCAN_COUNT > 16 )); then
        print_log "scan" "ERROR: MULTISCAN_COUNT must be from 1 through 16" >&2
        exit 1
    fi
    MULTISCAN_COUNT=$((10#$MULTISCAN_COUNT))

    NUM=$(printf "%03d" "$((10#$1))")
    TAG="scan ${NUM}"
    RGB="$RAW_DIR/scan-${NUM}-rgb.tif"
    IR="$RAW_DIR/scan-${NUM}-ir.tif"
    MANIFEST="$RAW_DIR/scan-${NUM}-capture.ini"
fi

log() { print_log "$TAG" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

ACTIVE_TMP=""
MANIFEST_TMP=""
cleanup() {
    rm -f -- "$ACTIVE_TMP" "$MANIFEST_TMP"
}
publish() {
    local temporary=$1
    local destination=$2

    [[ -s "$temporary" ]] || die "scan produced no data: $destination"
    mv -n -- "$temporary" "$destination"
    [[ ! -e "$temporary" ]] || die "output appeared while scanning: $destination"
}
manifest_value() {
    local wanted=$1 key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        if [[ "$key" == "$wanted" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$MANIFEST"
    return 1
}
write_manifest() {
    local status=$1
    MANIFEST_TMP="${MANIFEST}.tmp.$$"
    printf 'STATUS=%s\nMULTISCAN_COUNT=%s\nRESOLUTION=%s\nIR_ENABLED=%s\n' \
        "$status" "$MULTISCAN_COUNT" "$RESOLUTION" "$IR_ENABLED" > "$MANIFEST_TMP"
    mv -f -- "$MANIFEST_TMP" "$MANIFEST"
    MANIFEST_TMP=""
}
scan_rgb() {
    local destination=$1 phase=$2 step=$3 total=$4

    if [[ -s "$destination" ]]; then
        log "${step}/${total} RGB phase ${phase}/${MULTISCAN_COUNT} already captured; resume"
        return
    fi
    [[ ! -e "$destination" ]] || die "empty RGB phase exists: $destination"

    ACTIVE_TMP="${destination%.tif}.tmp.$$.tif"
    [[ ! -e "$ACTIVE_TMP" ]] || die "temporary scan output already exists: $ACTIVE_TMP"
    log "${step}/${total} RGB phase ${phase}/${MULTISCAN_COUNT} -> $destination"
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
        -o "$ACTIVE_TMP"
    publish "$ACTIVE_TMP" "$destination"
    ACTIVE_TMP=""
}
trap cleanup EXIT
trap 'rc=$?; log "ERROR: command failed (exit=$rc)" >&2; exit "$rc"' ERR

mkdir -p "$RAW_DIR" "$(dirname "$RGB")"

[[ -x "$SCANIMAGE" ]] || die "missing scanimage executable: $SCANIMAGE"

DEVICE="$("$SCANIMAGE" -L | sed -n "s/.*device \`\([^']*\)'.*/\1/p" | head -1)"
[[ -n "$DEVICE" ]] || die "scanner not found"

if [[ "$PREVIEW" == "yes" ]]; then
    rm -f "$RGB"
else
    if [[ -e "$MANIFEST" ]]; then
        [[ "$(manifest_value STATUS || true)" == "incomplete" ]] || \
            die "capture already complete for scan $NUM"
        [[ "$(manifest_value MULTISCAN_COUNT || true)" == "$MULTISCAN_COUNT" ]] || \
            die "cannot resume: multiscan count differs from capture manifest"
        [[ "$(manifest_value RESOLUTION || true)" == "$RESOLUTION" ]] || \
            die "cannot resume: resolution differs from capture manifest"
        [[ "$(manifest_value IR_ENABLED || true)" == "$IR_ENABLED" ]] || \
            die "cannot resume: IR setting differs from capture manifest"
        log "resuming incomplete capture"
    else
        [[ ! -e "$RGB" && ! -e "$IR" ]] || die "output already exists for scan $NUM"
        for (( phase = 2; phase <= MULTISCAN_COUNT; phase++ )); do
            phase_path="$RAW_DIR/scan-${NUM}-rgb-$(printf '%02d' "$phase").tif"
            [[ ! -e "$phase_path" ]] || die "output already exists: $phase_path"
        done
        write_manifest incomplete
    fi
fi

TOTAL=$MULTISCAN_COUNT
if [[ "$IR_ENABLED" == "yes" ]]; then
    TOTAL=$((TOTAL + 1))
fi
log "start device=$DEVICE resolution=${RESOLUTION}dpi depth=${DEPTH}-bit area=${WIDTH_MM}x${HEIGHT_MM}mm rgb=${MULTISCAN_COUNT}x ir=$IR_ENABLED"

for (( phase = 1; phase <= MULTISCAN_COUNT; phase++ )); do
    if (( phase == 1 )); then
        phase_path="$RGB"
    else
        phase_path="$RAW_DIR/scan-${NUM}-rgb-$(printf '%02d' "$phase").tif"
    fi
    scan_rgb "$phase_path" "$phase" "$phase" "$TOTAL"
done

if [[ "$IR_ENABLED" == "yes" ]]; then
    if [[ -s "$IR" ]]; then
        log "${TOTAL}/${TOTAL} IR already captured; resume"
    else
        [[ ! -e "$IR" ]] || die "empty IR scan exists: $IR"
        ACTIVE_TMP="${IR%.tif}.tmp.$$.tif"
        [[ ! -e "$ACTIVE_TMP" ]] || die "temporary scan output already exists: $ACTIVE_TMP"
        log "${TOTAL}/${TOTAL} IR -> $IR"
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
            -o "$ACTIVE_TMP"
        publish "$ACTIVE_TMP" "$IR"
        ACTIVE_TMP=""
    fi
fi

if [[ "$PREVIEW" == "no" ]]; then
    write_manifest complete
fi
log "done rgb=${MULTISCAN_COUNT}x ir=$IR_ENABLED raw=preserved"
