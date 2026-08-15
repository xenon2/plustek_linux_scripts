#!/usr/bin/env python3

import argparse

import cv2
import numpy as np

from scanlog import fail, log


COMPONENT = "preview"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Create a viewable positive preview from a negative TIFF"
    )
    parser.add_argument("input", help="Input 16-bit negative TIFF")
    parser.add_argument("output", help="Output preview image (for example, JPEG)")
    parser.add_argument(
        "--gamma", type=float, default=2.2, help="Gamma value (default: 2.2)"
    )
    parser.add_argument(
        "--exposure",
        type=float,
        default=0.0,
        help="Exposure adjustment after levels, in stops (default: 0)",
    )
    parser.add_argument(
        "--black-percentile",
        type=float,
        default=1.0,
        help="Per-channel black percentile (default: 1)",
    )
    parser.add_argument(
        "--white-percentile",
        type=float,
        default=99.0,
        help="Per-channel white percentile (default: 99)",
    )
    parser.add_argument(
        "--quality", type=int, default=92, help="JPEG quality (default: 92)"
    )
    parser.add_argument(
        "--no-mirror", action="store_true", help="Do not mirror horizontally"
    )
    return parser.parse_args()


def main():
    args = parse_args()

    if args.gamma <= 0:
        fail(COMPONENT, "gamma must be greater than zero")
    if not 0 <= args.quality <= 100:
        fail(COMPONENT, "quality must be between 0 and 100")
    if not 0 <= args.black_percentile < args.white_percentile <= 100:
        fail(COMPONENT, "levels must satisfy 0 <= black < white <= 100")

    image = cv2.imread(args.input, cv2.IMREAD_UNCHANGED)
    if image is None:
        fail(COMPONENT, f"cannot read input: {args.input}")
    if image.dtype != np.uint16:
        fail(COMPONENT, f"expected uint16 TIFF, got {image.dtype}")

    # Inversion alone leaves the film-base offset in place and produces a flat,
    # gray image. Stretch each channel after inversion to remove that color cast
    # and establish useful black/white points before display gamma is applied.
    positive = 1.0 - image.astype(np.float32) / 65535.0
    black = np.percentile(positive, args.black_percentile, axis=(0, 1))
    white = np.percentile(positive, args.white_percentile, axis=(0, 1))
    span = np.maximum(white - black, 1.0 / 65535.0)
    leveled = np.clip((positive - black) / span, 0.0, 1.0)

    adjusted = np.power(leveled, 1.0 / args.gamma)
    adjusted *= 2.0 ** args.exposure
    output = np.clip(np.round(adjusted * 255.0), 0, 255).astype(np.uint8)

    if not args.no_mirror:
        output = cv2.flip(output, 1)

    params = [cv2.IMWRITE_JPEG_QUALITY, args.quality]
    if not cv2.imwrite(args.output, output, params):
        fail(COMPONENT, f"cannot write output: {args.output}")

    log(
        COMPONENT,
        f"output={args.output} negative=yes levels="
        f"{args.black_percentile:g}/{args.white_percentile:g} gamma={args.gamma} "
        f"exposure={args.exposure:+g}EV size={image.shape[1]}x{image.shape[0]}",
    )


if __name__ == "__main__":
    main()
