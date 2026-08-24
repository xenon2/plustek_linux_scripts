#!/usr/bin/env python3
"""Align and average repeated linear 16-bit RGB scanner captures."""

import argparse
import math
import os
import sys

import cv2
import numpy as np
import tifffile

from scanlog import fail, log


COMPONENT = "multiscan"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Align and average 1-16 memory-mapped 16-bit RGB TIFFs."
    )
    parser.add_argument("inputs", nargs="+", help="RGB TIFF captures; first is reference")
    parser.add_argument("--output", required=True, help="Merged RGB TIFF")
    parser.add_argument("--offsets-file", help="Write phase alignment diagnostics as TSV")
    parser.add_argument("--max-shift", type=float, default=100.0)
    parser.add_argument("--min-response", type=float, default=0.05)
    parser.add_argument("--proxy-size", type=int, default=2000)
    parser.add_argument("--strip-rows", type=int, default=128)
    args = parser.parse_args()

    if not 1 <= len(args.inputs) <= 16:
        parser.error("between 1 and 16 input captures are required")
    if args.max_shift < 0:
        parser.error("--max-shift must not be negative")
    if not 0 <= args.min_response <= 1:
        parser.error("--min-response must be from 0 through 1")
    if args.proxy_size < 128:
        parser.error("--proxy-size must be at least 128")
    if args.strip_rows < 1:
        parser.error("--strip-rows must be positive")
    return args


def open_image(path):
    try:
        image = tifffile.memmap(path, mode="r")
    except Exception as exc:
        raise ValueError(
            f"cannot memory-map {path}; multiscan inputs must be uncompressed TIFFs: {exc}"
        ) from exc
    if image.ndim != 3 or image.shape[2] != 3:
        raise ValueError(f"expected three-channel RGB TIFF, got shape={image.shape}: {path}")
    if image.dtype.kind != "u" or image.dtype.itemsize != 2:
        raise ValueError(f"expected uint16 TIFF, got dtype={image.dtype}: {path}")
    return image


