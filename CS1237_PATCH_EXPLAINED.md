# CS1237 Patch Explained

This document explains the CS1237 integration in the current repository patchset.

## 1) Where this patch lives

CS1237 changes are inside:

- `patches/klipper/0002-load_cell-add-CS1237-ADC-support.patch`

Supported fallback revisions are listed in
[docs/KNOWN_GOOD_MATRIX.md](docs/KNOWN_GOOD_MATRIX.md).

The GD32F425 USB workaround and Q2 communication timeout are separate patches
in the numbered Klipper series.

## 2) File ownership

The CS1237 patch touches:

- `src/sensor_cs1237.c`
- `src/Kconfig`
- `src/Makefile`
- `klippy/extras/cs1237.py`
- `klippy/extras/load_cell.py`
- `klippy/extras/load_cell_probe.py`
- `docs/Config_Reference.md`
- `test/klippy/load_cell.cfg`

## 3) Relationship to the USB patch

The CS1237 and GD32 USB changes are separate and do not modify the same source
files.

## 4) How CS1237 fits mainline architecture

Mainline load-cell support pattern is:

1. MCU driver in `src/`
2. Host wrapper in `klippy/extras/`
3. Registration in load-cell plumbing (`load_cell.py` / `load_cell_probe.py`)
4. Trigger-analog integration for probing/homing behavior

This patch adds CS1237 following that same model.

## 5) Build and config integration

### `src/Kconfig`

Adds and wires:

- `WANT_CS1237`
- inclusion in `NEED_SENSOR_BULK` dependency path
- inclusion in `WANT_TRIGGER_ANALOG` dependency path

Effect:

- CS1237 becomes a first-class bulk sensor and can participate in trigger-based probing workflows.

### `src/Makefile`

Adds:

- `src-$(CONFIG_WANT_CS1237) += sensor_cs1237.c`

Effect:

- driver is compiled into firmware when enabled.

## 6) MCU-side driver (`src/sensor_cs1237.c`)

### A) Bidirectional single-wire behavior

The CS1237 DOUT line is used for read and command phases, so the driver manages both:

- input pin state
- output pin driving

with direction switching during command/config transactions.

### B) Protocol operations

Implements CS1237-specific operations:

- frame/sample reads
- config write command
- config read command
- readback verification

This is why it is not a drop-in alias of the existing HX71X path.

### C) Startup/config validation

On active query:

1. wake/configure sensor
2. read back config
3. verify expected bits

On failure:

- emits CS1237 config error marker to bulk stream
- reports trigger_analog-compatible sensor errors

### D) Sampling/error model

Uses periodic capture + bulk reporting and defines sentinel/error paths for:

- timeout
- overflow/long read path
- config failure

These errors are surfaced in a way load-cell probing logic can act on.

## 7) Host-side wrapper (`klippy/extras/cs1237.py`)

Main responsibilities:

1. Parse CS1237 options (`sample_rate`, `gain`, `channel`, `refout_off`)
2. Build config register and send `config_cs1237`
3. Start/stop streaming via bulk helpers
4. Convert/report samples and map sensor-specific error codes

The sensor type is `cs1237`. Its options include `sample_rate`, `gain`,
`channel`, and `refout_off`; force direction is handled by the native
`sensor_orientation` option.

## 8) Load-cell integration files

### `klippy/extras/load_cell.py`

- imports CS1237 module
- adds `CS1237_SENSOR_TYPE` to load-cell sensor registry

### `klippy/extras/load_cell_probe.py`

- imports CS1237 module
- adds `CS1237_SENSOR_TYPE` to probe sensor registry

Result:

- existing load-cell and load-cell-probe flows can instantiate CS1237 through normal `sensor_type` selection.

## 9) Relationship to the other Q2 patches

CS1237 does not implement the USB workaround.

Both are required for full Q2 stock-hardware usability:

1. GD32 USB patch: stable mainboard USB flashing/runtime communication
2. CS1237 patch: working load-cell support on mainline

The third Klipper patch extends the multi-MCU trigger synchronization timeout
used by the Q2 load-cell path. It does not alter CS1237 sampling or force
calibration.

For USB details, see [GD32F425_USB_PATCH_EXPLAINED.md](GD32F425_USB_PATCH_EXPLAINED.md).

## 10) Setup and calibration workflow

After firmware patching, setup/calibration should follow Klipper load-cell commissioning flow (diagnostics first, then interactive calibration).

Q2-specific practical workflow used in this project is documented here:

- [docs/LOAD_CELL_CALIBRATION.md](docs/LOAD_CELL_CALIBRATION.md)

The force calibration stores `counts_per_gram` and `reference_tare_counts`.
The Q2 nozzle itself is the probe, so `[load_cell_probe] z_offset` remains
`0`; material/first-layer correction is saved separately as a runtime G-code
offset.
