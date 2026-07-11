# Firmware images

The firmware partition dumps are **not** in this git repo (too large for
GitHub). They ship inside the **Release** download. When you extract
`JioFi_M2_Revival_Kit_v1.0.zip` from the [Releases](../../releases) page, this
`images/` folder is filled in and `revive.ps1 -Mode FullFlash` works.

Format: raw NAND page dumps, **data + OOB interleaved, 512 + 16 bytes per
sector** (hence written with `qwdirect ... -z128`).

**No EFS2 / identity image is shipped** — EFS2 holds a real IMEI and RF
calibration. `EfsFix` and `FullFlash` never need it; the `EfsRestore` last-resort
mode requires **you** to supply your own device's EFS backup (place it here as
`02-0-EFS2-donor.oob`).

Modes that need **no** images at all: `-Mode Diagnose`, `-Mode EfsFix`, and the
900E `-Mode CrashLog`.
