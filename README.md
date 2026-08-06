# Qidi Q2 Mainline Klipper Guide (Stock Hardware)

This repository documents and hosts the patchset required for running mainline Klipper firmware on the stock electronics of the Qidi Q2. The Qidi Q2 uses a GD32F425 as the MCU for its mainboard, it is functionally a clone of the STM32F407. However it is not readily compatible with Klipper as there are some differences between the two that must be accounted for. Additionally the Q2 uses a CS1237 ADC for load cell probing with the nozzle, this is not compatible with Klipper out of the box either.

## What this enables

- Mainboard (`GD32F425`) running mainline Klipper with stable USB CDC enumeration/communication.
- GD32F425 MCU temperature monitoring without crashing the mainboard.
- Mainboard Katapult build with the same GD32 USB workaround.
- Qidi's GD32F303 SPI2 mapping for hardware-SPI MAX6675 reads on the toolhead.
- Toolhead board firmware flow kept in the same repo for reproducible builds.
- `CS1237` load cell support integrated into the mainline Klipper load-cell stack (`load_cell` / `load_cell_probe`).
- Optional 200 MHz GD32F425 and 120 MHz GD32F303 Klipper builds.

## Installation Guidelines

- Keep the stock Q2 AP-board OS and update/tune it (external community guide).
- Install the host Klipper stack with KIAUH.
- Start with current upstream Klipper and Katapult checkouts.
- Clone this repo and run `./apply_patch.sh all`.
- To use the optional maximum-frequency builds, apply patches 6-7 with
  `./apply_patch.sh --with-max-clocks all` instead.
- If a current revision is incompatible, use the known-good fallback listed in
  the known-good matrix instead of forcing the patch.
- For a fresh installation, flash Katapult via ST-Link, then flash Klipper via
  Katapult.

### Alternative no-ST-Link installation

[n3oney/qidi-q2-klipper](https://github.com/n3oney/qidi-q2-klipper) documents
another way to install Katapult and Klipper without an ST-Link by using a
deployer with the stock Qidi update scripts. You can follow that project for
the initial installation, then return here for later Klipper updates if you
choose. It is a separate project and installation path, so use it at your own
risk. Verify the installed application offsets before selecting this
repository's automatic flash option.

## Updating an existing installation

If a Q2 mainline port and patched Katapult bootloaders are already installed,
keep Katapult in place and follow
[the manual update and rollback runbook](docs/KLIPPER_UPDATE_AND_FLASH.md).

[`update_q2_klipper.sh`](update_q2_klipper.sh) is an optional updater that backs
up the Klipper source, Python environment, and printer configuration before
updating the source, reapplying the Q2 patches, and building both MCU images.
It then presents a post-build choice and defaults to stopping without flashing.
Its default build uses patches 1-5; `--with-max-clocks` also applies patches
6-7 and selects the optional maximum-frequency configurations.
Automatic flashing is only for both MCUs already using the Katapult application
offsets from this repository's installation instructions: `0x08008000` on the
mainboard and `0x08002000` on the toolhead.

The updater attempts the latest upstream Klipper revision by default. A
documented known-good revision can be selected explicitly if the latest
revision no longer accepts or builds the patch series.

## Start here

- Full installation and flashing flow: [docs/INSTALL.md](docs/INSTALL.md)
- Existing-installation update and rollback flow:
  [docs/KLIPPER_UPDATE_AND_FLASH.md](docs/KLIPPER_UPDATE_AND_FLASH.md)
- Required stock->mainline config changes: [docs/config_changes.md](docs/config_changes.md)
- Patch/file scope summary: [docs/PATCH_SCOPE.md](docs/PATCH_SCOPE.md)
- Version matrix and config artifacts: [docs/KNOWN_GOOD_MATRIX.md](docs/KNOWN_GOOD_MATRIX.md)

## Notes

- The scripts in `qidi_mcu_flash_scripts/` flash a supplied firmware image only
  through an existing Katapult installation with the matching application
  offset. They do not install or replace Katapult and support a dry run.
- Device paths (`/dev/serial/by-id/...`, `/dev/ttyS4`) are
  environment-specific and must be confirmed on your machine.

## DISCLAIMER

I am NOT responsible for anything that happens if you decide to install mainline Klipper onto your Qidi Q2. I will not provide any dedicated support. You do this at your own endeavour. This is merely a resource that I am providing on how I got mainline Klipper running on the stock hardware of the Qidi Q2. Also a little bit of a flex because many others tried before me but could never get the GD32F425 to successfully enumerate via USB nor get the CS1237 to function with Klipper.
