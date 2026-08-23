# Plustek OpticFilm 7500i Linux scanning pipeline

A Linux scanning and processing workflow for the **Plustek OpticFilm 7500i** using SANE's `genesys` backend.

It produces 16-bit RGB TIFFs at 3600 or 7200 dpi, optionally scans infrared for dust and scratch removal, and prepares the result for Lightroom / Negative Lab Pro. Original scans are preserved unchanged.

## Requirements

Tested with:

- Ubuntu 22.04
- Plustek OpticFilm 7500i
- SANE / sane-backends 1.4.0 (`genesys` backend)
- Python 3
- `libtiff-tools`

Ubuntu 22.04's packaged SANE version is too old for this setup. SANE 1.4.0 is expected at `/usr/local/bin/scanimage`.

Verify it with:

```bash
/usr/local/bin/scanimage --version
```

Install the remaining system dependencies and create the Python environment:

```bash
sudo apt install python3-venv libtiff-tools
./scripts/setup.sh
```

The setup script installs compatible NumPy and OpenCV versions in `.venv` and verifies the required image codecs.

## Usage

Insert film with the shiny/base side up and the emulsion side down, then start the interactive workflow:

```bash
./scan-loop.sh
```

Available actions:

- **Enter / N** — scan and process the next frame
- **P** — create a quick 900 dpi RGB preview
- **S** — select 3600 or 7200 dpi, enable or disable infrared, and choose low or high scratch removal
- **Q** — quit

Disable infrared for black-and-white film. The next frame number is determined from existing scans in `RAW/`.

### Manual operation

Scan and process frame 1:

```bash
./scripts/raw-scan.sh 1
./scripts/process-scan.sh 1
```

Create a preview:

```bash
./scripts/preview-scan.sh
```

## Processing

With infrared enabled, processing consists of:

1. Scan 16-bit RGB and infrared TIFFs.
2. Detect defects from the infrared image.
3. Estimate RGB/infrared alignment.
4. Inpaint defects in each 16-bit RGB channel.
5. Apply gamma 2.2.
6. Mirror the image horizontally.

Without infrared, only gamma and mirroring are applied.

Scanner output is written to `RAW/`, temporary processing files to `TMP/`, and finished TIFFs to `DONE/`. With infrared enabled, processing creates the selected conservative `scan-NNN-scratch-low.tif` or aggressive `scan-NNN-scratch-high.tif` variant. The default scratch level is high and can be changed in the interactive setup. If the high variant inpaints more than 5% of the image, the pipeline warns and also creates the conservative low variant from the same RGB and infrared scans. RGB-only processing creates `scan-NNN.tif`. Temporary files are removed after successful processing by default.

RAW scans and finished images are written to temporary files first and published with an atomic rename only after the command succeeds. Existing files in `RAW/` and `DONE/` are never overwritten; choose another frame number or move the existing output before retrying. An interrupted raw scan is discarded. If processing fails, its intermediate files remain in `TMP/` for diagnosis, while an incomplete final file is removed automatically.

The scanner's output is horizontally mirrored, so mirroring is applied only to the finished image. Files in `RAW/` remain untouched.

## Configuration

All user-adjustable settings are centralized in `config.ini`, where every setting has a comment describing its purpose. It contains output paths, dependency versions, scanner geometry, scan defaults, scratch detection, alignment, inpainting, gamma, cleanup, and preview settings.

Edit `config.ini` to change persistent defaults. An environment variable overrides the corresponding default for one command, for example:

```bash
RESOLUTION=7200 IR_ENABLED=no ./scripts/raw-scan.sh 1
SCRATCH_LEVEL=low KEEP_TMP=yes ./scripts/process-scan.sh 1
```

For manual processing, `SCRATCH_LEVEL` accepts `low` or `high` and defaults to high.

These values were tuned for one scanner and may need adjustment. Different film stocks can require different low and high scratch-detection thresholds, so experiment with both settings to find suitable values for your film. Because infrared scans can contain image detail, a threshold that is too aggressive may classify normal parts of the image as scratches and inpaint them. The low threshold produces a conservative repair and the high threshold produces a more aggressive repair. A higher mask threshold selects more pixels as defects; excessive mask dilation or inpainting radius can smear texture. `REPAIR_WARNING_PERCENT` controls when high repair coverage triggers a warning and an additional low variant.

Set `KEEP_TMP` to `yes` in `config.ini`, or override it for one command, to retain masks and intermediate TIFFs for debugging.

## Scanner reset

If `scanimage` hangs:

```bash
pkill -9 scanimage
sudo usbreset 07b3:0c13
```

The scripts discover the current `genesys:libusb:*` device automatically after a reconnect or reset.

## Limitations

- RGB and infrared are separate passes and may not align perfectly.
- Infrared can contain faint image detail, so a global threshold may select real content.
- Dust removal and alignment parameters may require scanner-specific tuning.
- This is not literal sensor RAW; SANE still performs calibration and device-level processing.

## TODO:
- Multiscan (scan n-times + averaging)
- Smarter scratch detection
- all settings in ini file for other scanners

