# Qidi Q2 Config Changes (Stock Qidi -> Mainline)

This page lists target sections to use when moving from stock Qidi config to
mainline Klipper on Q2. It also covers users updating from the earlier
mainline configuration, which used a software-SPI MAX6675 workaround.

Merge these changes into the files included by your active `printer.cfg` and
retain machine-specific serial IDs and tuning. This is not a complete printer
profile.

## Stock configuration boundary

The stock `printer.cfg` includes `MCU_ID.cfg`, `gcode_macro.cfg`, `plr.cfg`, and
`box.cfg`. Mainline Klipper does not provide Qidi's proprietary Python extras.
Inspect every file still included by the active `printer.cfg`: retain ordinary
Klipper configuration and macros, but remove an include or dependent macro call
when its Qidi-only object is no longer available.

The supplied `personal_config_reference/` is a complete adapted example. It is
not a replacement for another printer's serial IDs, tuning, calibration, or
optional hardware configuration.

## 1) `printer.cfg` sections

### 1.1 Mainboard MCU section

```ini
[mcu]
serial: /dev/serial/by-id/usb-Klipper_stm32f407xx_<actual-id>-if00
restart_method: command
```

Changes:
- Replace the stock `MCU_ID.cfg` dependency with one active `[mcu]` definition,
  either in `printer.cfg` or a retained include.

Why:
- Mainline Klipper setup should not depend on vendor include files for the primary MCU definition.
- Run `ls /dev/serial/by-id/` to get the name of your mcu device.

### 1.2 Toolhead MCU section

```ini
[mcu THR]
serial: /dev/ttyS4
restart_method: command
baud: 500000
```

Changes:
- None, we keep UART toolhead MCU path and baud in the mainline config.

Why:
- Q2 toolhead communication is UART (`/dev/ttyS4`) and must use `500000` baud.

### 1.3 Z steppers (mainline load-cell homing path)

```ini
[stepper_z]
endstop_pin: probe:z_virtual_endstop
homing_positive_dir: false
```

Changes:
- Remove `endstop_pin_reverse`, `position_endstop_reverse`, and
  `homing_positive_dir_reverse` from the stock `[stepper_z]` section.
- Remove `endstop_pin_reverse` from the stock `[stepper_z1]` section.
- Uses the native load-cell probe virtual endstop.
- Retain the printer's existing Z pins, rotation distance, travel limits, and
  appropriate homing speeds.

Why:
- Mainline klipper does not contain Qidi reverse-homing logic.
- Current mainline Klipper supports native Z homing through
  `probe:z_virtual_endstop`.

### 1.4 Extruder section (MAX6675 hardware SPI)

```ini
[extruder]
sensor_type: MAX6675
sensor_pin: THR:PB12
spi_bus: spi2_PB14_PC0_PB13
spi_speed: 2000000
```

Changes:
- Replace the stock `spi_bus: spi2` value with the explicit mapping above.
- If updating from the older mainline configuration, remove all
  `spi_software_*` keys from `[extruder]`.
- Preserve the printer's remaining extruder, heater, PID, and extrusion values.

Why:
- The mapping uses `PB14` for MISO, `PB13` for SCK, and `PC0` as the unused
  MOSI pin, leaving heater output `PB15` available.

### 1.5 Chamber heater section

```ini
[heater_generic chamber]
z_max_limit: 230  # Remove this stock Qidi-only option.
```

Changes:
- Remove `z_max_limit`; do not merely copy the commented example into the
  active section.

Why:
- Mainline Klipper does not support `z_max_limit` in this section. Preserve the
  other chamber-heater settings.

### 1.6 Load-cell probe section (replaces stock `probe_air`)

```ini
[load_cell_probe]
sensor_type: cs1237
sclk_pin: THR:PB3
dout_pin: THR:PB4
sample_rate: 1280
gain: 128
# CS1237 channel and reference-output settings.
channel: A
refout_off: False
sensor_orientation: normal
# The nozzle is the probe. Save material/first-layer adjustment separately.
z_offset: 0
speed: 5
lift_speed: 5
samples: 2
sample_retract_dist: 3
samples_result: average
samples_tolerance: 0.02
samples_tolerance_retries: 10
# Force threshold in grams that counts as a tap.
# 75g is conservative for a direct-drive setup; lower if probe misses taps.
trigger_force: 75
force_safety_limit: 2000
# Uncomment and fill in after running LOAD_CELL_CALIBRATE:
#counts_per_gram: ...
#reference_tare_counts: ...
```

