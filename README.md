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
- **S** — select 3600 or 7200 dpi and enable or disable infrared
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

Scanner output is written to `RAW/`, temporary processing files to `TMP/`, and finished TIFFs to `DONE/`. Temporary files are removed after successful processing by default.

The scanner's output is horizontally mirrored, so mirroring is applied only to the finished image. Files in `RAW/` remain untouched.

## Configuration

Scanner geometry and defaults are configured near the top of `scripts/raw-scan.sh`. Processing parameters are configured near the top of `scripts/process-scan.sh`, including:

```bash
MASK_CHANNEL="0"
MASK_THRESHOLD="44000"
MASK_DILATE="0"

AUTO_OFFSET="yes"
OFFSET_MAX_SHIFT="100"

INPAINT_RADIUS="2"
INPAINT_DILATE="1"
INPAINT_METHOD="telea"

GAMMA_VALUE="2.2"
```

These values were tuned for one scanner and may need adjustment. A higher mask threshold selects more pixels as defects; excessive mask dilation or inpainting radius can smear texture.

Set `KEEP_TMP="yes"` in `scripts/process-scan.sh` to retain masks and intermediate TIFFs for debugging.

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

