#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
cd "$PROJECT_ROOT"

# shellcheck source=scripts/load-config.sh
source "$SCRIPTS_DIR/load-config.sh"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    GREEN='\033[32m'
    WHITE='\033[37m'
    RESET='\033[0m'
else
    GREEN=''
    WHITE=''
    RESET=''
fi

log() { printf '%b[loop]%b %s%b\n' "$GREEN" "$WHITE" "$*" "$RESET"; }

"$SCRIPTS_DIR/preflight.sh"
MULTISCAN_COUNT=$((10#$MULTISCAN_COUNT))

configure() {
    local answer ir_label multiscan_answer

    while true; do
        ir_label="$([[ "$IR_ENABLED" == "yes" ]] && echo on || echo off)"
        printf '\n%b[setup]%b resolution=%s dpi, RGB=%sx, IR=%s, scratch=%s — [1] 3600, [2] 7200, [M] multiscan, [I] toggle IR, [L] low, [H] high, [Enter] done: %b' \
            "$GREEN" "$WHITE" "$RESOLUTION" "$MULTISCAN_COUNT" "$ir_label" "$SCRATCH_LEVEL" "$RESET"
        read -r answer

        case "$answer" in
            1|3600)
                RESOLUTION="3600"
                log "resolution set to ${RESOLUTION} dpi"
                ;;
            2|7200)
                RESOLUTION="7200"
                log "resolution set to ${RESOLUTION} dpi"
                ;;
            M|m)
                printf '%b[setup]%b RGB captures [1-16]: %b' "$GREEN" "$WHITE" "$RESET"
                read -r multiscan_answer
                if [[ "$multiscan_answer" =~ ^[0-9]+$ ]] && \
                    (( 10#$multiscan_answer >= 1 && 10#$multiscan_answer <= 16 )); then
                    MULTISCAN_COUNT=$((10#$multiscan_answer))
                    log "RGB multiscan set to ${MULTISCAN_COUNT}x"
                else
                    log "invalid RGB capture count; enter a number from 1 through 16"
                fi
                ;;
            I|i)
                if [[ "$IR_ENABLED" == "yes" ]]; then
                    IR_ENABLED="no"
                    log "IR disabled (RGB only)"
                else
                    IR_ENABLED="yes"
                    log "IR enabled"
                fi
                ;;
            L|l)
                SCRATCH_LEVEL="low"
                log "scratch level set to low"
                ;;
            H|h)
                SCRATCH_LEVEL="high"
                log "scratch level set to high"
                ;;
            "")
                return
                ;;
            *)
                log "unknown choice; use 1/3600, 2/7200, M, I, L, H or Enter"
                ;;
        esac
    done
}

mkdir -p "$RAW_DIR"

last_num=0
shopt -s nullglob

for f in "$RAW_DIR"/scan-*-rgb.tif; do
    base="$(basename "$f")"
    num="${base#scan-}"
    num="${num%-rgb.tif}"

    if [[ "$num" =~ ^[0-9]+$ ]]; then
        n=$((10#$num))
        if (( n > last_num )); then
            last_num=$n
        fi
    fi
done

shopt -u nullglob

next_num=$((last_num + 1))

delete_all_files() {
    local first_confirmation second_confirmation directory

    printf '\n%b[delete]%b Permanently delete ALL files in %s, %s, and %s? [y/N]: %b' \
        "$GREEN" "$WHITE" "$RAW_DIR" "$TMP_DIR" "$DONE_DIR" "$RESET"
    read -r first_confirmation
    if [[ "$first_confirmation" != "y" && "$first_confirmation" != "Y" ]]; then
        log "delete cancelled"
        return
    fi

    printf '%b[delete]%b Are you absolutely sure? This cannot be undone. [y/N]: %b' \
        "$GREEN" "$WHITE" "$RESET"
    read -r second_confirmation
    if [[ "$second_confirmation" != "y" && "$second_confirmation" != "Y" ]]; then
        log "delete cancelled"
        return
    fi

    for directory in "$RAW_DIR" "$TMP_DIR" "$DONE_DIR"; do
        find -- "$directory" -mindepth 1 \( -type f -o -type l \) -delete
    done
    next_num=1
    log "deleted all files in $RAW_DIR, $TMP_DIR, and $DONE_DIR"
}

while true; do
    num=$(printf "%03d" "$next_num")

    ir_label="$([[ "$IR_ENABLED" == "yes" ]] && echo "IR, scratch $SCRATCH_LEVEL" || echo RGB-only)"
    printf '\n%b[loop]%b frame %s (%s dpi, RGB %sx, %s) — [Enter/N] scan and process, [P]review, [S]etup, [D]elete all, [Q]uit: %b' \
        "$GREEN" "$WHITE" "$num" "$RESOLUTION" "$MULTISCAN_COUNT" "$ir_label" "$RESET"
    read -r answer

    case "${answer:-N}" in
        N|n|"")
            RESOLUTION="$RESOLUTION" IR_ENABLED="$IR_ENABLED" MULTISCAN_COUNT="$MULTISCAN_COUNT" \
                "$SCRIPTS_DIR/raw-scan.sh" "$next_num"
            IR_ENABLED="$IR_ENABLED" SCRATCH_LEVEL="$SCRATCH_LEVEL" MULTISCAN_COUNT="$MULTISCAN_COUNT" \
                "$SCRIPTS_DIR/process-scan.sh" "$next_num"
            next_num=$((next_num + 1))
            ;;
        P|p)
            "$SCRIPTS_DIR/preview-scan.sh"
            ;;
        S|s)
            configure
            ;;
        D|d)
            delete_all_files
            ;;
        Q|q)
            log "done"
            exit 0
            ;;
        *)
            log "unknown choice; use Enter/N, P, S, D or Q"
            ;;
    esac
done