Changes:
- Replaces stock `probe_air` block with mainline `load_cell_probe` using `cs1237`.
- Remove the stock `c_sensor`, `voltage`, `delta_v`, and probe-offset values;
  they are not options for the native mainline integration.
- Keeps probe `z_offset` at zero and uses a separate runtime G-code offset for
  first-layer adjustment.
- Retain existing force-calibration values only when they belong to this
  printer, then verify them with the diagnostic and tap tests.

Why:
- The CS1237 patch integrates into Klipper's mainline load-cell probe stack.

## 2) `gcode_macro.cfg` sections

### 2.1 Z load-cell homing macros

```ini
[gcode_macro save_zoffset]
gcode:
    {% if printer.gcode_move.homing_origin.z < 0.5 %}
       SAVE_VARIABLE VARIABLE=z_offset VALUE={printer.gcode_move.homing_origin.z}
    {% endif %}

[gcode_macro set_zoffset]
gcode:
    {% set z = printer.save_variables.variables.z_offset|default(0) %}
    SET_GCODE_OFFSET Z={z} MOVE=0

[gcode_macro _HOME_Z]
gcode:
    SET_GCODE_OFFSET Z=0 MOVE=0
    G28 Z
    G91
    G1 Z10 F600
    G90
```

Changes:
- Uses native `G28 Z` through `probe:z_virtual_endstop`.
- Keeps the saved first-layer adjustment separate from the probe definition.

Why:
- Current mainline load-cell probing no longer requires the former
  `_HOME_Z_FROM_LAST_PROBE` kinematic workaround.

### 2.2 Homing override

If the configuration uses `[homing_override]`, include Z in its `axes` option
and route requested Z homing through `_HOME_Z`. Preserve the printer's existing
X/Y homing behavior. A complete working example is available in
`personal_config_reference/gcode_macro.cfg`.

Changes:
- Allows full and Z-only homing to reach the native load-cell virtual endstop.

Why:
- An override that intercepts Z without dispatching it prevents `G28 Z` from
  reaching the native homing path.

### 2.3 Stock macro audit

The stock macros span `gcode_macro.cfg`, `plr.cfg`, and the box configuration.
Audit `PRINT_START`, `PRINT_END`, `CANCEL_PRINT`, `PAUSE`, `RESUME_PRINT`, and
any filament-change macros against the includes retained on this printer.

Calls associated with omitted Qidi box or power-loss-recovery components may
include:

- `BUFFER_MONITORING` and `box_extras` objects;
- `DISABLE_BOX_HEATER`;
- `CLEAR_LAST_FILE` and `save_last_file`; and
- `G31` or other helper macros whose definitions or dependencies were removed.

Do not remove a normal G-code macro merely because it originated in the stock
configuration. Remove or replace a call only when its defining include or
underlying Qidi-only object is absent from the mainline installation.

Preserve the printer's heating, cleaning, meshing, filament, and parking
workflow. Update the Z portion so the runtime offset is cleared before probing,
native Z homing is used, and the saved first-layer offset is applied only after
probing:

```gcode
SET_GCODE_OFFSET Z=0 MOVE=0
G28 Z
Z_TILT_ADJUST
# Run bed meshing as required by this printer.
set_zoffset
```

The complete adapted personal example shows these changes in context; copy
only the portions appropriate for the target printer.

## 3) Notes

- Full minimal reference sections are also available in:
  - `config_changes/printer.cfg`
  - `config_changes/gcode_macro.cfg`
- A complete adapted personal configuration is available in
  `personal_config_reference/`.
- Load-cell commissioning workflow is documented in `docs/LOAD_CELL_CALIBRATION.md`.
- Keep `[load_cell_probe] z_offset: 0`. Do not use `PROBE_CALIBRATE` or
  `Z_OFFSET_APPLY_PROBE` to save a material or first-layer adjustment.
