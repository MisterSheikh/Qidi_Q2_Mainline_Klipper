# Patch Scope

This page summarizes the current numbered patch series.

## Patch files

- Klipper, default series:
  1. `patches/klipper/0001-stm32-add-GD32F425-USB-workaround.patch`
  2. `patches/klipper/0002-load_cell-add-CS1237-ADC-support.patch`
  3. `patches/klipper/0003-mcu-extend-Q2-multi-MCU-trigger-synchronization-time.patch`
  4. `patches/klipper/0004-stm32-add-Qidi-Q2-GD32F303-SPI2-mapping.patch`
  5. `patches/klipper/0005-stm32-add-Q2-GD32F425-MCU-temperature-support.patch`
- Klipper, optional maximum-frequency additions:
  6. `patches/klipper/0006-stm32-add-Q2-GD32F303-120MHz-target.patch`
  7. `patches/klipper/0007-stm32-add-Q2-GD32F425-200MHz-support.patch`
- Katapult: `patches/katapult/0001-q2-mainboard-usb.patch`

These are intended for `git apply` on upstream clones.

## Klipper patch scope

### 0001: MCU / USB bring-up (GD32F425 on STM32F4 path)

- `src/stm32/usbotg.c`
- `src/stm32/Kconfig`
- `src/generic/usb_cdc_ep.h`

Purpose:

- Add `CONFIG_STM32F4_GD32_USB_INIT_WORKAROUND`.
- Apply GD32-safe USB core/session init.
- Stabilize enumeration/control handling and bulk OUT re-arming.
- Preserve current upstream USB behavior outside the selected workaround.

### 0002: CS1237 load-cell support

- `src/sensor_cs1237.c`
- `src/Kconfig`
- `src/Makefile`
- `klippy/extras/cs1237.py`
- `klippy/extras/load_cell.py`
- `klippy/extras/load_cell_probe.py`
- `docs/Config_Reference.md`
- `test/klippy/load_cell.cfg`

Purpose:

- Add the MCU-side CS1237 driver and host bulk-sensor wrapper.
- Register `cs1237` with the current load-cell and load-cell-probe registries.
- Integrate with the current trigger-analog and bulk-sensor interfaces.
- Account for missed conversion windows without publishing invalid samples or
  forcing sensor restart loops.
- Preserve other current upstream load-cell sensor registrations.

The February `c_sensor` compatibility alias is not part of the active port.

### 0003: Q2 multi-MCU trigger timeout

- `klippy/mcu.py`

Purpose:

- Change `TRSYNC_TIMEOUT` from `0.025` seconds to `0.050` seconds.
- Retain the Q2-tested allowance for the load-cell trigger path spanning the
  host, mainboard, and UART-connected toolhead.

### 0004: Q2 GD32F303 toolhead SPI2 mapping

- `src/stm32/spi.c`

Purpose:

- Add the explicit `spi2_PB14_PC0_PB13` STM32F1 bus mapping.
- Preserve `PB15` for the toolhead heater while using the read-only MAX6675
  on native SPI2.
- Leave the ordinary STM32F1 `spi2` mapping and default behavior unchanged.

### 0005: Q2 GD32F425 MCU temperature support

- `src/stm32/Kconfig`
- `src/stm32/adc.c`
- `klippy/extras/temperature_mcu.py`

Purpose:

- Allow GD32F425 MCU temperature monitoring without crashing the mainboard.

### 0006: Optional Q2 GD32F303 120 MHz target

- `src/stm32/Kconfig`
- `src/stm32/Makefile`
- `src/stm32/adc.c`
- `src/stm32/stm32f1.c`

Purpose:

- Add a Q2-specific GD32F303 target running at its officially supported
  120 MHz maximum.
- Keep the ordinary STM32F103 target and 72 MHz toolhead build unchanged.

### 0007: Optional Q2 GD32F425 200 MHz support

- `src/stm32/Kconfig`
- `src/stm32/stm32f4.c`

Purpose:

- Allow the Q2 GD32F425 target to run at its officially supported 200 MHz
  maximum.
- Keep the default 168 MHz mainboard build unchanged unless selected.

## Katapult patch scope

- `src/stm32/usbotg.c`
- `src/stm32/Kconfig`
- `src/generic/usb_cdc_ep.h`
- `src/generic/usb_cdc.h`

Purpose:

- Add the same GD32 USB workaround concept in Katapult so USB bootloader behavior is reliable on Q2 mainboard hardware.
- Keep this bootloader patch for fresh installation or recovery. A routine
  update of an already working Q2 installation does not reflash Katapult.

## Saved build configs

Saved build configurations are stored under:

- `klipper_patch/`
- `katapult_patch/`

## Detailed technical explanations

- [GD32F425_USB_PATCH_EXPLAINED.md](../GD32F425_USB_PATCH_EXPLAINED.md)
- [CS1237_PATCH_EXPLAINED.md](../CS1237_PATCH_EXPLAINED.md)
