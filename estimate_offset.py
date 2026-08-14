#!/usr/bin/env python3

import argparse
import sys

import cv2
import numpy as np

from scanlog import fail, log


COMPONENT = "offset"


def gradient_image(img):
    gx = cv2.Sobel(img, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(img, cv2.CV_32F, 0, 1, ksize=3)

    mag = cv2.magnitude(gx, gy)

    # suppress very weak gradients / noise
    mag = cv2.GaussianBlur(mag, (0, 0), 1.2)

    return mag


def main():
    p = argparse.ArgumentParser(
        description="Estimate RGB/IR translation offset using gradient phase correlation."
    )

    p.add_argument("rgb", help="RGB TIFF")
    p.add_argument("ir", help="IR TIFF")

    p.add_argument(
        "--channel",
        type=int,
        default=0,
        choices=[0, 1, 2],
        help="IR channel (default: 0)"
    )

    p.add_argument(
        "--max-shift",
        type=float,
        default=30,
        help="Reject offsets larger than this many pixels (default: 30)"
    )

    p.add_argument(
        "--debug",
        action="store_true",
        help="Print diagnostics to stderr"
    )

    args = p.parse_args()

    rgb = cv2.imread(args.rgb, cv2.IMREAD_UNCHANGED)
    ir = cv2.imread(args.ir, cv2.IMREAD_UNCHANGED)

    if rgb is None:
        fail(COMPONENT, f"cannot read RGB: {args.rgb}")

    if ir is None:
        fail(COMPONENT, f"cannot read IR: {args.ir}")

    if rgb.ndim != 3 or rgb.shape[2] != 3:
        fail(COMPONENT, f"unexpected RGB shape: {rgb.shape}")

    if ir.ndim == 3:
        ir = ir[:, :, args.channel]
    elif ir.ndim != 2:
        fail(COMPONENT, f"unexpected IR shape: {ir.shape}")

    if rgb.shape[:2] != ir.shape[:2]:
        fail(
            COMPONENT,
            f"geometry mismatch: RGB={rgb.shape[:2]} IR={ir.shape[:2]}"
        )

    #
    # Normalize into float32 0..1
    #

    rgbf = rgb.astype(np.float32) / 65535.0
    irf = ir.astype(np.float32) / 65535.0

    rgb_gray = cv2.cvtColor(rgbf, cv2.COLOR_BGR2GRAY)

    #
    # Remove slow tonal variation.
    # IR and RGB differ strongly photometrically, but edges should correspond.
    #

    rgb_grad = gradient_image(rgb_gray)
    ir_grad = gradient_image(irf)

    #
    # Hanning window reduces edge artifacts in phase correlation.
    #

    h, w = rgb_grad.shape

    window = cv2.createHanningWindow(
        (w, h),
        cv2.CV_32F
    )

    shift, response = cv2.phaseCorrelate(
        rgb_grad,
        ir_grad,
        window
    )

    dx, dy = shift

    if abs(dx) > args.max_shift or abs(dy) > args.max_shift:
        fail(
            COMPONENT,
            f"estimated shift outside allowed range: dx={dx:.3f} dy={dy:.3f}"
        )

    #
    # phaseCorrelate tells how image #2 is shifted relative to image #1.
    # For the mask we want to move IR-derived coordinates into RGB space.
    #

    mask_dx = int(round(-dx))
    mask_dy = int(round(-dy))

    if args.debug:
        log(
            COMPONENT,
            f"phase=({dx:.3f},{dy:.3f}) mask=({mask_dx},{mask_dy}) "
            f"response={response:.6f}",
            file=sys.stderr
        )

    # stdout deliberately machine-readable
    print(mask_dx, mask_dy)


if __name__ == "__main__":
    main()
