#!/usr/bin/env python3

import argparse
import cv2
import numpy as np

from scanlog import fail, log


COMPONENT = "inpaint"


def main():
    p = argparse.ArgumentParser(
        description="16-bit TIFF inpainting with mask offset"
    )

    p.add_argument("input", help="Input RGB TIFF (uint16)")
    p.add_argument("mask", help="Binary mask: white=repair, black=keep")
    p.add_argument("output", help="Output RGB TIFF")

    p.add_argument("--dx", type=int, default=0)
    p.add_argument("--dy", type=int, default=-16)

    p.add_argument("--radius", type=float, default=3.0)
    p.add_argument("--dilate", type=int, default=1)

    p.add_argument(
        "--method",
        choices=["telea", "ns"],
        default="telea"
    )

    args = p.parse_args()

    img = cv2.imread(args.input, cv2.IMREAD_UNCHANGED)

    if img is None:
        fail(COMPONENT, f"cannot read image: {args.input}")

    if img.dtype != np.uint16:
        fail(COMPONENT, f"expected uint16 image, got {img.dtype}")

    if img.ndim != 3 or img.shape[2] != 3:
        fail(COMPONENT, f"expected 3-channel TIFF, got {img.shape}")

    mask = cv2.imread(args.mask, cv2.IMREAD_GRAYSCALE)

    if mask is None:
        fail(COMPONENT, f"cannot read mask: {args.mask}")

    if mask.shape != img.shape[:2]:
        fail(
            COMPONENT,
            f"mask size {mask.shape} != image size {img.shape[:2]}"
        )

    # Binary: white = repair
    mask = np.where(mask > 0, 255, 0).astype(np.uint8)

    #
    # Shift IR-derived mask into RGB coordinates
    #
    h, w = mask.shape

    M = np.array([
        [1, 0, args.dx],
        [0, 1, args.dy]
    ], dtype=np.float32)

    mask = cv2.warpAffine(
        mask,
        M,
        (w, h),
        flags=cv2.INTER_NEAREST,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0
    )

    #
    # Slightly enlarge detected defects
    #
    if args.dilate > 0:
        size = args.dilate * 2 + 1

        kernel = cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE,
            (size, size)
        )

        mask = cv2.dilate(mask, kernel, iterations=1)

    method = (
        cv2.INPAINT_TELEA
        if args.method == "telea"
        else cv2.INPAINT_NS
    )

    masked = np.count_nonzero(mask)
    log(
        COMPONENT,
        f"start offset=({args.dx},{args.dy}) radius={args.radius} "
        f"dilate={args.dilate} method={args.method} masked={masked}"
    )

    repaired = []

    for channel in cv2.split(img):
        repaired.append(
            cv2.inpaint(
                channel,
                mask,
                args.radius,
                method
            )
        )

    output = cv2.merge(repaired)

    if not cv2.imwrite(args.output, output):
        fail(COMPONENT, f"cannot write output: {args.output}")

    log(
        COMPONENT,
        f"output={args.output} repaired={masked}/{mask.size} "
        f"({100 * masked / mask.size:.3f}%)"
    )


if __name__ == "__main__":
    main()
