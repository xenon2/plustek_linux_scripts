#!/usr/bin/env python3

import argparse
import cv2
import numpy as np

from scanlog import fail, log


COMPONENT = "gamma"


def parse_args():
    p = argparse.ArgumentParser(
        description="Apply gamma encoding to 16-bit TIFF"
    )

    p.add_argument("input", help="Input 16-bit RGB TIFF")
    p.add_argument("output", help="Output 16-bit RGB TIFF")

    p.add_argument(
        "--gamma",
        type=float,
        default=2.2,
        help="Gamma value (default: 2.2)"
    )

    return p.parse_args()


def main():
    args = parse_args()

    img = cv2.imread(args.input, cv2.IMREAD_UNCHANGED)

    if img is None:
        fail(COMPONENT, f"cannot read input: {args.input}")

    if img.dtype != np.uint16:
        fail(COMPONENT, f"expected uint16 TIFF, got {img.dtype}")

    x = img.astype(np.float32) / 65535.0

    y = np.power(
        np.clip(x, 0.0, 1.0),
        1.0 / args.gamma
    )

    out = np.clip(
        np.round(y * 65535.0),
        0,
        65535
    ).astype(np.uint16)

    if not cv2.imwrite(args.output, out):
        fail(COMPONENT, f"cannot write output: {args.output}")

    log(COMPONENT, f"output={args.output} gamma={args.gamma} size={img.shape[1]}x{img.shape[0]}")


if __name__ == "__main__":
    main()
