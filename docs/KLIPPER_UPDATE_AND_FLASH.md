# Qidi Q2 Klipper Update, Build, and Flash Runbook

This runbook updates an existing Q2 mainline installation. It updates Klipper
and reapplies the Q2 patch series; it does not reinstall Katapult or convert a
stock Qidi installation.

The patch series provides:

1. The GD32F425 mainboard USB workaround.
2. Native CS1237 load-cell support.
3. The Q2 multi-MCU trigger-synchronization timeout adjustment.
4. The Q2 GD32F303 SPI2 mapping used by the toolhead MAX6675.
5. GD32F425 MCU temperature monitoring without crashing the mainboard.

The default update uses patches 1-5, with the mainboard at 168 MHz and the
toolhead at 72 MHz. Optional patches 6-7 add 200 MHz GD32F425 and 120 MHz
GD32F303 builds.

## Choosing a revision

The default update attempt uses the latest commit fetched from upstream
Klipper `master`. The revision is resolved to an exact commit before the
printer is stopped.

The fallback in [KNOWN_GOOD_MATRIX.md](KNOWN_GOOD_MATRIX.md) can be selected
explicitly if current upstream does not accept or build the patches:

```bash
# Latest upstream master (default)
./update_q2_klipper.sh update

# Known-good fallback
./update_q2_klipper.sh update --klipper-revision known-good

# Optional maximum-frequency builds
./update_q2_klipper.sh update --with-max-clocks

# Specific commit from upstream master history
./update_q2_klipper.sh update \
  --klipper-revision <full-40-character-commit>
```

If patching or building fails, the updater stops and prints the command for
retrying with `known-good`.

## Update model

The updater identifies the active Klipper source, resolves the selected
revision, stops the service after confirmation, and creates timestamped backups
of the source, `klippy-env`, and printer configuration. It then updates and
patches the source, updates the Python environment, and builds separate
mainboard and toolhead images. By default, it then pauses before flashing and
asks whether to stop with the verified images or flash through an existing,
matching Katapult installation.

This is an offline maintenance operation. It does not try to keep the printer
usable while its software is being replaced.

## Important boundaries

- The updater cannot read back the firmware installed on either MCU. Keep
  previous known-good mainboard and toolhead images separately.
- The saved build configurations use the documented Q2 Katapult application
  offsets: `0x08008000` (32 KiB) on the mainboard and `0x08002000` (8 KiB) on
  the toolhead.
- Automatic flashing is only for printers where both MCUs already have the
  matching Katapult layout installed using this repository's instructions. It
  does not install, update, replace, or reconfigure Katapult.
- Do not select automatic flashing for stock, alternative, deployer-modified,
  or unknown bootloader layouts. A firmware image built for the wrong
  application offset can leave an MCU unbootable.
- The default post-build prompt selects no flashing when its answer is blank,
  invalid, unconfirmed, or unavailable. This leaves `klipper.service` stopped
  with the verified images ready for the appropriate external procedure.
- The updater backs up but does not rewrite personal printer configuration.
- It does not home, move, heat, or commission the printer.

The default update builds with `klipper_patch/.main_mcu.config` and
`klipper_patch/.th_mcu.config`. The `--with-max-clocks` option also applies
patches 6-7 and builds with `.main_mcu_200mhz.config` and
`.th_mcu_120mhz.config`. Its default output directory is suffixed with
`-max-clocks` so it does not replace default-build artifacts for the same
Klipper revision.

