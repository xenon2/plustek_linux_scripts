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

p.add_argument(
    "--local-radius",
    type=float,
    default=0,
    help="Gaussian radius for local dark-defect detection; 0 disables it"
)

p.add_argument(
    "--local-threshold",
    type=float,
    default=0,
    help="Minimum local darkness to add to the mask; 0 disables it"
)

p.add_argument(
    "--local-min-area",
    type=int,
    default=0,
    help="Discard local-contrast components smaller than this many pixels"
)

args = p.parse_args()

if args.local_radius < 0 or args.local_threshold < 0 or args.local_min_area < 0:
    fail(COMPONENT, "local detection values must not be negative")

ir = cv2.imread(args.input, cv2.IMREAD_UNCHANGED)

if ir is None:
    fail(COMPONENT, f"cannot read input: {args.input}")

if ir.ndim == 3:
    if args.channel >= ir.shape[2]:
        fail(COMPONENT, f"channel {args.channel} is unavailable in shape {ir.shape}")
    ir = ir[:, :, args.channel]
elif ir.ndim != 2:
    fail(COMPONENT, f"unexpected input shape: {ir.shape}")

# Absolute darkness catches dust and scratches against the clear film base.
mask = ir < args.threshold

# A long scratch can cross areas with different IR levels. Detect pixels that
# are dark relative to their immediate surroundings as well, so the mask does
# not become discontinuous where the absolute threshold is too conservative.
local_count = 0
if args.local_radius > 0 and args.local_threshold > 0:
    ir_float = ir.astype(np.float32)
    background = cv2.GaussianBlur(
        ir_float,
        (0, 0),
        args.local_radius
    )
    local_mask = (background - ir_float) > args.local_threshold

    if args.local_min_area > 1:
        component_count, labels, stats, _ = cv2.connectedComponentsWithStats(
            local_mask.astype(np.uint8),
            connectivity=8
        )
        keep = np.zeros(component_count, dtype=bool)
        keep[1:] = stats[1:, cv2.CC_STAT_AREA] >= args.local_min_area
        local_mask = keep[labels]

    local_count = np.count_nonzero(local_mask)
    mask |= local_mask

mask = mask.astype(np.uint8) * 255

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
    f"local_radius={args.local_radius:g} local_threshold={args.local_threshold:g} "
    f"local_min_area={args.local_min_area} local_pixels={local_count} "
    f"masked={count}/{mask.size} ({100 * count / mask.size:.3f}%)"
)
