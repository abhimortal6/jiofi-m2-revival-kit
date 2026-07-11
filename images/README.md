# Firmware images

The donor firmware partition dumps live **right here in this folder** — you do
not need to download anything separately. After you clone the repo they are
already in place and `revive.ps1 -Mode FullFlash` works out of the box.

Format: raw NAND page dumps, **data + OOB interleaved, 512 + 16 bytes per
sector** (that is why they must be written with `qwdirect ... -z128`).

## Two things are intentionally NOT here

- **`17-0-cache.oob`** — the cache image is ~146 MB, over GitHub's 100 MB
  per-file limit. It is not needed: `FullFlash` **erases** the cache region and
  the device rebuilds it on boot. Only `-FlashCache` would use it, and for that
  you can dump your own device's cache.
- **`02-0-EFS2.oob` (device identity / IMEI)** — no EFS2 image is shipped, ever.
  EFS2 holds a real IMEI and RF calibration. `EfsFix` and `FullFlash` never
  need it. The `EfsRestore` last-resort mode requires **you** to supply your own
  device's EFS backup (place it here as `02-0-EFS2-donor.oob`); the kit will not
  hand you someone else's identity.

## If `images/` is empty

Only `-Mode FullFlash` needs these files. `-Mode Diagnose`, `-Mode EfsFix`, and
the 900E `-Mode CrashLog` all work without any firmware images.
