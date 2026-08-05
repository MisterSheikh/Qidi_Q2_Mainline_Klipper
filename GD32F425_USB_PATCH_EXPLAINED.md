# GD32F425 USB Patch Explained

This document explains the GD32 USB bring-up work as it exists in this repository today.

## 1) Where this patch lives

Patch files:

- Klipper runtime patch:
  `patches/klipper/0001-stm32-add-GD32F425-USB-workaround.patch`
- Katapult bootloader patch: `patches/katapult/0001-q2-mainboard-usb.patch`

## 2) File ownership

The Klipper USB patch changes:

- `src/stm32/usbotg.c`
- `src/stm32/Kconfig`
- `src/generic/usb_cdc_ep.h`

## 3) Common USB files across Klipper and Katapult

The same USB workaround concept is implemented in both firmware layers:

- `src/stm32/usbotg.c`
- `src/stm32/Kconfig`
- `src/generic/usb_cdc_ep.h`

Katapult also changes:

- `src/generic/usb_cdc.h`

Q2 needs stable USB behavior in both the bootloader stage (Katapult) and the
runtime stage (Klipper).

## 4) Hardware issue this patch addresses

The Q2 mainboard uses GD32F425 but follows STM32F407 target settings. Mainline STM32 OTG init assumptions are not fully safe on this clone family after bootloader handoff.

Observed failure classes:

1. Unreliable enumeration after handoff
2. CDC host->MCU traffic stalls (OUT endpoint not re-armed in all interrupt paths)

Key compatibility differences handled by this patch:

1. `GUSBCFG.PHYSEL` handling:
- Common STM32F407 init paths set `PHYSEL`.
- On GD32F425, touching this bit is not safe in this context; workaround mode avoids setting it.
2. `GCCFG` session/power bits:
- Mainline STM32 path often relies on minimal `NOVBUSSENS` behavior.
- GD32F425 needs explicit power/session bits during bring-up:
  `PWRDWN | NOVBUSSENS | VBUSASEN | VBUSBSEN`.
3. EP0 setup buffering:
- GD32F425 is more sensitive to EP0 OUT setup rearm timing.
- Workaround mode uses explicit `DOEPTSIZ.STUPCNT` handling to keep control transfers stable.
4. OUT endpoint interrupt behavior:
- STM32-centric assumptions around RXFLVL-only handling are insufficient here.
- GD32 can complete bulk OUT via `OEPINT`, so explicit OUT rearm is required there too.

## 5) What changed in `src/stm32/Kconfig`

Both Klipper and Katapult add:

- `CONFIG_STM32F4_GD32_USB_INIT_WORKAROUND`

Purpose:

- Keep workaround opt-in and scoped to STM32F4x5 USB serial targets.
- Avoid changing behavior for unaffected boards.

## 6) What changed in USB endpoint definitions

### `src/generic/usb_cdc_ep.h` (Klipper and Katapult)

When workaround is enabled:

- endpoint map becomes:
  - BULK IN = 1
  - ACM IN = 2
  - BULK OUT = 3

Why:

- Matches the validated CDC layout used on this GD32 target.

### EP0 size handling

- Klipper patch sets EP0 size conditionally in `src/generic/usb_cdc_ep.h`.
- Katapult patch sets EP0 size conditionally in `src/generic/usb_cdc.h`.

In both cases, workaround mode uses EP0 size `64`.

## 7) What changed in `src/stm32/usbotg.c` (core of the fix)

The important changes are the same in principle for Klipper and Katapult.

### A) Bootloader handoff cleanup and core reset

Adds GD32-specific reset/cleanup paths before normal USB bring-up:

- core soft reset
- runtime FIFO/endpoint/interrupt state cleanup
- clock/power domain cleanup before re-init

Result:

- startup state is deterministic after handoff.

### B) Safe GD32 register programming

Under workaround mode:

- avoids unsafe/clone-sensitive programming patterns
- uses read-modify-write style where needed
- applies GD32-safe session/power bit combinations
- does not force `GUSBCFG.PHYSEL`

Result:

- enumerates more reliably on GD32F425.

### C) EP0/control transfer hardening

Adds robust EP0 rearm behavior and reset/enum handling:

- setup buffering behavior aligned to this target
- explicit reset/enumeration-done handling paths
- rearm logic after control phases
- explicit `STUPCNT`-aware EP0 OUT arming

Result:

- control-plane stability during initial USB negotiation.

### D) Bulk OUT reliability fix (host->MCU path)

Adds handling so OUT endpoint gets re-armed consistently regardless of interrupt path (RXFLVL/OEPINT mix).

Result:

- prevents the "first packets work, then host writes stall" failure mode.
- Klipper identify/command stream stays alive.

Implementation detail that matters:

- RXFLVL path stages packet data and rearms OUT.
- OEPINT completion path also rearms OUT (`enable_rx_endpoint(USB_CDC_EP_BULK_OUT)`).
- This closes the specific stall mode where initial packets arrive but endpoint remains NAKing afterward.

## 8) Why enumeration and communication succeed after this patch

The patch addresses both control-plane and data-plane failures:

1. Control-plane (enumeration/setup):
- deterministic post-handoff reset state
- GD32-safe register programming (`GUSBCFG`/`GCCFG`)
- robust EP0 setup rearm and enum/reset handling
2. Data-plane (runtime CDC traffic):
- reliable bulk OUT processing and rearm across RXFLVL and OEPINT paths

Net effect:

- device enumerates reliably as USB CDC
- host writes do not deadlock after initial traffic
- Klipper identify/command stream remains stable

## 9) Why both Katapult and Klipper need USB fixes

Katapult must enumerate and communicate reliably for flashing.
Klipper must do the same for normal runtime operation.

If only one side is fixed, users still encounter breakage at either flashing or runtime stages.

## 10) Relationship to CS1237

The CS1237 feature work is separate and does not implement the USB fix.

The `src/Kconfig` and `src/Makefile` changes in the `0002` patch are CS1237
integration work, not GD32 USB bring-up.

For CS1237 details, see [CS1237_PATCH_EXPLAINED.md](CS1237_PATCH_EXPLAINED.md).
