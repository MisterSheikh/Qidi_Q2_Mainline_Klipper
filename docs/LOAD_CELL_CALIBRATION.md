# Qidi Q2 CS1237 Load Cell Calibration Workflow

This document explains the practical calibration workflow used on Qidi Q2 with the CS1237 mainline integration in this repo.

It follows Klipper's load-cell calibration model, with Q2-specific handling for safely applying a known force.

This guide calibrates force measurement only. The Q2 nozzle is the probe, so
`[load_cell_probe] z_offset` remains `0`. First-layer adjustment is a separate
runtime G-code offset.

## 1) Prerequisites

1. CS1237 patch is applied and firmware is running.
2. `[load_cell_probe]` is configured. `loadcell.cfg` is an optional reference
   fragment; merge it into the active configuration or include it, but do not
   define `[load_cell_probe]` twice.
3. Utility macros `Fake_Home_Z` and `Fake_Home_Z_MAX` are available (see
   `utility_macros.cfg`). Copy that file to your Klipper config directory and
   add `[include utility_macros.cfg]` to `printer.cfg`.
4. You have a reliable digital scale capable of measuring at least 2 kg.
5. You can move Z from the web UI/console.

## 2) Important command information

Calibration is interactive:

1. Start tool: `LOAD_CELL_CALIBRATE`
2. Set zero point: `TARE`
3. Apply known load, then solve scale factor: `CALIBRATE GRAMS=<value>`
4. Accept result: `ACCEPT`
5. Persist config: `SAVE_CONFIG`

If needed, cancel with `ABORT`.

## 3) Recommended commissioning order

Use a workflow aligned with [Klipper load-cell docs](https://www.klipper3d.org/Load_Cell.html#load-cell-probes):

1. Run initial sensor health check:
```gcode
LOAD_CELL_DIAGNOSTIC
```
2. Confirm sample rate and noise look reasonable.
3. Then perform calibration (`LOAD_CELL_CALIBRATE` flow).

Do not treat `LOAD_CELL_CALIBRATE` as optional if you want correct force behavior.

An existing installation may retain that printer's current `counts_per_gram`
and `reference_tare_counts` during the update, then validate them with the
diagnostic and tap tests before deciding whether to recalibrate. Do not copy
these machine-specific values from another Q2.

## 4) Practical Q2 calibration workflow used here

This is the exact process I used to calibrate on the Q2:

1. If you need to lower the bed first so the scale fits:
```gcode
Fake_Home_Z
```
This sets `Z=0`, then you can lower the bed by increasing the Z value in the UI.
2. Put a digital scale (kitchen scale or something suitable) on the bed.
3. Ensure enough Z clearance so the nozzle does not contact the scale.
4. Turn on the scale and tare it to `0`.
5. Run:
```gcode
Fake_Home_Z_MAX
```
This sets a fake Z home so bed Z motion can be controlled in the UI.
6. Start calibration mode:
```gcode
LOAD_CELL_CALIBRATE
```
7. With no contact force yet, run:
```gcode
TARE
```
8. Raise the bed into the nozzle slowly (on the Q2 this is done by decreasing Z value).
9. Once the nozzle is very close to the scale, approach in small steps (`0.10` or `0.05` mm) until the nozzle makes contact with the scale, adjust carefully until the scale reads at least around `1000g`. That is the lowest amount recommended in the Klipper docs.
10. Use that measured value in calibration, for example:
```gcode
CALIBRATE GRAMS=1001
```
11. When Klipper reports solved calibration values, run:
```gcode
ACCEPT
SAVE_CONFIG
```

## 5) What gets saved

Successful calibration yields values for:

- `counts_per_gram`
- `reference_tare_counts`

These are the key parameters required for accurate force reporting and load-cell probe safety limits.

## 6) Probe offset versus print offset

Keep the probe definition at:

```ini
[load_cell_probe]
z_offset: 0
```

Do not use the generic paper-based `PROBE_CALIBRATE` procedure for the Q2
load-cell nozzle, and do not use `Z_OFFSET_APPLY_PROBE` to save a first-layer
adjustment into the probe definition.

Reset the runtime print offset before homing, Z tilt, and bed meshing:

```gcode
SET_GCODE_OFFSET Z=0 MOVE=0
```

After probing is complete, apply the saved value with `set_zoffset`. Tune that
runtime offset while observing a real first layer for the material and build
surface in use, then save it through the existing `save_zoffset` macro and
`saved_variables.cfg`.

## 7) Post-calibration checks

After saving config:

1. Restart Klipper.
2. Run `LOAD_CELL_DIAGNOSTIC` again.
3. Run `LOAD_CELL_TEST_TAP` and confirm reliable trigger behavior.
4. Verify probing/homing behavior before full print workflows.

## 8) Notes specific to this repo

1. `loadcell.cfg` includes useful setup context, but follow this calibration flow for final commissioning.
2. Macro names used in this workflow are `Fake_Home_Z` and `Fake_Home_Z_MAX` (exact case as defined in `utility_macros.cfg`).
