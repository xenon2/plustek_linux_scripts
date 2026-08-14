
# Plustek OpticFilm 7500i – Linux RAW-like scanning pipeline

A small Linux scanning pipeline for the **Plustek OpticFilm 7500i** using `scanimage` / SANE `genesys`.

The goal is to keep the scan simple and reproducible:

- 3600 dpi
- 16-bit per channel RGB TIFF
- separate IR scan for dust/scratch detection
- binary defect mask
- 16-bit inpainting
- gamma 2.2 encoding for Lightroom / Negative Lab Pro
- final horizontal mirror
- untouched RAW scans preserved separately

## Tested setup

- Ubuntu 22.04
- Plustek OpticFilm 7500i
- SANE / sane-backends 1.4.0
- backend: `genesys`

Ubuntu 22.04 ships SANE 1.1.1, so this setup uses a locally built SANE 1.4.0 installed under:

```text
/usr/local/bin/scanimage
```

Check:

```bash
/usr/local/bin/scanimage --version
```

Expected:

```text
scanimage (sane-backends) 1.4.0
```

## Repository structure

```text
.
├── setup.sh
├── raw-scan.sh
├── scan-loop.sh
├── process-scan.sh
├── preview-scan.sh
├── preview.py
├── detect_scratch.py
├── inpaint.py
├── gamma22.py
├── overlay_mask.py
├── RAW/
├── TMP/
└── DONE/
```

`RAW/` contains untouched scanner output, e.g.:

```text
scan-001-rgb.tif
scan-001-ir.tif
```

`TMP/` contains masks and intermediate files.

`DONE/` contains processed TIFFs ready for Lightroom / Negative Lab Pro.

## Installation

System packages:

```bash
sudo apt install python3-venv libtiff-tools
```

Make scripts executable:

```bash
chmod +x setup.sh raw-scan.sh process-scan.sh scan-loop.sh
```

Create the Python environment:

```bash
./setup.sh
```

Before replacing `.venv`, setup verifies the required system commands
(`python3`, `/usr/local/bin/scanimage`, `tiffcrop`, and the standard shell
utilities), Python venv support, NumPy/OpenCV imports, required OpenCV APIs, and
TIFF/PNG/JPEG codec support. Missing dependencies are reported with install
hints. `xdg-open` is optional and is used only to open desktop previews.

The venv intentionally uses:

```text
numpy < 2
opencv-python
```

to avoid NumPy/OpenCV ABI conflicts seen with some Ubuntu Python installations.

## Scanning

Scan one frame:

```bash
./raw-scan.sh 1
```

For a temporary 900 dpi RGB-only scan, use `./raw-scan.sh --preview`.
Both modes use the scan area configured in `raw-scan.sh`.

A numbered scan creates:

```text
RAW/scan-001-rgb.tif
RAW/scan-001-ir.tif
```

RGB scan parameters are approximately:

```bash
scanimage   --source 'Transparency Adapter'   --mode Color   --depth 16   --resolution 3600   -l 0   -t 0   -x 35   -y 24   --custom-gamma=no   --format=tiff
```

The IR scan uses the same geometry and resolution, but:

```bash
--source 'Transparency Adapter Infrared'
--mode Color
```

For this scanner/backend combination, `Infrared + Gray` produced striped output, while `Infrared + Color` produced a useful IR image.

## Film orientation

Film is inserted with:

```text
shiny/base side up
emulsion side down
```

The backend output is mirrored horizontally, so the mirror operation is applied only to the final processed TIFF. RAW files remain untouched.

## Processing

Process an existing frame:

```bash
./process-scan.sh 1
```

Pipeline:

```text
RGB RAW ─────────────────────────────┐
                                     │
IR RAW -> binary defect mask         │
          -> mask offset             │
                                     v
                               16-bit inpaint
                                     |
                                  gamma 2.2
                                     |
                              horizontal mirror
                                     |
                                     v
                              DONE/scan-001.tif
```

## Current important parameters

At the top of `process-scan.sh`:

```bash
MASK_CHANNEL="0"
MASK_THRESHOLD="46000"
MASK_DILATE="0"

MASK_OFFSET_X="0"
MASK_OFFSET_Y="-10"

INPAINT_RADIUS="2"
INPAINT_DILATE="1"
INPAINT_METHOD="telea"

GAMMA_VALUE="2.2"
```

These are empirical values and may need tuning.

## IR mask

The current detector deliberately uses a simple model:

```python
mask = (ir < threshold)
```

White mask pixels mean:

```text
repair / inpaint
```

Black mask pixels mean:

```text
preserve
```

