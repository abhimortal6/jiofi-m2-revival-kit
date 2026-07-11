# JioFi M2 Ver-2 Revival Kit (PEG_M2_B37 / "Pegasus M2")

Un-brick a dead or boot-looping **JioFi M2 Ver-2** (PEG_M2_B37, Qualcomm
MDM9x07-class, Toshiba KSLCMBL2VA2M2A 512 MiB NAND). One PowerShell script does
everything — detect the device's state, diagnose *why* it won't boot, and repair
it. Runs on stock **Windows 10/11** with the built-in PowerShell; no QPST/QFIL.

> **New here? Read the [Beginner walkthrough](#beginner-walkthrough-start-here)
> below, top to bottom.** It assumes zero prior flashing experience.

---

## Download

The code and docs live in this repo. The **actual kit** (script + flash tools +
firmware images) is a single download, because the firmware is too large for
GitHub's file limit:

➡️ **Grab `JioFi_M2_Revival_Kit_v1.0.zip` from the [Releases](../../releases)
page and extract it somewhere simple like `C:\JioFiKit`.**

Everything below is run from inside that extracted folder.

---

## ⚠️ Read first — safety & legal

- This kit **preserves your device's identity** (IMEI, calibration in the EFS2
  partition) in every normal mode. It backs up before it writes.
- The `imei_tool/` and the donor-EFS restore path exist **only** for the
  disaster case where a device's identity is already destroyed. **Only ever
  write your own device's original IMEI** (printed on the label under the
  battery). Operating a device with someone else's IMEI is illegal in most
  countries, including India.
- Flashing carries risk. This kit is designed to be recoverable (the cold-boot
  test-point short always forces EDL again), but you use it at your own risk.
  No warranty — see LICENSE.

---

## Beginner walkthrough (start here)

You will: install a USB driver → (if needed) let Windows accept it → put the
device in "9008" repair mode → run the script → follow what it tells you.

### Step 1 — Install the Qualcomm 9008 (QDLoader) USB driver

