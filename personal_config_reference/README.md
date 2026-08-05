# Personal Config Reference

These files provide an adapted configuration reference for Q2 mainline
Klipper. You WILL need to adapt them for your own purposes, including the
part-cooling fan connection and other machine-specific choices.

The load-cell calibration values below are recorded only as a reference. Do not
use them as production values on another printer; calibrate that machine and
verify its force direction and safety limit independently.

```ini
[load_cell_probe]
counts_per_gram = 179.39500
reference_tare_counts = -1113211
```

The load-cell probe itself uses `z_offset: 0`. The `save_zoffset` and
`set_zoffset` macros preserve the separate runtime first-layer adjustment in
`saved_variables.cfg`.