If Katapult is not installed yet,
[n3oney/qidi-q2-klipper](https://github.com/n3oney/qidi-q2-klipper) documents
another way to install Katapult and Klipper without an ST-Link by using a
deployer with the stock Qidi update scripts. You can follow that project for
the initial installation, then return to this runbook for later Klipper updates
if you choose. It is a separate project and installation path, so use it at
your own risk. Before selecting automatic flashing here, verify that both
reported application offsets match the values required above.

## Using the updater

Run the read-only preflight first:

```bash
cd ~/Qidi_Q2_Mainline_Klipper
./update_q2_klipper.sh check
```

The preflight verifies required commands, paths, the active Git checkout, the
Python environment, and the source path used by `klipper.service`. It does not
contact upstream, stop the service, or modify the installation.

### Default post-build choice

Run the update without selecting a flash method:

```bash
./update_q2_klipper.sh update
```

After the backup, source update, environment update, and both builds, the
script displays the required Katapult offsets and offers two choices:

1. Stop without flashing. This is the safe default for stock, alternative,
   deployer-modified, or unknown bootloader layouts.
2. Confirm that both installed Katapult bootloaders use the exact documented
   offsets, then flash the toolhead and mainboard through Katapult.

If no interactive terminal is available, the updater stops without flashing.
The `--yes` option bypasses the initial typed update confirmation but does not
select the Katapult choice at the post-build prompt.

### Manual or external flashing

To select the no-flash path before starting the update, use:

```bash
./update_q2_klipper.sh update --flash-method manual
```

The script prints the two exact image paths and leaves Klipper stopped. Flash
both MCUs using the method appropriate for that installation, then start
Klipper and perform the checks below.

Do not assume the generated images fit a non-Katapult bootloader merely because
the processor is the same. Confirm its application offsets and rebuild with
matching configurations if necessary.

### Katapult flashing

Only use this preselected mode when both MCUs already have the Katapult layout
from this repository's installation instructions: mainboard application offset
`0x08008000` and toolhead application offset `0x08002000`:

```bash
./update_q2_klipper.sh update \
  --flash-method katapult \
  --main-device /dev/serial/by-id/usb-Klipper_stm32f407xx_<actual-id>-if00
```

If exactly one matching mainboard Klipper or Katapult USB device exists,
`--main-device` may be omitted. The toolhead defaults to `/dev/ttyS4` at
500000 baud.

Katapult mode uses the wrappers in `qidi_mcu_flash_scripts/`. Direct
wrapper use requires an explicit firmware image and a separate board-specific
matching-Katapult confirmation. If another project installed or replaced the
bootloader, verify its exact application offset rather than assuming it matches.

Run `./update_q2_klipper.sh help` for non-default source, environment,
printer-data, firmware-output, backup, device, build-job, and revision options.

## What the updater records

The default locations are:

- backup: `~/q2-backups/<timestamp>-<selected-commit-short>/`
- firmware: `~/q2-firmware/<selected-commit-short>/`

The firmware directory contains the two board-specific images plus:

- the requested revision selector and exact resolved upstream base;
- firmware checksums;
- Q2 patch checksums;
- saved build-configuration checksums; and
- a checksum describing the patched source state.

If an error occurs after the service is stopped, Klipper remains stopped so a
mismatched host and MCU pair is not knowingly started. The rollback location
is printed when one has been created.

## Manual equivalent

The following is the equivalent manual workflow. Read each command and adapt
paths to the printer.

### 1. Identify the active installation

```bash
systemctl cat klipper --no-pager
pid="$(systemctl show klipper --property=MainPID --value)"
tr '\0' ' ' < "/proc/$pid/cmdline"
printf '\n'

git -C ~/klipper rev-parse HEAD
git -C ~/klipper status --short
ls -l /dev/serial/by-id/
```

KIAUH commonly places the expanded command in
`~/printer_data/systemd/klipper.env`. Confirm that the active entry point is
the expected `~/klipper/klippy/klippy.py` before changing that checkout.

### 2. Check dependencies and active configuration

```bash
command -v arm-none-eabi-gcc
command -v arm-none-eabi-objcopy
python3 -c "import serial; print('pyserial OK')"
~/klippy-env/bin/python -c \
  "import numpy, serial; print('Klippy dependencies OK')"
```

NumPy is required by the load-cell stack.

Merge only the required changes from:

- `config_changes/printer.cfg`
- `config_changes/gcode_macro.cfg`
- `docs/config_changes.md`

into files actually included by the active `printer.cfg`. Retain this
printer's own `counts_per_gram` and `reference_tare_counts`; do not copy force
calibration from another machine.

### 3. Resolve the upstream base

Fetch current upstream and record its exact commit:

```bash
git -C ~/klipper fetch https://github.com/Klipper3d/klipper.git master
selected_base="$(git -C ~/klipper rev-parse FETCH_HEAD)"
base_short="${selected_base:0:8}"
printf '%s\n' "$selected_base"
```

To use the known-good fallback instead, set:

```bash
selected_base="$(~/Qidi_Q2_Mainline_Klipper/apply_patch.sh --print-klipper-known-good)"
base_short="${selected_base:0:8}"
```

### 4. Stop Klipper and make complete backups

```bash
sudo systemctl stop klipper
systemctl is-active klipper

backup_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$HOME/q2-backups/$backup_stamp-$base_short"
mkdir -p "$backup_dir"
cp -a ~/klipper "$backup_dir/klipper"
cp -a ~/klippy-env "$backup_dir/klippy-env"
cp -a ~/printer_data/config "$backup_dir/printer-config"
```

The expected service result is `inactive`. Also retain the previous matching
mainboard and toolhead images; the host backup cannot reconstruct running MCU
firmware.

### 5. Update and patch the active Klipper checkout

```bash
git -C ~/klipper reset --hard "$selected_base"
git -C ~/klipper clean -fdx

cd ~/Qidi_Q2_Mainline_Klipper
KLIPPER_DIR=~/klipper ./apply_patch.sh klipper
git -C ~/klipper diff --check
```

If the patch check fails on current upstream, leave Klipper stopped and repeat
the update from the documented known-good base. Do not force a rejected patch.

Do not use `git pull` directly on the patched checkout; repeat this backup,
reset, patch, build, and flash process instead.

### 6. Update the Klippy environment

```bash
~/klippy-env/bin/python -m pip install \
  -r ~/klipper/scripts/klippy-requirements.txt
if ! ~/klippy-env/bin/python -c "import numpy" >/dev/null 2>&1; then
  ~/klippy-env/bin/python -m pip install numpy
fi
~/klippy-env/bin/python -c \
  "import numpy, serial; print('Klippy dependencies OK')"
```

### 7. Build both MCU images

Use one build job on the stock AP board:

```bash
firmware_dir="$HOME/q2-firmware/$base_short"
mkdir -p "$firmware_dir"

cd ~/klipper
cp ~/Qidi_Q2_Mainline_Klipper/klipper_patch/.main_mcu.config .config
make olddefconfig
make clean
make -j1
cp out/klipper.bin "$firmware_dir/q2-mainboard-klipper-$base_short.bin"

cp ~/Qidi_Q2_Mainline_Klipper/klipper_patch/.th_mcu.config .config
make olddefconfig
make clean
make -j1
cp out/klipper.bin "$firmware_dir/q2-toolhead-klipper-$base_short.bin"

sha256sum \
  "$firmware_dir/q2-mainboard-klipper-$base_short.bin" \
  "$firmware_dir/q2-toolhead-klipper-$base_short.bin"
```

The mainboard configuration targets the 32 KiB Katapult application offset,
USB on PA11/PA12, the GD32F425 USB workaround, and CS1237 support. The toolhead
configuration targets the 8 KiB offset, USART1 on PB7/PB6 at 500000 baud, and
the Q2 `PB14,PC0,PB13` hardware-SPI2 mapping used by the read-only MAX6675.

### 8. Flash both MCUs

Only when the installed Katapult bootloaders use application offset
`0x08008000` on the mainboard and `0x08002000` on the toolhead:

```bash
cd ~/Qidi_Q2_Mainline_Klipper
./qidi_mcu_flash_scripts/flash_th.sh \
  --firmware "$firmware_dir/q2-toolhead-klipper-$base_short.bin"

./qidi_mcu_flash_scripts/flash_main.sh \
  --firmware "$firmware_dir/q2-mainboard-klipper-$base_short.bin" \
  --device /dev/serial/by-id/usb-Klipper_stm32f407xx_<actual-id>-if00
```

Use `--dry-run` to inspect the selected paths without requesting a bootloader
or flashing. Never type the placeholder USB ID literally. Do not run these
wrappers with a stock, differently configured, deployer-modified, or unknown
bootloader. Follow that installation's established procedure only after
verifying its bootloader layout and rebuilding for the matching application
offset when necessary.

### 9. Start and inspect Klipper

Only after the host and both MCU images match:

```bash
sudo systemctl start klipper
sudo systemctl status klipper --no-pager
journalctl -u klipper -n 100 --no-pager
tail -n 150 ~/printer_data/logs/klippy.log
```

Before homing, confirm Klipper is ready, both MCUs connect, no protocol or
configuration errors are present, and CS1237 initializes normally.

With heaters and motors idle, run:

```gcode
LOAD_CELL_DIAGNOSTIC
LOAD_CELL_TEST_TAP
```

Confirm unloaded force is near zero, force changes in the expected direction,
and all requested taps register. Then proceed cautiously through XY homing, the
first Z home, Z tilt, a small mesh, and normal commissioning. See
[LOAD_CELL_CALIBRATION.md](LOAD_CELL_CALIBRATION.md).

## Rollback boundary

A complete rollback restores a matched set:

1. The prior `~/klipper` source.
2. The prior `~/klippy-env` environment.
3. The prior printer configuration.
4. The prior mainboard Klipper image.
5. The prior toolhead Klipper image.

Keep Klipper stopped while restoring all five components. Restoring only the
host source can cause an MCU protocol mismatch. Working Katapult bootloaders
normally allow both prior images to be reflashed without another SWD operation.