When the JioFi is in repair mode, Windows must see it as
**`Qualcomm HS-USB QDLoader 9008 (COMx)`** in Device Manager. That needs the
Qualcomm USB driver ("qcser" / "QDLoader"). See
[Driver installation](#driver-installation-details) for the full how-to. Do this
once, before anything else.

**Quick check:** open **Device Manager** (press `Win+X`, choose *Device
Manager*). You'll come back here after Step 3 to confirm the device shows up.

### Step 2 — Let Windows load the driver (Driver Signature Enforcement)

Some Qualcomm driver packages are **test-signed**. On a normal PC, Windows
refuses to load them and Device Manager shows the device with a yellow **error
code 52** ("Windows cannot verify the digital signature…"). If that happens you
must temporarily **disable Driver Signature Enforcement (DSE)**. Full steps are
in [Disabling Driver Signature Enforcement](#disabling-driver-signature-enforcement-dse).
If your driver installed cleanly (no code 52), you can skip this.

### Step 3 — Put the JioFi into 9008 (EDL) repair mode

The device has to be in **Emergency Download (EDL / 9008)** mode for the kit to
talk to its flash. Because the bootloader is broken, you force it with a
**hardware test-point short**:

1. Power the device **fully off** (remove the battery if it has one, wait ~10 s).
2. Locate the **EDL test point** on the board (a small pad you briefly short to
   ground — see the JioFi M2 XDA thread / YouTube for the exact spot on your
   revision).
3. **Short the test point to ground, and while holding it, plug in USB.**
4. Watch Device Manager. The instant it shows
   **`Qualcomm HS-USB QDLoader 9008 (COMx)`**, **release the short.**

> If you instead see **`Qualcomm HS-USB Diagnostics 900E`**, that's the crash
> port — the kit can still read the crash reason from it (great for diagnosis),
> but to *flash* you need 9008. Redo the short and release a moment later.

### Step 4 — Run the kit

1. Open **PowerShell** in the extracted kit folder: in File Explorer, `Shift` +
   right-click the folder → *Open PowerShell window here* (or run `powershell`
   and `cd` into it).
2. Run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File revive.ps1
   ```
3. The script auto-detects the device state and **tells you the recommended next
   command.** Follow it. That's it.

### Step 5 — Follow the recommendation

- If it found the **EFS log-region wedge** (the most common "won't boot"), it
  points you to `revive.ps1 -Mode EfsFix` — a lossless one-block repair.
- If the **boot chain is corrupt**, it points you to `revive.ps1 -Mode FullFlash`.
- After a repair the script reboots the device and watches USB; success =
  `Remote NDIS…` appears (the WiFi router is up). Open **http://192.168.1.1/**.

---

## Driver installation (details)

You need the **Qualcomm HS-USB QDLoader 9008** driver (package name usually
`qcser`, publisher "Qualcomm Incorporated").

1. Obtain a Qualcomm QDLoader 9008 driver package (search "Qualcomm USB Driver
   QDLoader 9008" — Qualcomm's own signed package is best; many phone-vendor
   packages include it). This kit does **not** bundle a driver.
2. Put the device in 9008 (Step 3). Windows will show an unknown/`QHSUSB` device
   or a COM port needing a driver.
3. Install the driver:
   - Run the driver package's installer, **or**
   - In **Device Manager**, right-click the device → *Update driver* → *Browse my
     computer* → point it at the extracted driver folder (the one containing
     `qcser.inf` / `.inf` files) → accept.
4. Success looks like: **`Qualcomm HS-USB QDLoader 9008 (COM3)`** with **Status:
   OK** (no yellow mark). Note the **COM number** — the script auto-detects it,
   but you can force it with `-Port COM3` if needed.

**Verify from PowerShell:**
```powershell
Get-PnpDevice -PresentOnly | Where-Object {$_.FriendlyName -match 'QDLoader'} |
  Select-Object FriendlyName, Status
```
Status must be **OK**.

---

## Disabling Driver Signature Enforcement (DSE)

Only needed if your driver shows **code 52** / "digital signature" errors
(common with test-signed Qualcomm drivers). Pick one method.

### Method A — One-time (recommended, per-boot, safest)

No permanent change; the setting reverts on next normal reboot.

1. **Settings → System → Recovery → Advanced startup → Restart now**
   (or hold **Shift** while clicking **Restart** in the Start menu).
2. After it reboots into the blue menu:
   **Troubleshoot → Advanced options → Startup Settings → Restart.**
3. When the numbered list appears, press **7** (or **F7**) for
   **"Disable driver signature enforcement."**
4. Windows boots with enforcement off *for this session.* Now install the driver
   (Step 1) — it will load. It keeps working until you next reboot.

### Method B — Persistent (test-signing mode)

Survives reboots, but shows a "Test Mode" watermark and **requires Secure Boot
to be OFF** (test-signing cannot be enabled while Secure Boot is on).

1. If needed, turn **Secure Boot OFF** in your PC's UEFI/BIOS.
2. Open **PowerShell as Administrator** and run:
   ```powershell
   bcdedit /set testsigning on
   ```
3. **Reboot.** Install the driver. To undo later:
   `bcdedit /set testsigning off` then reboot.

> **Secure Boot note:** if `bcdedit` says the value is protected by Secure Boot
> policy, you must disable Secure Boot in UEFI first, or just use **Method A**
> (which works regardless of Secure Boot).

---

## Device states you may see (Device Manager)

| USB device | Meaning | What the kit does |
|---|---|---|
| `Qualcomm HS-USB QDLoader 9008 (COMx)` | EDL / repair mode. Ready to flash. | Diagnose, flash, or repair EFS |
| `Qualcomm HS-USB Diagnostics 900E (COMx)` | **Crash-dump mode** — modem hit a fatal error and is looping. | Reads the actual crash reason from RAM (`-Mode CrashLog`) |
| `Remote NDIS based Internet Sharing Device` | Normal, healthy boot | Nothing to do — it's alive |
| Nothing at all | Cable / driver / power issue | See Troubleshooting |

## The two failure modes this kit fixes

1. **Corrupt boot chain (stuck in 9008 forever)** — `-Mode FullFlash` reflashes
   all system partitions from the donor images (SBL → s_dtm2), **skipping EFS2**
   so your IMEI/calibration are kept. Cache is erased (rebuilt on boot).
2. **EFS2 log-region wedge (boot-loops into 900E)** — the modem dies at mount
   with `fs_logr.c: Ran out of good blocks in log-rgn`. EFS2 keeps a circular
   transaction log in the last 8 blocks of the partition; if one log block goes
   bad while the rest are full, the filesystem can never mount again. Extremely
   common "natural death" (half-boot, LED on, no WiFi). `-Mode EfsFix` erases
   only the **oldest stale** log generation — **all data, IMEI, calibration
   survive.** This exact fix revived the reference device with zero data loss.

## Usage

```powershell
revive.ps1                          # Auto: detect state, diagnose, recommend
revive.ps1 -Mode Diagnose           # EDL: check controller, EFS log region, SBL
revive.ps1 -Mode EfsFix             # EDL: repair the EFS log-region wedge
revive.ps1 -Mode EfsFix -EraseAllStale   # bigger hammer if one block wasn't enough
revive.ps1 -Mode FullFlash          # EDL: flash all donor partitions (keeps EFS2)
revive.ps1 -Mode FullFlash -FlashCache   # also flash donor cache (needs cache.oob)
revive.ps1 -Mode Backup             # EDL: raw-dump the EFS2 region (do this first!)
revive.ps1 -Mode CrashLog           # 900E: read the modem's crash reason from RAM
revive.ps1 -Mode EfsWipe            # LAST RESORT: wipe EFS2 (destroys IMEI/cal!)
revive.ps1 -Mode EfsRestore         # LAST RESORT: flash a donor EFS you supply
revive.ps1 ... -Yes                 # skip confirmations (never skips EfsWipe/EfsRestore)
revive.ps1 ... -Port COM3           # force the COM port instead of auto-detect
```

### EFS repair escalation ladder (follow in order, never skip ahead)

1. `-Mode EfsFix` — lossless, erases one stale log block. Fixed the reference device.
2. `-Mode EfsFix -EraseAllStale` — lossless, erases every stale log generation.
3. `-Mode EfsWipe` — **destructive last resort** for genuinely destroyed EFS
   data (still shows an EFS crash string after step 2). Wipes EFS2; the modem
   formats a fresh one on boot. IMEI/calibration are lost — rewrite **your
   own** IMEI from the label with `imei_tool/` afterwards. A raw backup is taken
   first, so it's reversible in the raw sense.
4. `-Mode EfsRestore` — **absolute last resort**. Flashes an EFS image you place
   at `images/02-0-EFS2-donor.oob`. The kit ships **no** EFS image; you must
   supply your own device's backup. If you use anyone else's, the device carries
   that IMEI and you must immediately rewrite your own. Never operate on a
   foreign IMEI.

### Recommended flow — boot-looping (900E) device
1. `revive.ps1` → reads the crash reason over the 900E port.
2. If it's the `fs_logr` message: enter 9008 EDL and run `revive.ps1 -Mode EfsFix`.
3. Reboots; `Remote NDIS…` appears → done. Open http://192.168.1.1/.
4. Still 900E? `revive.ps1 -Mode EfsFix -EraseAllStale`.

### Recommended flow — 9008-dead device
1. `revive.ps1` (auto-diagnose). If SBL ≠ donor → `-Mode FullFlash`.
2. If it then boot-loops into 900E, follow the 900E flow (the two often coexist).

## Getting into EDL (9008) manually

The brokened bootloader means the device won't enter 9008 by itself:
- **Test point (reliable):** short the EDL pad to ground while plugging in USB;
  release the instant `QDLoader 9008` appears. Exact pad location is in the
  JioFi M2 XDA thread / community videos for your board revision.
- Some units enter EDL via boot-loop timing (plug USB at the reset moment) —
  fiddly, needs a few tries.

## After revival: SIM / IMEI fields

- **IMEI** lives in the device (EFS2) — the kit preserves it.
- **IMSI / ICCID / MSISDN** come from the **SIM card**. All-zeros just means no
  SIM is inserted/detected — insert a SIM and reboot.

## Technical background (for the curious)

- The NAND must be driven with 516-byte codewords, **BCH-8 ECC** (13 B/codeword),
  2 spare bytes, **bad-block marker at user+0x175**. Generic "peek" loaders leave
  the NAND controller misconfigured and **silently corrupt every write** while
  their reads self-consistently "verify" fine. The kit pokes the controller
  registers (`0x079b0020 = 295409C0 08065D5D 42040D11`) after every loader load
  and **hard-verifies them before any write.**
- Images are written with `qwdirect -fi -ub -uc -z128`. The `-z128` is essential:
  without it qtools misparses this chip's OOB as 512+32 and writes garbage.
- EFS2 occupies blocks 0x14–0x43; its last 8 blocks are the log region, each
  starting with a superblock page (`EFSSuper` magic at data +0x08, 16-bit age at
  +0x06). Newest age = live state; older generations are reclaimable — unless the
  log wedges. `-Mode Diagnose` prints the full generation map.
- 900E is a Sahara **memory-debug** interface. The kit speaks just enough Sahara
  (hello → mode 2 → memory_read) to dump the SMEM area at `0x87C00000`, where the
  modem leaves its `ERR_FATAL` string.

## Safety rules baked into the script

1. No write happens unless the controller registers verify byte-exact.
2. EFS2 is raw-backed-up (with OOB) before *any* modification; the restore
   command is printed with the backup.
3. `EfsFix` erases the minimum (one stale block), verifies the erase, and never
   touches the newest generation or any data block.
4. SBL is raw-verified byte-for-byte after flashing; the script refuses to reboot
   on a mismatch.
5. EFS2 / IMEI is never flashed from donor data in any normal mode.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Device is `900E`, not `9008` | That's the crash port. Redo the test-point short, release a moment later, to land on 9008. `-Mode CrashLog` still reads the crash reason from 900E. |
| Driver **code 52** / signature error | [Disable Driver Signature Enforcement](#disabling-driver-signature-enforcement-dse) (Method A), then install the driver. |
| No device in Device Manager at all | Bad/charge-only cable, no power, or PBL not reached. Try another cable/port, re-seat battery, redo the short. |
| `Hello packet not received` | One EDL session per loader load: unplug, re-enter 9008, rerun. |
| Banner geometry wrong / register verify fails | Replug and retry; **never** flash in this state. |
| `EfsFix` says erase didn't verify | That block may be dying; reboot anyway (modem may remap). If not, rerun with `-EraseAllStale`. |
| Still 900E after `-EraseAllStale` | `-Mode CrashLog` again — a changed message = progress. |
| Boot-loops 9008↔reboot during flash | Cable/hub issue; use a rear USB port. |

## What's in the kit (the Release zip)

| Path | What |
|---|---|
| `revive.ps1` | The automation script — this is all you run |
| `qtool/` | qtools binaries + patched NPRG/ENPRG loaders + `chipset.cfg` (GPLv3, see `qtool/LICENSE`) |
| `qtool/qwdirect_jmr.exe` | The proven qwdirect build used for all writes/erases |
| `images/*.oob` | Donor firmware dumps (raw data+OOB, 512+16/sector) |
| `imei_tool/` | Qualcomm IMEI write tool — **only** to restore your own device's IMEI after EfsWipe |
| `rescue_YYYYMMDD_*/` | Created per run: your backups, logs, dumps |

The kit ships **no EFS2/identity image** — that would publish a real IMEI. See
`images/README.md`.

## Credits & licenses

This kit builds on others' work; their attribution and licenses are preserved in
**[NOTICE](NOTICE)**:
- **qtools** (qdload/qrflash/qwdirect/qbadblock/…) — by **forth32**, GPLv3
  (`qtool/LICENSE`), <https://github.com/forth32/qtools>
- **Patched NAND loaders** — from **bkerler**'s Loaders,
  <https://github.com/bkerler/Loaders>
- JioFi M2 Ver-2 community — the XDA JioFi M2 R&D thread.

Original work in this repo (`revive.ps1`, docs) is MIT — see **[LICENSE](LICENSE)**.

---
*Reference device revived July 2026 with IMEI intact, via a full boot-chain
reflash + EFS log-region repair.*
