#!/usr/bin/env bash

set -euo pipefail

RAW_DIR="RAW"
RESOLUTION="3600"
IR_ENABLED="yes"

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

configure() {
    local answer ir_label

    while true; do
        ir_label="$([[ "$IR_ENABLED" == "yes" ]] && echo on || echo off)"
        printf '\n%b[setup]%b resolution=%s dpi, IR=%s — [1] 3600, [2] 7200, [I] toggle IR, [Enter] done: %b' \
            "$GREEN" "$WHITE" "$RESOLUTION" "$ir_label" "$RESET"
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
            I|i)
                if [[ "$IR_ENABLED" == "yes" ]]; then
                    IR_ENABLED="no"
                    log "IR disabled (RGB only)"
                else
                    IR_ENABLED="yes"
                    log "IR enabled"
                fi
                ;;
            "")
                return
                ;;
            *)
                log "unknown choice; use 1/3600, 2/7200, I or Enter"
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

while true; do
    num=$(printf "%03d" "$next_num")

    ir_label="$([[ "$IR_ENABLED" == "yes" ]] && echo IR || echo RGB-only)"
    printf '\n%b[loop]%b frame %s (%s dpi, %s) — [Enter/N] scan and process, [P] preview, [S] setup, [Q] quit: %b' \
        "$GREEN" "$WHITE" "$num" "$RESOLUTION" "$ir_label" "$RESET"
    read -r answer

    case "${answer:-N}" in
        N|n|"")
            RESOLUTION="$RESOLUTION" IR_ENABLED="$IR_ENABLED" ./raw-scan.sh "$next_num"
            IR_ENABLED="$IR_ENABLED" ./process-scan.sh "$next_num"
            next_num=$((next_num + 1))
            ;;
        P|p)
            ./preview-scan.sh
            ;;
        S|s)
            configure
            ;;
        Q|q)
            log "done"
            exit 0
            ;;
        *)
            log "unknown choice; use Enter/N, P, S or Q"
            ;;
    esac
done
