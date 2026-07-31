# Known-Good Matrix

This page captures the pinned fallback revisions and config artifacts used for this guide.

## Pinned fallback commits

If applying to latest upstream fails, use:

- Klipper fallback commit: `d865997403cad36d105026f73a4b76dcacec4c76`
- Katapult fallback commit: `b0bf421069e2aab810db43d6e15f38817d981451`

## Canonical patch files

- Klipper patch: `patches/klipper/0001-q2-mainboard-usb-and-cs1237.patch`
- Katapult patch: `patches/katapult/0001-q2-mainboard-usb.patch`

## Config artifacts used to build patch files

### Klipper

- Mainboard config artifact: `klipper_patch/.main_mcu.config`
- Toolhead config artifact: `klipper_patch/.th_mcu.config`

Key flags in mainboard artifact:

- `CONFIG_MCU="stm32f407xx"` (GD32F425-compatible target path)
- `CONFIG_STM32F4_GD32_USB_INIT_WORKAROUND=y`
- `CONFIG_WANT_CS1237=y`
- `CONFIG_WANT_TRIGGER_ANALOG=y`

Key flags in toolhead artifact:

- `CONFIG_MCU="stm32f103xe"` (used in current patchset for toolhead target)
- `CONFIG_SERIAL_BAUD=500000`

### Katapult

- Mainboard config artifact: `katapult_patch/.main_mcu.config`
- Toolhead config artifact: `katapult_patch/.th_mcu.config`

Key flags in mainboard artifact:

- `CONFIG_MCU="stm32f407xx"` (GD32F425-compatible target path)
- `CONFIG_STM32F4_GD32_USB_INIT_WORKAROUND=y`
- `CONFIG_STM32_APP_START_8000=y`

Key flags in toolhead artifact:

- `CONFIG_MCU="stm32f103xe"`
- `CONFIG_SERIAL_BAUD=500000`
- `CONFIG_STM32_APP_START_2000=y`
