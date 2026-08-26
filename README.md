# Plustek OpticFilm 7500i scanning pipeline

Linux workflow for scanning film with a **Plustek OpticFilm 7500i** through SANE's `genesys` backend. It creates 16-bit RGB TIFFs at 3600 or 7200 dpi and can use an infrared pass for dust and scratch removal.

## Pipeline

```text
                               ┌──────────────────────────┐
Film ──► OpticFilm scanner ───►│ 1–16 linear RGB captures │──► RAW/
          │                    └────────────┬─────────────┘
          │                                 │
          │                       capture count > 1?
          │                         yes │       │ no
          │                             ▼       │
          │                    align + average  │
          │                             └───┬───┘
          │                                 ▼
          │                           merged RGB
          │                                 │
          │       IR disabled ──────────────┼─────────────────────┐
          │                                 │                     │
          │ IR enabled                      ▼                     │
          └────────► IR capture ──► estimate RGB/IR offset        │
                             │             │                      │
                             ▼             ▼                      │
                       detect defects ──► inpaint RGB             │
                                           │                      │
                                           └──────────┬───────────┘
                                                      ▼
                                              gamma 2.2 + mirror
                                                      │
                                                      ▼
                                                    DONE/
```

Raw captures are never modified. Intermediate files go to `TMP/`; completed images go to `DONE/`.

## Requirements

Tested with Ubuntu 22.04, Python 3, `libtiff-tools`, and SANE 1.4.0. Ubuntu 22.04's SANE package is too old; this project expects `scanimage` at `/usr/local/bin/scanimage`.

```bash
/usr/local/bin/scanimage --version
sudo apt install python3-venv libtiff-tools
./scripts/setup.sh
```

`setup.sh` creates `.venv` and installs the required NumPy, OpenCV, and TIFFFile versions.

## Usage

Insert film shiny/base side up and emulsion side down, then run:

```bash
./scan-loop.sh
```

At startup, the loop checks the scanner, command-line tools, Python packages, pipeline scripts, and writable output directories. Each available requirement is marked `[OK]`; the loop exits before scanning if a requirement is missing.

Controls:

- **Enter / N** — scan and process the next frame
- **P** — make a quick 900 dpi preview
- **S** — set resolution, RGB capture count, IR, and scratch level
- **Q** — quit

Disable IR for black-and-white film. Frame numbering continues from the files in `RAW/`.

Manual commands:

```bash
./scripts/raw-scan.sh 1
./scripts/process-scan.sh 1
./scripts/preview-scan.sh
```

## Files and recovery

For frame `NNN`, the pipeline writes:

- `RAW/scan-NNN-rgb.tif` — first RGB capture
- `RAW/scan-NNN-rgb-02.tif` … `-16.tif` — additional captures
- `RAW/scan-NNN-ir.tif` — optional IR capture
- `RAW/scan-NNN-capture.ini` — capture settings and completion state
- `DONE/scan-NNN.tif` — RGB-only result
- `DONE/scan-NNN-scratch-low.tif` or `-high.tif` — IR-cleaned result

Captures and final images are published atomically and existing files are not overwritten. Re-running an interrupted `raw-scan.sh` with identical settings resumes at the first missing capture. Processing rejects incomplete captures and leaves failed intermediates in `TMP/` for diagnosis.

The high scratch profile is more aggressive. If it repairs more than `REPAIR_WARNING_PERCENT` (5% by default), the pipeline warns and also creates the low variant. Successful temporary files are removed unless `KEEP_TMP=yes`.

## Configuration

Settings live in [`config.ini`](config.ini), including paths, scanner geometry, scan defaults, multiscan alignment, scratch detection, inpainting, gamma, and cleanup. Environment variables override settings for one command:

```bash
RESOLUTION=7200 MULTISCAN_COUNT=4 IR_ENABLED=no ./scripts/raw-scan.sh 1
SCRATCH_LEVEL=low KEEP_TMP=yes ./scripts/process-scan.sh 1
```

> **Plustek OpticFilm 7500i note:** Using multiscan with at least two RGB captures (`MULTISCAN_COUNT=2` or higher) dramatically improves color response in testing, for reasons that are not yet understood. Prefer multiscan over a single capture when scan time and storage permit.

Scratch thresholds are scanner- and film-dependent. Start with `low`; aggressive thresholds, dilation, or inpainting can remove real image detail.

## Scanner reset

If `scanimage` hangs:

```bash
pkill -9 scanimage
sudo usbreset 07b3:0c13
```

The scripts rediscover the `genesys:libusb:*` device after reconnecting it.

## Limitations

- RGB and IR are separate passes and may not align perfectly.
- Multiscan registration corrects translation, not rotation or line-by-line drift.
- Every additional RGB capture requires another full 16-bit TIFF.
- IR may contain image detail, so defect masks require tuning.
- SANE still performs calibration and device-level processing; output is not sensor RAW.

## TODO

- Improve scratch detection.
- Add scanner-specific configuration profiles.
