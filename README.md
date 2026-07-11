# JioFi M2 Ver-2 Revival Kit

Un-brick a dead or boot-looping **JioFi M2 Ver-2** (PEG_M2_B37, Qualcomm MDM9x07
NAND) from Windows. One PowerShell script figures out *why* it won't boot and
repairs it — **keeping your IMEI**. No QPST/QFIL needed.

## Download

Get **`JioFi_M2_Revival_Kit_v1.1.zip`** from the [Releases](../../releases) page,
extract it (e.g. to `C:\JioFiKit`), and open PowerShell in that folder.

## Steps

1. **Install the driver** — the Qualcomm *HS-USB QDLoader 9008* USB driver.
   (If Device Manager later shows the device with **code 52**, see
   [Driver signature](#driver-signature-code-52-only) below.)
2. **Enter 9008 mode** — power the device fully off, then **short the EDL test
   point to ground while plugging in USB**; release the moment Device Manager
   shows `Qualcomm HS-USB QDLoader 9008 (COMx)`.
3. **Run it:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File revive.ps1
   ```
4. It detects the state and **prints the exact command to run next.** Follow it.
5. Success = the device reboots and `Remote NDIS…` appears. Open
   **http://192.168.1.1/**.

## Usage

```powershell
revive.ps1                       # auto-detect + recommend what to do
revive.ps1 -Mode Diagnose        # check controller / EFS / SBL, no writes
revive.ps1 -Mode EfsFix          # repair the common EFS log-region wedge (keeps data)
revive.ps1 -Mode FullFlash       # reflash boot chain from donor (keeps IMEI)
revive.ps1 -Mode CrashLog        # read the crash reason from a 900E device
revive.ps1 -Port COM3            # force the COM port if auto-detect misses it
```

**If it won't boot, try in this order:** `-Mode EfsFix` →
`-Mode EfsFix -EraseAllStale` → (last resort) `-Mode FullFlash`.

## Driver signature (code 52 only)

If the driver won't load (yellow **code 52**), disable driver-signature
enforcement for one boot: **Settings → System → Recovery → Advanced startup →
Restart now → Troubleshoot → Advanced options → Startup Settings → Restart →
press `7`.** Then install the driver — it works until you next reboot.

## Notes

- **Your IMEI is safe** — normal modes never touch the identity partition. Only
  ever write your *own* device's IMEI.
- Built on **qtools** (forth32, GPLv3) + patched loaders (bkerler). Attribution
  and licenses in [NOTICE](NOTICE); original script/docs are MIT ([LICENSE](LICENSE)).
- Thanks to **sheikhshahnawaz41299** for the firmware backups and tools.
