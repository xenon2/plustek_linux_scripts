#!/usr/bin/env python3

import argparse
import cv2
import numpy as np

from scanlog import fail, log


COMPONENT = "overlay"


def percentile_stretch_rgb16_to_8(img16, p_low=1.0, p_high=99.0):
    img = img16.astype(np.float32)

    out = np.empty_like(img, dtype=np.uint8)

    for c in range(3):
        ch = img[:, :, c]

        lo = np.percentile(ch, p_low)
        hi = np.percentile(ch, p_high)

        if hi <= lo:
            hi = lo + 1.0

        x = (ch - lo) / (hi - lo)
        x = np.clip(x, 0.0, 1.0)

        out[:, :, c] = np.round(x * 255.0).astype(np.uint8)

    return out


def parse_color(name):
    # OpenCV = BGR
    colors = {
        "red":     (0, 0, 255),
        "green":   (0, 255, 0),
        "blue":    (255, 0, 0),
        "yellow":  (0, 255, 255),
        "magenta": (255, 0, 255),
        "cyan":    (255, 255, 0),
        "white":   (255, 255, 255),
    }

    if name not in colors:
        fail(COMPONENT, f"unsupported color: {name}")

    return np.array(colors[name], dtype=np.float32)


def main():
    p = argparse.ArgumentParser(
        description="Overlay binary mask on RGB image for alignment/debug preview."
    )

    p.add_argument("image", help="Input RGB TIFF (preferably uint16)")
    p.add_argument("mask", help="Input binary mask")
    p.add_argument("output", help="Output preview image (jpg/png)")

    p.add_argument("--dx", type=int, default=0, help="Mask X offset in pixels")
    p.add_argument("--dy", type=int, default=0, help="Mask Y offset in pixels")

    p.add_argument("--alpha", type=float, default=0.65,
                   help="Overlay opacity 0..1 (default: 0.65)")

    p.add_argument("--color", type=str, default="red",
                   choices=["red", "green", "blue", "yellow", "magenta", "cyan", "white"],
                   help="Highlight color (default: red)")

    p.add_argument("--low", type=float, default=1.0,
                   help="Lower percentile for preview stretch (default: 1)")
    p.add_argument("--high", type=float, default=99.0,
                   help="Upper percentile for preview stretch (default: 99)")

    p.add_argument("--write-shifted-mask", action="store_true",
                   help="Also save shifted binary mask next to output")

    args = p.parse_args()

    if not (0.0 <= args.alpha <= 1.0):
        fail(COMPONENT, "--alpha must be in range 0..1")

    img = cv2.imread(args.image, cv2.IMREAD_UNCHANGED)
    if img is None:
        fail(COMPONENT, f"cannot read image: {args.image}")

    if img.ndim != 3 or img.shape[2] != 3:
        fail(COMPONENT, f"expected 3-channel image, got shape {img.shape}")

    mask = cv2.imread(args.mask, cv2.IMREAD_GRAYSCALE)
    if mask is None:
        fail(COMPONENT, f"cannot read mask: {args.mask}")

    if mask.shape != img.shape[:2]:
        fail(COMPONENT, f"mask size {mask.shape} != image size {img.shape[:2]}")

    mask = np.where(mask > 0, 255, 0).astype(np.uint8)

    # shift mask
    h, w = mask.shape
    M = np.array([
        [1, 0, args.dx],
        [0, 1, args.dy]
    ], dtype=np.float32)

    shifted_mask = cv2.warpAffine(
        mask,
        M,
        (w, h),
        flags=cv2.INTER_NEAREST,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0
    )

    # preview conversion
    if img.dtype == np.uint16:
        preview = percentile_stretch_rgb16_to_8(img, args.low, args.high)
    elif img.dtype == np.uint8:
        preview = img.copy()
    else:
        fail(COMPONENT, f"unsupported dtype: {img.dtype}")

    overlay = preview.astype(np.float32)
    color = parse_color(args.color)

    sel = shifted_mask > 0
    overlay[sel] = overlay[sel] * (1.0 - args.alpha) + color * args.alpha

    overlay = np.clip(np.round(overlay), 0, 255).astype(np.uint8)

    if not cv2.imwrite(args.output, overlay):
        fail(COMPONENT, f"cannot write output: {args.output}")

    if args.write_shifted_mask:
        if "." in args.output:
            base = args.output.rsplit(".", 1)[0]
        else:
            base = args.output
        mask_out = base + "-shifted-mask.png"
        if not cv2.imwrite(mask_out, shifted_mask):
            fail(COMPONENT, f"cannot write shifted mask: {mask_out}")

    masked = np.count_nonzero(shifted_mask)
    extra = f" shifted_mask={mask_out}" if args.write_shifted_mask else ""
    log(
        COMPONENT,
        f"output={args.output} offset=({args.dx},{args.dy}) alpha={args.alpha} "
        f"color={args.color} masked={masked}/{shifted_mask.size}{extra}"
    )


if __name__ == "__main__":
    main()
