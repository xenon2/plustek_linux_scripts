#!/usr/bin/env bash

set -euo pipefail

VENV=".venv"
BUILD_VENV="${VENV}.setup.$$"
SCANIMAGE="/usr/local/bin/scanimage"

log() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        printf '\033[32m[setup]\033[37m %s\033[0m\n' "$*"
    else
        printf '[setup] %s\n' "$*"
    fi
}

cleanup() {
    local rc=$?
    rm -rf "$BUILD_VENV"
    if (( rc != 0 )); then
        log "ERROR: setup failed (exit=$rc)" >&2
    fi
}
trap cleanup EXIT

missing=0
require_command() {
    local command_name=$1
    local install_hint=$2

    if ! command -v "$command_name" >/dev/null 2>&1; then
        log "ERROR: missing $command_name ($install_hint)" >&2
        missing=1
    fi
}

log "check system dependencies"
require_command python3 "install package: python3"
require_command tiffcrop "install package: libtiff-tools"
require_command sed "install package: sed"
require_command head "install package: coreutils"
require_command basename "install package: coreutils"
require_command mkdir "install package: coreutils"
require_command rm "install package: coreutils"
require_command mv "install package: coreutils"

if [[ ! -x "$SCANIMAGE" ]]; then
    log "ERROR: missing scanimage executable: $SCANIMAGE (install/build sane-backends)" >&2
    missing=1
elif ! "$SCANIMAGE" --version >/dev/null 2>&1; then
    log "ERROR: scanimage is present but cannot run: $SCANIMAGE" >&2
    missing=1
fi

if (( missing != 0 )); then
    exit 1
fi

# Build separately so a failed venv creation or package install does not destroy
# an existing working environment.
log "check Python venv support"
if ! python3 -m venv "$BUILD_VENV"; then
    log "ERROR: cannot create a Python venv (install package: python3-venv)" >&2
    exit 1
fi

log "install Python dependencies"
"$BUILD_VENV/bin/python" -m pip install --quiet --upgrade pip
"$BUILD_VENV/bin/python" -m pip install --quiet "numpy<2" "opencv-python==4.11.0.86"

log "verify Python dependencies and image codecs"
versions=$("$BUILD_VENV/bin/python" <<'PY'
import os
import tempfile

import cv2
import numpy as np

required = ("inpaint", "phaseCorrelate", "Sobel", "warpAffine")
missing = [name for name in required if not hasattr(cv2, name)]
if missing:
    raise RuntimeError("OpenCV is missing required APIs: " + ", ".join(missing))

with tempfile.TemporaryDirectory() as directory:
    image16 = np.zeros((2, 2, 3), dtype=np.uint16)
    for extension in ("tif", "png"):
        path = os.path.join(directory, "test." + extension)
        if not cv2.imwrite(path, image16) or cv2.imread(path, cv2.IMREAD_UNCHANGED) is None:
            raise RuntimeError(f"OpenCV {extension.upper()} codec is unavailable")

    jpeg = os.path.join(directory, "test.jpg")
    if not cv2.imwrite(jpeg, image16.astype(np.uint8)):
        raise RuntimeError("OpenCV JPEG codec is unavailable")

print(f"NumPy={np.__version__} OpenCV={cv2.__version__}")
PY
)

log "activate clean environment: $VENV"
rm -rf "$VENV"
mv "$BUILD_VENV" "$VENV"
log "ready $versions"