Measured example from `scan-001-ir.tif`, channel 0:

```text
min      0
0.1%     4992
1%       6089
5%       47014
50%      50160
95%      52479
99%      53700
max      65535
```

A useful starting point is therefore around:

```bash
--threshold 46000
```

Higher threshold = more pixels treated as defects.

Lower threshold = only darker/stronger IR defects selected.

## RGB / IR alignment

RGB and IR are acquired in separate passes and are not pixel-perfect aligned.

For the tested scanner, visual alignment gave approximately:

```text
X = 0
Y = -9 .. -10 px
```

Current default:

```bash
MASK_OFFSET_X="0"
MASK_OFFSET_Y="-10"
```

Do not assume the same offset for every scanner.

## Debugging alignment

Generate a mask manually:

```bash
.venv/bin/python detect_scratch.py   RAW/scan-001-ir.tif   TMP/scan-001-mask.png   --channel 0   --threshold 46000
```

Generate an overlay:

```bash
.venv/bin/python overlay_mask.py   RAW/scan-001-rgb.tif   TMP/scan-001-mask.png   TMP/scan-001-overlay.jpg   --dx 0   --dy -10   --color red   --alpha 0.65
```

Open:

```bash
xdg-open TMP/scan-001-overlay.jpg
```

The highlight should sit directly on visible dust/scratches.

## Inpainting

`inpaint.py` uses OpenCV and processes the 16-bit TIFF one channel at a time.

Example:

```bash
.venv/bin/python inpaint.py   RAW/scan-001-rgb.tif   TMP/scan-001-mask.png   TMP/scan-001-clean.tif   --dx 0   --dy -10   --radius 2   --dilate 1   --method telea
```

Large radius/dilation values can smear texture, so conservative settings are preferred.

## Gamma

Before Lightroom / Negative Lab Pro, the processing pipeline applies:

```text
gamma = 2.2
```

Conceptually:

```text
out = input^(1 / 2.2)
```

This gave substantially better Negative Lab Pro conversions than feeding the untouched scanner TIFF directly.

The original RAW TIFF remains preserved.

## Lightroom / Negative Lab Pro workflow

```text
scanimage 16-bit TIFF
-> IR dust/scratch cleanup
-> gamma 2.2
-> horizontal mirror
-> Lightroom
-> Negative Lab Pro
```

Empirically, this produced better color than the previous SilverFast DNG workflow for the tested negatives.

## Full interactive workflow

Run:

```bash
./scan-loop.sh
```

Typical prompt:

```text
[loop] frame 003 (3600 dpi) — [Enter/N] scan and process, [P] preview, [S] setup, [Q] quit:
```

Enter / `N`:

```text
scan RGB
scan IR
detect defects
inpaint
gamma 2.2
mirror
write DONE file
```

`P` makes a quick 900 dpi RGB-only preview. It does not scan IR, consume a
frame number, or alter the selected full-scan resolution. The negative is
inverted, per-channel 1–99% auto-levels and gamma 2.2 are applied, and the
image is mirrored into `TMP/preview.jpg`. Auto-levels remove the film-base cast
and avoid a flat gray preview. On a desktop, it is opened with `xdg-open`.
Preview conversion parameters can be adjusted in `preview-scan.sh`; scan area
and scanner parameters are shared with full scans and configured in
`raw-scan.sh`.

`S` opens setup. The full-scan resolution can be changed between 3600 and
7200 dpi, and `I` toggles the IR pass. Disable IR for B&W film; the scan is
then processed directly with gamma and mirroring, without defect detection or
inpainting. The settings remain active until the scan loop exits.

`Q` exits.

Existing RAW files determine the next scan number. The default resolution is
3600 dpi each time the scan loop starts.

## Scanner reset

If `scanimage` hangs:

```bash
pkill -9 scanimage
```

USB reset:

```bash
sudo usbreset 07b3:0c13
```

After reconnect/reset, the USB device number may change. `raw-scan.sh` therefore discovers the current `genesys:libusb:*` device dynamically.

## Known limitations

- RGB and IR need empirical alignment.
- IR still contains a faint version of the original image.
- A global IR threshold may classify some real image content as a defect.
- OpenCV inpainting can smear texture if the mask is too broad.
- Very fine scratches may still require mask tuning.
- Parameters are currently tuned empirically for one OpticFilm 7500i.
- This is not literal sensor RAW; SANE still performs scanner calibration/device-level processing.

## Design principle

Keep archival data simple:

```text
RAW = immutable scanner output
DONE = reproducible interpretation
```

All cleanup, gamma conversion and orientation changes can be regenerated later from the RAW RGB + IR pair.
