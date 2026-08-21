#!/usr/bin/env python3

import argparse
import cv2
import numpy as np
from scanlog import fail, log


COMPONENT = "detect"

p = argparse.ArgumentParser()

p.add_argument("input")
p.add_argument("output")

p.add_argument(
    "--threshold",
    type=int,
    default=45000
)

p.add_argument(
    "--channel",
    type=int,
    default=0
)

p.add_argument(
    "--dilate",
    type=int,
    default=0
)

args = p.parse_args()

ir = cv2.imread(args.input, cv2.IMREAD_UNCHANGED)

if ir is None:
    fail(COMPONENT, f"cannot read input: {args.input}")

if ir.ndim == 3:
    if args.channel >= ir.shape[2]:
        fail(COMPONENT, f"channel {args.channel} is unavailable in shape {ir.shape}")
    ir = ir[:, :, args.channel]
elif ir.ndim != 2:
    fail(COMPONENT, f"unexpected input shape: {ir.shape}")

# Wszystko ciemniejsze niż threshold = defekt
mask = (ir < args.threshold).astype(np.uint8) * 255

if args.dilate > 0:
    size = args.dilate * 2 + 1

    kernel = cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE,
        (size, size)
    )

    mask = cv2.dilate(mask, kernel)

if not cv2.imwrite(args.output, mask):
    fail(COMPONENT, f"cannot write output: {args.output}")

count = np.count_nonzero(mask)
log(
    COMPONENT,
    f"output={args.output} threshold={args.threshold} dilate={args.dilate} "
    f"masked={count}/{mask.size} ({100 * count / mask.size:.3f}%)"
)