def gradient_proxy(image, step):
    # Channel averaging is deliberate: TIFFFile exposes RGB rather than OpenCV's BGR.
    proxy = image[::step, ::step].astype(np.float32).mean(axis=2)
    proxy *= 1.0 / 65535.0
    gx = cv2.Sobel(proxy, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(proxy, cv2.CV_32F, 0, 1, ksize=3)
    magnitude = cv2.magnitude(gx, gy)
    return cv2.GaussianBlur(magnitude, (0, 0), 1.2)


def estimate_offsets(paths, shape, max_shift, min_response, proxy_size):
    step = max(1, math.ceil(max(shape[:2]) / proxy_size))
    reference_image = open_image(paths[0])
    reference = gradient_proxy(reference_image, step)
    del reference_image

    height, width = reference.shape
    window = cv2.createHanningWindow((width, height), cv2.CV_32F)
    offsets = [(0.0, 0.0, 1.0)]

    for phase, path in enumerate(paths[1:], start=2):
        image = open_image(path)
        moving = gradient_proxy(image, step)
        del image
        (proxy_dx, proxy_dy), response = cv2.phaseCorrelate(reference, moving, window)
        dx = proxy_dx * step
        dy = proxy_dy * step
        if not np.isfinite((dx, dy, response)).all():
            raise ValueError(f"RGB phase {phase} produced a non-finite alignment result")
        if abs(dx) > max_shift or abs(dy) > max_shift:
            raise ValueError(
                f"RGB phase {phase} shift ({dx:.3f},{dy:.3f}) exceeds "
                f"maximum {max_shift:.3f} pixels"
            )
        if response < min_response:
            raise ValueError(
                f"RGB phase {phase} alignment response {response:.6f} is below "
                f"minimum {min_response:.6f}"
            )
        offsets.append((dx, dy, response))
        log(
            COMPONENT,
            f"phase={phase}/{len(paths)} shift=({dx:.3f},{dy:.3f}) response={response:.6f}",
        )
    return offsets, step


def valid_axis(length, shift):
    base = math.floor(shift)
    fraction = shift - base
    extra = 1 if fraction > 1e-7 else 0
    start = max(0, -base)
    stop = min(length, length - base - extra)
    return base, fraction, start, stop


def translated_block(source, y_start, y_stop, x_start, x_stop, dx, dy):
    bx, fx, _, _ = valid_axis(source.shape[1], dx)
    by, fy, _, _ = valid_axis(source.shape[0], dy)
    sy0 = y_start + by
    sx0 = x_start + bx
    rows = y_stop - y_start
    columns = x_stop - x_start

    top_left = source[sy0 : sy0 + rows, sx0 : sx0 + columns].astype(np.float32)
    if fx > 1e-7:
        top_right = source[
            sy0 : sy0 + rows, sx0 + 1 : sx0 + columns + 1
        ].astype(np.float32)
        top_left *= 1.0 - fx
        top_left += top_right * fx

    if fy <= 1e-7:
        return top_left

    bottom_left = source[
        sy0 + 1 : sy0 + rows + 1, sx0 : sx0 + columns
    ].astype(np.float32)
    if fx > 1e-7:
        bottom_right = source[
            sy0 + 1 : sy0 + rows + 1, sx0 + 1 : sx0 + columns + 1
        ].astype(np.float32)
        bottom_left *= 1.0 - fx
        bottom_left += bottom_right * fx
    top_left *= 1.0 - fy
    top_left += bottom_left * fy
    return top_left


def tiff_output_options(reference_path):
    options = {"photometric": "rgb", "metadata": None}
    try:
        with tifffile.TiffFile(reference_path) as tif:
            page = tif.pages[0]
            x_resolution = page.tags.get("XResolution")
            y_resolution = page.tags.get("YResolution")
            unit = page.tags.get("ResolutionUnit")
            if x_resolution and y_resolution:
                options["resolution"] = (
                    float(x_resolution.value[0]) / x_resolution.value[1],
                    float(y_resolution.value[0]) / y_resolution.value[1],
                )
            if unit:
                options["resolutionunit"] = unit.value
    except (OSError, TypeError, ValueError, ZeroDivisionError):
        pass
    return options


def write_offsets(path, inputs, offsets, proxy_step):
    temporary = f"{path}.tmp.{os.getpid()}"
    try:
        with open(temporary, "x", encoding="utf-8") as stream:
            stream.write(f"# proxy_step={proxy_step}\n")
            stream.write("phase\tdx\tdy\tresponse\tfile\n")
            for phase, (input_path, values) in enumerate(zip(inputs, offsets), start=1):
                dx, dy, response = values
                stream.write(
                    f"{phase}\t{dx:.6f}\t{dy:.6f}\t{response:.6f}\t{input_path}\n"
                )
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def merge(args, reference, offsets):
    output = args.output
    if os.path.exists(output):
        raise ValueError(f"output already exists: {output}")
    temporary = f"{os.path.splitext(output)[0]}.tmp.{os.getpid()}.tif"
    if os.path.exists(temporary):
        raise ValueError(f"temporary output already exists: {temporary}")

    height, width, _ = reference.shape
    byte_count = height * width * 3 * np.dtype(np.uint16).itemsize
    options = tiff_output_options(args.inputs[0])
    output_map = None
    sources = [reference]
    try:
        sources.extend(open_image(path) for path in args.inputs[1:])
        output_map = tifffile.memmap(
            temporary,
            shape=reference.shape,
            dtype=np.uint16,
            bigtiff=byte_count >= 2**32,
            **options,
        )
        for y0 in range(0, height, args.strip_rows):
            y1 = min(height, y0 + args.strip_rows)
            accumulator = np.zeros((y1 - y0, width, 3), dtype=np.float32)
            contributors = np.zeros((y1 - y0, width), dtype=np.uint8)

            for source, (dx, dy, _) in zip(sources, offsets):
                _, _, x0, x1 = valid_axis(width, dx)
                _, _, valid_y0, valid_y1 = valid_axis(height, dy)
                block_y0 = max(y0, valid_y0)
                block_y1 = min(y1, valid_y1)
                if x0 < x1 and block_y0 < block_y1:
                    block = translated_block(source, block_y0, block_y1, x0, x1, dx, dy)
                    accumulator[block_y0 - y0 : block_y1 - y0, x0:x1] += block
                    contributors[block_y0 - y0 : block_y1 - y0, x0:x1] += 1

            if np.any(contributors == 0):
                raise ValueError(f"no RGB capture contributes to output strip starting at row {y0}")
            averaged = accumulator / contributors[:, :, None]
            output_map[y0:y1] = np.clip(np.rint(averaged), 0, 65535).astype(np.uint16)
            log(COMPONENT, f"merge rows={y0 + 1}-{y1}/{height}")

        output_map.flush()
        del output_map
        output_map = None
        # Hard-link publication is atomic and refuses to replace a concurrent output.
        os.link(temporary, output)
        os.unlink(temporary)
    finally:
        if output_map is not None:
            del output_map
        sources.clear()
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main():
    args = parse_args()
    try:
        reference = open_image(args.inputs[0])
        shape = reference.shape
        for path in args.inputs[1:]:
            image = open_image(path)
            if image.shape != shape:
                raise ValueError(
                    f"geometry mismatch: reference={shape}, input={image.shape}: {path}"
                )
            del image

        log(COMPONENT, f"start phases={len(args.inputs)} size={shape[1]}x{shape[0]}")
        offsets, proxy_step = estimate_offsets(
            args.inputs,
            shape,
            args.max_shift,
            args.min_response,
            args.proxy_size,
        )
        if args.offsets_file:
            write_offsets(args.offsets_file, args.inputs, offsets, proxy_step)
        merge(args, reference, offsets)
        log(COMPONENT, f"done output={args.output} phases={len(args.inputs)}")
    except (OSError, ValueError, tifffile.TiffFileError) as exc:
        fail(COMPONENT, str(exc))


if __name__ == "__main__":
    main()
