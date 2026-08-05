# Qidi Q2 Mainline Installation Guide

This is the installation workflow for running mainline-style Klipper on stock Qidi Q2 hardware.

If a Q2 mainline port and patched Katapult bootloaders are already installed,
use the
[existing-installation update guide](KLIPPER_UPDATE_AND_FLASH.md) instead.

## 0) Scope and safety

- This process flashes both MCUs and can brick boards if done incorrectly.
- Keep recovery tooling available before proceeding (ST-Link V2, wiring access, host shell access).
- This guide does **not** cover full AP-board OS reimaging.

## 1) Host AP-board prep (external guide)

Use the [qidi community Q2 wiki](https://github.com/qidi-community/q2-wiki) guides to prepare the stock AP-board OS:

- [Update Debian package sources.](https://github.com/qidi-community/q2-wiki/blob/main/content/debian-package-sources/README.md)
- [Update and fix KIAUH](https://github.com/qidi-community/q2-wiki/blob/main/content/kiauh-update-and-fix/README.md)
- [Disable unused processes](https://github.com/bluedrool/Qidi-Q2-tuning-tweaks-and-mods/blob/main/docs/processes.md)
- Remove the stock Qidi Klipper, Moonraker, Fluidd, and Crowsnest installation
  with KIAUH.

You may also need to disable or remove `klipper-mcu.service`. If KIAUH reports
that a directory was not removed, resolve its exact path, inspect its contents,
and move it aside or remove that specific directory only after confirming it is
the obsolete installation. Do not run a recursive removal command against an
unresolved placeholder or broad home-directory path.

Before continuing, confirm:

1. You can SSH into the printer host.
2. Network and package installation work.
3. Unneeded stock services are disabled.
4. You are ready to install the Klipper stack via KIAUH.

## 2) Install software stack with KIAUH

Use KIAUH to install:

- The `klipper` host service and Python environment
- Latest `moonraker`
- Your web UI of choice (`mainsail` or `fluidd`)
- Any optional components you want (Input shaping dependencies for example)

If KIAUH is not available:

```bash
cd ~
git clone https://github.com/dw-0/kiauh.git
./kiauh/kiauh.sh
```

## 3) Install required tools

```bash
sudo apt update
sudo apt install -y -t bullseye-backports stlink-tools git python3-serial
command -v arm-none-eabi-gcc
command -v arm-none-eabi-objcopy
command -v make
~/klippy-env/bin/python -c 'import numpy; print(numpy.__version__)'
```

Notes:

- `bullseye-backports` is required to get a more recent version of `stlink-tools` (1.7 instead of 1.6.1)
- `python3-serial` (pyserial) is required for Katapult `flashtool.py`.
- KIAUH normally installs the ARM compiler, binary utilities, and build tools
  with Klipper. If any of the three `command -v` checks fail, install the
  missing build dependencies:

  ```bash
  sudo apt install -y gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi make
  ```

- NumPy is required by `[load_cell_probe]`, but it may already be present from
  the stock environment or optional input-shaper dependencies. If the NumPy
  import check fails, install it in Klipper's Python environment:

  ```bash
  ~/klippy-env/bin/python -m pip install numpy
  ```

- Keep `~/klipper` from KIAUH and clone `katapult` into home.

## 4) Get upstream sources

If `~/klipper` already exists from KIAUH, keep it. Start from the current
upstream Klipper `master` revision:

```bash
git -C ~/klipper fetch https://github.com/Klipper3d/klipper.git master
git -C ~/klipper checkout --detach FETCH_HEAD
```

Clone Katapult if needed, then start from its current upstream `master`
revision:

```bash
cd ~
if [ ! -d katapult ]; then
  git clone https://github.com/Arksine/katapult.git
fi
cd ~/katapult
git fetch https://github.com/Arksine/katapult.git master
git checkout --detach FETCH_HEAD
```

The known-good fallback revisions are listed in
[KNOWN_GOOD_MATRIX.md](KNOWN_GOOD_MATRIX.md). Current upstream is attempted
first; those checkpoints remain available if a patch compatibility check fails
or the current revision does not build or operate correctly.

## 5) Apply Q2 patches from this repo

Clone this guide repo to the host:

```bash
cd ~
git clone https://github.com/MisterSheikh/Qidi_Q2_Mainline_Klipper.git
cd Qidi_Q2_Mainline_Klipper

```

Run the helper script:

```bash
./apply_patch.sh all
```

By default it targets:

1. `~/klipper`
2. `~/katapult`

If your repos are elsewhere, override paths when running:

```bash
KLIPPER_DIR=/path/to/klipper \
KATAPULT_DIR=/path/to/katapult \
./apply_patch.sh all
```

The helper checks the complete ordered series before modifying either checkout.

If the check fails, do not force the patches. Confirm that both repositories
are clean, then check out the fallback printed by the helper and rerun it. The
fallback revisions can also be printed directly:

```bash
cd ~/Qidi_Q2_Mainline_Klipper
./apply_patch.sh --print-klipper-known-good
./apply_patch.sh --print-katapult-known-good
git -C ~/klipper status --short
git -C ~/katapult status --short
```

## 6) Mainboard (GD32F425) Katapult build + ST-Link flash

### 6.1 Build Katapult for mainboard

Configure katapult for the mainboard:

```bash
cd ~/katapult
cp ~/Qidi_Q2_Mainline_Klipper/katapult_patch/.main_mcu.config .config
make olddefconfig
make menuconfig
```

![image](images/main_mcu_katapult.png)

Make sure you match the settings shown in the image, then press `q` and `y` to save and quit.

Build the firmware:

```bash
make clean
make -j1
```

### 6.2 ST-Link wiring and power (mainboard)

I used a $3 ST-Link V2 clone I bought on Aliexpress, adjust based on what you have.
Connect ST-Link V2 to mainboard SWD pins:

- `SWDIO`
- `SWCLK`
- `GND`
- optional `RST`

Refer to the pinout show here and in `board_pinouts/X-9-3 V1.2_001 PIN.pdf`:

![image](images/q2_main_stlink_pinout.png)

Power behavior:

- Mainboard is powered by the printer 24V PSU.
- **Do not connect ST-Link 3V3 to the mainboard**.

Connect ST-Link USB to the host AP-board USB port on the side of the Q2 screen assembly.

### 6.3 Flash Katapult to mainboard

Verify probe:

```bash
st-info --probe
```

Erase and flash:

```bash
st-flash erase
st-flash write ~/katapult/out/katapult.bin 0x8000000
```

Verify USB presence:

```bash
lsusb
ls /dev/serial/by-id/
```

If Katapult USB does not appear, rerun:

```bash
st-info --probe
lsusb
ls /dev/serial/by-id/
```

## 7) Mainboard (GD32F425) Klipper build + flash via Katapult

### 7.1 Build Klipper for mainboard

Configure klipper for the mainboard:

```bash
cd ~/klipper
cp ~/Qidi_Q2_Mainline_Klipper/klipper_patch/.main_mcu.config .config
make olddefconfig
make menuconfig
```

![image](images/main_mcu_klipper.png)

Then build:

```bash
cd ~/klipper
make clean
make -j1
```

### 7.2 Flash Klipper to mainboard over Katapult USB

Replace serial ID with your device path:

```bash
python3 ~/katapult/scripts/flashtool.py \
  -d /dev/serial/by-id/usb-katapult_stm32f407xx_<actual-id>-if00 \
  -f ~/klipper/out/klipper.bin
```

After flash, mainboard should run mainline Klipper on GD32F425.

## 8) Toolhead board (GD32F303) Katapult + Klipper

The toolhead follows a similar flow with key hardware/runtime differences.

### 8.1 Hardware differences

1. Fully disconnect toolhead board from the printer before ST-Link flashing.
2. Solder headers for ST-Link access if not already present.
3. For toolhead ST-Link flashing, **connect 3V3** from ST-Link.
Refer to the pinout here:
[TH-Board Pinout](../board_pinouts/A-9%28GD%29%20V1.2_002%20PIN.pdf)

NOTE: Do not Disable SWD at startup as we do not use pins PA13 and PA14 on this board. Therefore we don't need them to be available via the disable SWD patch.

### 8.2 Build Katapult for toolhead

Configure katapult for the toolhead:

```bash
cd ~/katapult
cp ~/Qidi_Q2_Mainline_Klipper/katapult_patch/.th_mcu.config .config
make olddefconfig
make menuconfig
```

![image](images/th_mcu_katapult.png)

Make sure you match the settings shown in the image, then press `q` and `y` to save and quit.

Build the firmware:

```bash
make clean
make -j1
```

Flash Katapult over ST-Link:

```bash
st-info --probe
st-flash erase
st-flash write ~/katapult/out/katapult.bin 0x8000000
```

### 8.3 Build and flash Klipper for toolhead

Configure klipper for the toolhead:

```bash
cd ~/klipper
cp ~/Qidi_Q2_Mainline_Klipper/klipper_patch/.th_mcu.config .config
make olddefconfig
make menuconfig
```

![image](images/th_mcu_klipper.png)

Make sure you match the settings shown in the image, then press `q` and `y` to save and quit.

The patched firmware exposes the Q2 GD32F303 toolhead mapping as
`spi2_PB14_PC0_PB13`. Use that explicit name in the MAX6675 configuration so
native SPI2 does not reserve the heater output on `PB15`.

Then build:

```bash
make clean
make -j1
```

Flash over UART device `/dev/ttyS4` at baud `500000`:

```bash
python3 ~/katapult/scripts/flashtool.py -b 500000 -d /dev/ttyS4 -r
python3 ~/katapult/scripts/flashtool.py -b 500000 -d /dev/ttyS4 -f ~/klipper/out/klipper.bin
```

## 9) Config migration to mainline

Apply the required config changes outlined in:

- [config_changes.md](config_changes.md)

to your personal `printer.cfg` and `gcode_macro.cfg` files.

Also provided here as quick and easy references:

- [config_changes/printer.cfg](../config_changes/printer.cfg)
- [config_changes/gcode_macro.cfg](../config_changes/gcode_macro.cfg)
- [complete adapted personal configuration](../personal_config_reference/README.md)

Required adjustments per machine:

1. Mainboard MCU serial path in `[mcu]` (from `/dev/serial/by-id/...`).
2. Remove the stock Qidi reverse-homing options and keep
   `[stepper_z] endstop_pin: probe:z_virtual_endstop`.
3. Replace stock `spi_bus: spi2` or the older mainline software-SPI workaround
   with `spi_bus: spi2_PB14_PC0_PB13` for the MAX6675.
4. Remove stock chamber `z_max_limit` and replace `[probe_air]`/`c_sensor` with
   `[load_cell_probe]`/`cs1237`, keeping `z_offset: 0`.
5. Use native `G28 Z` homing while retaining the separate
   `saved_variables.cfg` first-layer-offset workflow.
6. Remove stock includes or macro calls that depend on unavailable Qidi-only
   components.
7. Preserve and verify all per-machine tuning and calibration values.

Merge the documented sections into the configuration actually included by
`printer.cfg`; do not replace your complete personal configuration.

## 10) Validation checklist

1. `st-info --probe` succeeds for both MCUs during ST-Link stages.
2. Mainboard enumerates after Katapult flash (`lsusb`, `/dev/serial/by-id/`).
3. Mainboard Klipper flash via Katapult completes without timeout.
4. Toolhead Klipper flash via `/dev/ttyS4` at `500000` completes.
5. Klipper starts with both MCUs connected.
6. Core printer motion/heater/fan commands work.
7. Load-cell/CS1237 features initialize and function.

## 11) Troubleshooting quick notes

1. `git apply --check` fails on current upstream: confirm the checkout is
   clean, then use the relevant fallback in
   [KNOWN_GOOD_MATRIX.md](KNOWN_GOOD_MATRIX.md).
2. No Katapult USB after mainboard ST-Link flash: run probe again and rerun erase/write commands.
3. `flashtool.py` import errors: ensure `python3-serial` is installed.
4. Toolhead flash UART failures: confirm `/dev/ttyS4` exists, board is correctly powered/wired, and baud is `500000`.

## 12) Future firmware updates

For an existing installation with working Katapult bootloaders, follow
[KLIPPER_UPDATE_AND_FLASH.md](KLIPPER_UPDATE_AND_FLASH.md). A generic Klipper
update does not apply or validate the required Q2 patches.

## 13) Post install

Calibrate or validate the CS1237 force scale by following
[LOAD_CELL_CALIBRATION.md](LOAD_CELL_CALIBRATION.md). Keep
`[load_cell_probe] z_offset: 0`; tune and save the separate runtime
first-layer offset during an actual print.
