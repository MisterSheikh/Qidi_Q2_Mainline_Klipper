# Known-Good Matrix

This page lists upstream revisions known to work with the Q2 patches. Use them
as fallbacks if the current upstream revision does not accept or build the
patch series.

## Klipper

- Upstream repository: `https://github.com/Klipper3d/klipper.git`
- Base commit: `9c1ae230eaebd5ec4df76d5a87537e2f35defab0`
- Patch series:
  1. `patches/klipper/0001-stm32-add-GD32F425-USB-workaround.patch`
  2. `patches/klipper/0002-load_cell-add-CS1237-ADC-support.patch`
  3. `patches/klipper/0003-mcu-extend-Q2-multi-MCU-trigger-synchronization-time.patch`
  4. `patches/klipper/0004-stm32-add-Qidi-Q2-GD32F303-SPI2-mapping.patch`
  5. `patches/klipper/0005-stm32-add-Q2-GD32F425-MCU-temperature-support.patch`

The ordered patch series applies cleanly at this revision, and both saved MCU
configurations compile with GNU Arm Embedded Toolchain 10.3-2021.10. The
toolhead build includes Qidi's hardware-SPI2 mapping for the MAX6675. The
GD32F425 MCU temperature can be monitored without crashing the mainboard.

## Katapult

- Upstream repository: `https://github.com/Arksine/katapult.git`
- Base commit: `b0bf421069e2aab810db43d6e15f38817d981451`
- Patch: `patches/katapult/0001-q2-mainboard-usb.patch`

An already working patched Katapult bootloader does not need to be replaced
during a Klipper-only update.

## Earlier Klipper fallback

- Klipper base: `187481e2514f30fbaa19241869f4485ab4289cea`
- Archived combined patch:
  `patches/legacy/klipper/187481e2514f/0001-q2-mainboard-usb-and-cs1237.patch`

This archived combined patch is available for recovery but is not the current
patch series.

## Build configuration artifacts

### Klipper

- Mainboard: `klipper_patch/.main_mcu.config`
- Toolhead: `klipper_patch/.th_mcu.config`

Key mainboard settings:

- `CONFIG_MCU="stm32f407xx"`
- `CONFIG_FLASH_APPLICATION_ADDRESS=0x8008000`
- `CONFIG_STM32F4_GD32_USB_INIT_WORKAROUND=y`
- `CONFIG_WANT_CS1237=y`
- `CONFIG_WANT_TRIGGER_ANALOG=y`

Key toolhead settings:

- `CONFIG_MCU="stm32f103xe"`
- `CONFIG_FLASH_APPLICATION_ADDRESS=0x8002000`
- `CONFIG_SERIAL_BAUD=500000`
- `CONFIG_WANT_CS1237=y`
- `CONFIG_WANT_TRIGGER_ANALOG=y`

### Katapult

- Mainboard: `katapult_patch/.main_mcu.config`
- Toolhead: `katapult_patch/.th_mcu.config`

Key mainboard settings:

- `CONFIG_MCU="stm32f407xx"` (GD32F425-compatible target path)
- `CONFIG_STM32F4_GD32_USB_INIT_WORKAROUND=y`
- `CONFIG_STM32_APP_START_8000=y`

Key toolhead settings:

- `CONFIG_MCU="stm32f103xe"`
- `CONFIG_SERIAL_BAUD=500000`
- `CONFIG_STM32_APP_START_2000=y`
