# =============================================================================
#  JioFi M2 Ver-2 (PEG_M2_B37 / "Pegasus M2") REVIVAL SCRIPT
# =============================================================================
#  Revives a bricked/boot-looping JioFi M2 Ver-2 (Qualcomm MDM9x07 class,
#  Toshiba KSLCMBL2VA2M2A 512MiB NAND, 4K pages + 128B OOB, BCH-8 ECC,
#  516B codewords, bad-block marker at user+0x175).
#
#  Handles ALL known device states:
#    * 9008 EDL (QDLoader)      -> diagnose / flash / EFS repair
#    * 900E crash-dump (Sahara) -> read the modem's crash reason from RAM
#    * Normal boot (RNDIS)      -> nothing to do
#
#  Requires: Windows PowerShell 5.1+ (built into Windows 10/11), the files
#  bundled in this kit (qtool\, images\), and a working Qualcomm 9008 serial
#  driver. NO other software needed.
#
#  USAGE (run from an elevated-or-normal PowerShell prompt, kit dir intact):
#    powershell -ExecutionPolicy Bypass -File revive.ps1                 # auto
#    powershell -ExecutionPolicy Bypass -File revive.ps1 -Mode Diagnose
#    powershell -ExecutionPolicy Bypass -File revive.ps1 -Mode EfsFix
#    powershell -ExecutionPolicy Bypass -File revive.ps1 -Mode EfsFix -EraseAllStale
#    powershell -ExecutionPolicy Bypass -File revive.ps1 -Mode FullFlash
#    powershell -ExecutionPolicy Bypass -File revive.ps1 -Mode Backup
#    powershell -ExecutionPolicy Bypass -File revive.ps1 -Mode CrashLog
#    powershell -ExecutionPolicy Bypass -File revive.ps1 -Port COM3       # force port
#    powershell -ExecutionPolicy Bypass -File revive.ps1 -Mode EfsWipe    # LAST RESORT
#    powershell -ExecutionPolicy Bypass -File revive.ps1 -Mode EfsRestore # LAST RESORT (donor EFS)
#
#  Read README.md first. Short version of the philosophy:
#    - NEVER flash anything until the NAND controller config is verified.
#    - NEVER touch the EFS2 partition data (blocks 0x14-0x43) - it holds the
#      device's IMEI and RF calibration. The only EFS operation this script
#      performs is the surgical "log region" repair, which erases stale
#      transaction-log blocks and preserves all filesystem data.
#    - ALWAYS take a raw backup before any destructive step.
# =============================================================================

param(
    [ValidateSet('Auto','Diagnose','EfsFix','FullFlash','Backup','CrashLog','EfsWipe','EfsRestore')]
    [string]$Mode = 'Auto',
    # EfsFix: erase ALL stale log generations instead of only the oldest one.
    # Use if a previous default EfsFix run did not stop the 900E loop.
    [switch]$EraseAllStale,
    # FullFlash: also flash the donor cache image (default: cache is erased,
    # the device rebuilds it - that is the donor-proven flow).
    [switch]$FlashCache,
    # Force the COM port (e.g. -Port COM3 or -Port 3) if auto-detect misses it.
    [string]$Port = '',
    # Skip interactive confirmations (for the brave).
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$KIT    = $PSScriptRoot
$QTOOL  = Join-Path $KIT 'qtool'
$IMAGES = Join-Path $KIT 'images'
$STAMP  = Get-Date -Format 'yyyyMMdd_HHmmss'
$OUTDIR = Join-Path $KIT "rescue_$STAMP"

# ---- Device geometry constants (JioFi M2 Ver-2 ONLY - do not reuse blindly) --
$RAWPAGE   = 4224        # 4096 data + 128 OOB, exported by qtools as 8x(512+16)
$PAGES_PER_BLOCK = 64
$RAWBLOCK  = $RAWPAGE * $PAGES_PER_BLOCK   # 270336 bytes per block, raw
$EFS_START = 0x14        # EFS2 partition first block (absolute)
$EFS_LEN   = 0x30        # EFS2 partition length in blocks
$CACHE_START = 0x5c4
$CACHE_LEN   = 0x23c
# Known-good NAND controller register values (cfg0/cfg1/ecc_cfg @ 0x079b0020):
$REG_ADDR  = '079b0020'
$REG_VALS  = '295409C0 08065D5D 42040D11'
$REG_BYTES = 'c0 09 54 29 5d 5d 06 08 11 0d 04 42'
# Donor partition flash map: absolute start block (hex) -> image file.
# EFS2 (block 14) is DELIBERATELY absent. modm2 really is 1ad (donor
# flash.txt says 1ac - that is a typo; partition table: modem=ce+df => 1ad).
$FLASH_MAP = @(
    @{blk='0';   file='00-0-SBL.oob'},
    @{blk='a';   file='01-0-MIBIB.oob'},
    @{blk='44';  file='03-0-TZ.oob'},
    @{blk='48';  file='04-0-RPM.oob'},
    @{blk='4a';  file='05-0-aboot.oob'},
    @{blk='4c';  file='06-0-boot.oob'},
    @{blk='6c';  file='07-0-bot2.oob'},
    @{blk='8c';  file='08-0-SCRUB.oob'},
    @{blk='ce';  file='09-0-modem.oob'},
    @{blk='1ad'; file='10-0-modm2.oob'},
    @{blk='28c'; file='11-0-misc.oob'},
    @{blk='292'; file='12-0-data.oob'},
    @{blk='2bc'; file='13-0-system.oob'},
    @{blk='43c'; file='14-0-systm2.oob'},
    @{blk='5bc'; file='15-0-s_dtm1.oob'},
    @{blk='5c0'; file='16-0-s_dtm2.oob'}
)

# =============================================================================
#  Utility / plumbing
# =============================================================================

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Head([string]$msg) { Write-Host ""; Write-Host ("== $msg ==") -ForegroundColor Cyan }

function Confirm-Step([string]$what) {
    if ($Yes) { return $true }
    $ans = Read-Host "$what  Type YES to proceed"
    return ($ans -eq 'YES')
}

function New-OutDir {
    if (-not (Test-Path $OUTDIR)) { New-Item -ItemType Directory -Force $OUTDIR | Out-Null }
}

# Run a qtools EXE. qtools exit codes are unreliable (nonzero on success) and
# their Cyrillic output shows as '?' when redirected - we parse ASCII tokens
# only and never trust $LASTEXITCODE.
function Invoke-QTool([string]$exe, [string]$arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $QTOOL $exe
    $psi.Arguments = $arguments
    $psi.WorkingDirectory = $QTOOL       # so chipset.cfg + loaders\ resolve
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return $out
}

# ---- Device / port discovery ------------------------------------------------
function Get-DeviceState {
    $r = @{ State = 'NONE'; Com = $null; Name = '' }
    $devs = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'Qualcomm|Remote NDIS' }
    foreach ($d in $devs) {
        if ($d.Name -match 'QDLoader 9008.*\(COM(\d+)\)') {
            if ($d.Status -ne 'OK') { $r.State = 'EDL_BADDRIVER' } else { $r.State = 'EDL' }
            $r.Com = [int]$Matches[1]; $r.Name = $d.Name; return $r
        }
        if ($d.Name -match '900E.*\(COM(\d+)\)') {
            $r.State = 'CRASH'; $r.Com = [int]$Matches[1]; $r.Name = $d.Name; return $r
        }
        if ($d.Name -match 'Remote NDIS') { $r.State = 'NORMAL'; $r.Name = $d.Name }
    }
    return $r
}

function Wait-ForState([string[]]$wanted, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $s = Get-DeviceState
        if ($wanted -contains $s.State) { return $s }
        Start-Sleep -Seconds 3
    }
    return (Get-DeviceState)
}

# =============================================================================
#  EDL: loader + controller config (THE critical gate)
# =============================================================================

function Enter-Loader([int]$com) {
    Head "Loading flash programmer (qdload -p$com -i -k10)"
    $out = Invoke-QTool 'qdload.exe' "-p$com -i -k10"
    if ($out -match 'Read memory command failed' -or $out -match 'Unknown Flash ID = 00') {
        # The loader was sent and is running (it probes the flash itself and
        # may even name the right chip in the banner), but its peek/memory-read
        # command channel returns nothing - so the -i register setup read zeros
        # and every geometry line below it is fabricated (Sector size: 0,
        # R-S ECC, Flash ID = 00). That is a dead command channel, NOT a
        # different NAND chip. Probe once via qcommand before giving up.
        $probe = Invoke-QTool 'qcommand.exe' "-p$com -k10 -c `"d $REG_ADDR c`""
        if ($probe -notmatch '079b0020:') {
            throw ("The flash programmer loaded but does not answer memory reads`n" +
                   "('Read memory command failed' / 'Unknown Flash ID = 00'). The banner`n" +
                   "geometry below that line is garbage computed from the failed reads -`n" +
                   "this is a connection/session problem, NOT a different flash chip.`n" +
                   "Fix, in order:`n" +
                   " 1. Pull the battery, wait 10 s, re-enter EDL via the test point and`n" +
                   "    rerun IMMEDIATELY (a stale Sahara session - e.g. after a QFIL/QPST`n" +
                   "    attempt - looks exactly like this).`n" +
                   " 2. Plug into a direct/rear USB port with a short data cable - no hubs.`n" +
                   " 3. Close other Qualcomm tools (QFIL/QPST/driver utilities) that may`n" +
                   "    be holding the port.`n" +
                   "qdload said:`n$out")
        }
        Say "peek channel answered on the qcommand probe - continuing." Yellow
    } elseif ($out -match 'Hello packet not received' -or $out -notmatch 'Flash chip:') {
        # A loader may already be resident from a previous run of this script -
        # in that case qdload fails but qcommand still works. Probe it.
        $probe = Invoke-QTool 'qcommand.exe' "-p$com -k10 -c `"d $REG_ADDR c`""
        if ($probe -match '079b0020:') {
            Say "Loader already resident from a previous session - continuing." Yellow
        } else {
            throw ("Loader load failed. Unplug the device, re-enter EDL (9008) and rerun.`n" +
                   "qdload said:`n$out")
        }
    } else {
        # Sanity-check the banner geometry tokens (ASCII survives redirection)
        foreach ($tok in @('Sector size: 516', 'Page size: 4096', 'OOB size: 128', 'BCH, 8 bits')) {
            if ($out -notmatch [regex]::Escape($tok)) {
                throw "Loader banner missing '$tok' - WRONG chip or wrong loader. STOPPING.`n$out"
            }
        }
        Say "Loader loaded, flash geometry banner OK." Green
    }
    Set-NandRegs $com
}

# qdload -i re-inits the controller and can leave it half-configured; ALWAYS
# poke the proven register values and verify by reading them back.
function Set-NandRegs([int]$com) {
    Invoke-QTool 'qcommand.exe' "-p$com -k10 -c `"m $REG_ADDR $REG_VALS`"" | Out-Null
    $dump = Invoke-QTool 'qcommand.exe' "-p$com -k10 -c `"d $REG_ADDR c`""
    if ($dump -notmatch [regex]::Escape($REG_BYTES)) {
        throw ("NAND controller registers did NOT take the proven values.`n" +
               "Wanted: $REG_BYTES`nGot   : $dump`n" +
               "DO NOT FLASH in this state - replug and retry.")
    }
    Say "NAND controller config verified (516/13/2, badblock marker user+0x175)." Green
}

# =============================================================================
#  EDL: read / erase / flash primitives
# =============================================================================

function Read-RawBlocks([int]$com, [int]$startBlk, [int]$numBlk, [string]$outFile) {
    $bh = '{0:x}' -f $startBlk; $lh = '{0:x}' -f $numBlk
    $out = Invoke-QTool 'qrflash.exe' "-p$com -k10 -x -e -ui -z128 -b$bh -l$lh -o `"$outFile`""
    if (-not (Test-Path $outFile)) { throw "raw read produced no file:`n$out" }
    $want = $numBlk * $RAWBLOCK
    $got = (Get-Item $outFile).Length
    if ($got -ne $want) { throw "raw read short: got $got, expected $want bytes" }
}

function Erase-Blocks([int]$com, [int]$startBlk, [int]$numBlk) {
    $bh = '{0:x}' -f $startBlk; $lh = '{0:x}' -f $numBlk
    $out = Invoke-QTool 'qwdirect_jmr.exe' "-p$com -k10 -b$bh -c $lh"
    return $out
}

function Get-MarkedBadBlocks([int]$com, [int]$startBlk, [int]$numBlk) {
    $bh = '{0:x}' -f $startBlk; $lh = '{0:x}' -f $numBlk
    $out = Invoke-QTool 'qbadblock.exe' "-p$com -k10 -b$bh -l$lh -d"
    $bad = @()
    foreach ($m in [regex]::Matches($out, '([0-9a-fA-F]{8})\s*-\s*badblock')) {
        $bad += [Convert]::ToInt32($m.Groups[1].Value, 16)
    }
    return ,$bad
}

function Compare-Bytes([byte[]]$a, [byte[]]$b) {
    $n = [Math]::Min($a.Length, $b.Length); $diff = 0
    for ($i = 0; $i -lt $n; $i++) { if ($a[$i] -ne $b[$i]) { $diff++ } }
    return $diff + [Math]::Abs($a.Length - $b.Length)
}

# =============================================================================
#  EFS2 log-region analysis (pure file analysis, no device access)
# =============================================================================
#  EFS2-on-NAND keeps a circular transaction log in the last blocks of the EFS
#  partition. Each log block starts with a superblock page: magic "EFSSuper"
#  at data offset +0x08, u16 AGE at +0x06. If every good log block is full and
#  the next block in rotation is bad, the modem dies at mount with
#  "fs_logr.c: Ran out of good blocks in log-rgn" -> endless 900E loop.
#  Cure: erase the OLDEST stale generation(s); newest superblock + its block
#  hold the live filesystem state and must be kept.

function Analyze-EfsLog([string]$rawFile, [int[]]$markedBad) {
    $b = [IO.File]::ReadAllBytes($rawFile)
    $sup = @()   # blocks (relative) that carry a superblock, with age
    $stat = @()
    for ($rb = 0; $rb -lt $EFS_LEN; $rb++) {
        $o = $rb * $RAWBLOCK
        $isSuper = ($b[$o+8] -eq 0x45 -and $b[$o+9] -eq 0x46 -and $b[$o+10] -eq 0x53 -and
                    $b[$o+11] -eq 0x53 -and $b[$o+12] -eq 0x75 -and $b[$o+13] -eq 0x70 -and
                    $b[$o+14] -eq 0x65 -and $b[$o+15] -eq 0x72)
        # free = every byte of every page's first 528 raw bytes is FF (cheap probe)
        $freePages = 0
        for ($pg = 0; $pg -lt $PAGES_PER_BLOCK; $pg++) {
            $po = $o + $pg * $RAWPAGE; $allff = $true
            for ($j = 0; $j -lt 528; $j++) { if ($b[$po+$j] -ne 0xFF) { $allff = $false; break } }
            if ($allff) { $freePages++ }
        }
        $absBlk = $EFS_START + $rb
        # PSCustomObject, NOT hashtable: Sort-Object cannot sort hashtables by
        # key in PowerShell 5.1 (it fails silently and returns garbage order).
        $entry = [pscustomobject]@{ rel = $rb; abs = $absBlk; free = $freePages
                    bad = ($markedBad -contains $absBlk); age = $null }
        if ($isSuper) {
            $entry.age = [BitConverter]::ToUInt16($b, $o+6)
            $sup += ,$entry
        }
        $stat += ,$entry
    }
    if ($sup.Count -eq 0) {
        return @{ verdict = 'NO_SUPERBLOCKS'; super = @(); all = $stat }
    }
    # age is a u16 that wraps: normalize if the observed spread implies a wrap
    $ages = $sup | ForEach-Object { [int]$_.age }
    $mn = ($ages | Measure-Object -Minimum).Minimum
    $mx = ($ages | Measure-Object -Maximum).Maximum
    if (($mx - $mn) -gt 32768) {
        foreach ($s in $sup) { if ($s.age -lt 32768) { $s.age = [int]$s.age + 65536 } }
    }
    $newest = ($sup | Sort-Object age)[-1]
    $stale  = @($sup | Where-Object { $_.age -ne $newest.age } | Sort-Object age)
    $verdict = 'OK'
    if ($stale.Count -gt 0) {
        # Wedged = every superblock-bearing block is 100% full AND there is no
        # fully-erased good block anywhere in the log region to rotate into.
        $regionFirstRel = ($sup | ForEach-Object { $_.rel } | Measure-Object -Minimum).Minimum
        $anyFreeInRegion = @($stat | Where-Object { $null -eq $_.age -and -not $_.bad -and $_.free -eq $PAGES_PER_BLOCK -and $_.rel -ge $regionFirstRel }).Count
        if (($sup | Where-Object { $_.free -gt 0 }).Count -eq 0 -and $anyFreeInRegion -eq 0) {
            $verdict = 'LOG_FULL'
        }
    }
    return @{ verdict = $verdict; super = $sup; newest = $newest; stale = $stale; all = $stat }
}

function Show-EfsAnalysis($an) {
    Head "EFS2 log-region analysis"
    if ($an.verdict -eq 'NO_SUPERBLOCKS') {
        Say "No EFS2 superblocks found - EFS is blank or unreadable." Yellow
        Say "If the device still crash-loops, the modem should fresh-format EFS on boot;"
        Say "IMEI will then need re-writing with the bundled imei_tool. Get expert help first."
        return
    }
    foreach ($s in ($an.super | Sort-Object age)) {
        $tag = if ($s.age -eq $an.newest.age) { ' <== NEWEST (live state, keep!)' } else { ' (stale)' }
        Say ("  block 0x{0:x2}: superblock age {1}, {2}/{3} pages free{4}" -f $s.abs, ($s.age % 65536), $s.free, $PAGES_PER_BLOCK, $tag)
    }
    $badList = @($an.all | Where-Object { $_.bad })
    foreach ($s in $badList) { Say ("  block 0x{0:x2}: MARKED BAD" -f $s.abs) Yellow }
    if ($an.verdict -eq 'LOG_FULL') {
        Say "VERDICT: log region FULL and wedged - this is the 'fs_logr: Ran out of good" Red
        Say "blocks in log-rgn' boot-loop. Run -Mode EfsFix to repair (keeps IMEI/cal)." Red
    } else {
        Say "VERDICT: log region has free space - the log region is NOT the problem." Green
    }
}

# =============================================================================
#  MODES
# =============================================================================

function Mode-Backup([int]$com) {
    New-OutDir
    Head "Raw backup of EFS2 region (blocks 0x14-0x43, with OOB)"
    $f = Join-Path $OUTDIR 'efs2_raw_oob.bin'
    Read-RawBlocks $com $EFS_START $EFS_LEN $f
    Say "EFS2 raw backup -> $f" Green
    Say "(This file can restore the exact current EFS state with:"
    Say "   qwdirect_jmr.exe -p<N> -k10 -fi -ub -uc -z128 -b14 `"$f`" )"
    return $f
}

function Mode-Diagnose([int]$com) {
    Enter-Loader $com
    New-OutDir
    Head "Scanning EFS2 region for marked-bad blocks"
    $bad = Get-MarkedBadBlocks $com $EFS_START $EFS_LEN
    Say ("Marked bad in EFS region: " + $(if ($bad.Count) { ($bad | ForEach-Object { '0x{0:x2}' -f $_ }) -join ', ' } else { 'none' }))
    $raw = Mode-Backup $com
    $an = Analyze-EfsLog $raw $bad
    Show-EfsAnalysis $an
    # SBL sanity: compare first block against donor image
    Head "SBL quick check (block 0 vs donor image)"
    $sblRaw = Join-Path $OUTDIR 'sbl_blk0_raw.bin'
    Read-RawBlocks $com 0 1 $sblRaw
    $donor = [IO.File]::ReadAllBytes((Join-Path $IMAGES '00-0-SBL.oob'))
    $mine  = [IO.File]::ReadAllBytes($sblRaw)
    $donor0 = New-Object byte[] $RAWBLOCK; [Array]::Copy($donor, $donor0, $RAWBLOCK)
    $d = Compare-Bytes $donor0 $mine
    if ($d -eq 0) {
        Say "SBL block 0 is byte-identical to the donor image - boot chain looks flashed/good." Green
        if ($an.verdict -eq 'LOG_FULL') { Say ">> RECOMMENDED NEXT STEP: -Mode EfsFix" Cyan }
    } else {
        Say "SBL block 0 differs from donor image in $d bytes." Yellow
        Say ">> RECOMMENDED NEXT STEP: -Mode FullFlash (then EfsFix if it still 900E-loops)" Cyan
    }
    return $an
}

function Mode-EfsFix([int]$com) {
    Enter-Loader $com
    New-OutDir
    $bad = Get-MarkedBadBlocks $com $EFS_START $EFS_LEN
    $raw = Mode-Backup $com                      # backup FIRST, always
    $an = Analyze-EfsLog $raw $bad
    Show-EfsAnalysis $an
    if ($an.verdict -eq 'NO_SUPERBLOCKS') { Say "Nothing to fix here."; return }
    if ($an.stale.Count -eq 0) {
        Say "Only one superblock generation exists - the log-full repair does not apply." Yellow
        return
    }
    if ($an.verdict -ne 'LOG_FULL' -and -not $EraseAllStale) {
        Say "Log region is not wedged-full; refusing the default repair." Yellow
        Say "(If the device still crash-loops with the fs_logr message, rerun with -EraseAllStale.)"
        return
    }
    $targets = if ($EraseAllStale) { $an.stale } else { ,$an.stale[0] }   # stale[] sorted oldest-first
    Head "EFS log-region repair"
    Say ("Will ERASE stale log block(s): " + (($targets | ForEach-Object { '0x{0:x2} (age {1})' -f $_.abs, ($_.age % 65536) }) -join ', '))
    Say ("Keeping newest generation in block 0x{0:x2} (age {1}) and all data blocks." -f $an.newest.abs, ($an.newest.age % 65536))
    Say "A full raw backup was already written to $raw"
    if (-not (Confirm-Step "Erase the block(s) listed above?")) { Say "Aborted."; return }
    foreach ($t in $targets) {
        Erase-Blocks $com $t.abs 1 | Out-Null
        # verify erased: read back, must be all FF
        $chk = Join-Path $OUTDIR ('erased_blk{0:x2}.bin' -f $t.abs)
        Read-RawBlocks $com $t.abs 1 $chk
        $cb = [IO.File]::ReadAllBytes($chk); $nonff = 0
        foreach ($byte in $cb) { if ($byte -ne 0xFF) { $nonff++; break } }
        if ($nonff) {
            Say ("block 0x{0:x2}: ERASE DID NOT VERIFY (non-FF bytes remain) - possible dying block." -f $t.abs) Red
            Say "Stopping. The device may mark it bad on its own; try rebooting anyway." Red
            break
        }
        Say ("block 0x{0:x2}: erased and verified blank." -f $t.abs) Green
        Remove-Item $chk -Force
    }
    Reboot-AndWatch $com
}

function Mode-FullFlash([int]$com) {
    Enter-Loader $com
    New-OutDir
    # preflight: all images present with sane sizes
    foreach ($e in $FLASH_MAP) {
        $f = Join-Path $IMAGES $e.file
        if (-not (Test-Path $f)) { throw "missing image: $f" }
        if (((Get-Item $f).Length % $RAWBLOCK) -ne 0) { throw "image $($e.file) size is not a multiple of a raw block - wrong file format (need data+OOB 512+16 dumps)" }
    }
    Mode-Backup $com | Out-Null       # EFS safety net even though we don't touch it
    Say ""
    Say "About to flash ALL system partitions from donor images (EFS2 is skipped" Yellow
    Say "and preserved - your IMEI/calibration are NOT touched)." Yellow
    if (-not (Confirm-Step "Flash all partitions now?")) { Say "Aborted."; return }
    foreach ($e in $FLASH_MAP) {
        $f = Join-Path $IMAGES $e.file
        Say ("flashing {0} @ block 0x{1} ..." -f $e.file, $e.blk)
        $out = Invoke-QTool 'qwdirect_jmr.exe' "-p$com -k10 -fi -ub -uc -z128 -b$($e.blk) `"$f`""
        if ($out -match 'error|Error|ERROR') { Say "  WARNING - tool reported an error, output saved." Yellow }
        $out | Out-File (Join-Path $OUTDIR ("flash_" + $e.file + ".log")) -Encoding utf8
    }
    if ($FlashCache) {
        $f = Join-Path $IMAGES '17-0-cache.oob'
        if (Test-Path $f) {
            Say "flashing cache @ 0x5c4 ..."
            Invoke-QTool 'qwdirect_jmr.exe' "-p$com -k10 -fi -ub -uc -z128 -b5c4 `"$f`"" | Out-Null
        }
    } else {
        Say "erasing cache region (rebuilt automatically on boot) ..."
        Erase-Blocks $com $CACHE_START $CACHE_LEN | Out-Null
    }
    # verify SBL raw - the one partition where a single wrong byte = brick
    Head "Verifying SBL (raw, all 10 blocks)"
    $chk = Join-Path $OUTDIR 'sbl_verify.bin'
    Read-RawBlocks $com 0 10 $chk
    $d = Compare-Bytes ([IO.File]::ReadAllBytes((Join-Path $IMAGES '00-0-SBL.oob'))) ([IO.File]::ReadAllBytes($chk))
    if ($d -eq 0) { Say "SBL verified byte-identical to donor image (0 diffs). " Green }
    else {
        Say "SBL VERIFY FAILED: $d differing bytes. DO NOT REBOOT." Red
        Say "The controller config may have reverted - rerun this mode from a fresh EDL." Red
        return
    }
    Reboot-AndWatch $com
}

# LAST RESORT ONLY: full EFS2 wipe. Destroys IMEI + RF calibration on the
# device; the modem fresh-formats an empty filesystem on next boot and the
# IMEI must then be rewritten with imei_tool\ (use the IMEI from the label).
# Only for devices that STILL crash-loop with an EFS crash string after
# EfsFix -EraseAllStale (i.e. the EFS data itself is destroyed).
function Mode-EfsWipe([int]$com) {
    Enter-Loader $com
    New-OutDir
    $raw = Mode-Backup $com            # even a corrupt EFS is worth keeping
    Say ""
    Say "################################################################" Red
    Say "#  FULL EFS2 WIPE - THIS ERASES IMEI AND RF CALIBRATION!       #" Red
    Say "#  Only proceed if:                                            #" Red
    Say "#   * CrashLog showed an EFS/fs_ crash string, AND             #" Red
    Say "#   * EfsFix and EfsFix -EraseAllStale did NOT fix the loop.   #" Red
    Say "#  After the wipe you MUST rewrite the IMEI from the device    #" Red
    Say "#  label using imei_tool\ (write only your OWN device's IMEI). #" Red
    Say "################################################################" Red
    Say "A raw backup of the current (corrupt) EFS was saved to:"
    Say "  $raw"
    # deliberately NOT bypassable with -Yes: this destroys device identity
    $phrase = Read-Host "Type exactly: WIPE MY EFS   to proceed"
    if ($phrase -cne 'WIPE MY EFS') { Say "Aborted - nothing was changed." Yellow; return }
    Head "Erasing EFS2 partition (blocks 0x14-0x43)"
    $out = Erase-Blocks $com $EFS_START $EFS_LEN
    $out | Out-File (Join-Path $OUTDIR 'efs_wipe.log') -Encoding utf8
    Say "EFS2 region erased (marked-bad blocks are skipped automatically)." Green
    Say ""
    Say "After reboot the modem will format a fresh EFS (first boot can take a"
    Say "few minutes and may reboot once on its own). Then:"
    Say "  1. Check the web UI comes up (http://192.168.1.1/)."
    Say "  2. Rewrite your IMEI with imei_tool\ over the diag port."
    Reboot-AndWatch $com
}

# LAST RESORT (alternative to EfsWipe): flash the DONOR EFS image.
# The image is a known-good, working-state EFS2 dump voluntarily donated from
# the reference (revived) device. Flashing it makes the modem mount instantly,
# BUT the device then carries the DONOR's IMEI and RF calibration:
#   * You MUST immediately rewrite YOUR OWN device's IMEI (from its label)
#     with imei_tool\ - operating a device with someone else's IMEI is illegal
#     in most countries, including India.
#   * Donor RF calibration is per-unit; radio performance may be slightly off.
#   * The image embeds the donor chip's bad-block layout (block 0x40 marked
#     bad). On your chip that block will just be treated as bad - harmless.
#     If YOUR chip has bad blocks inside 0x14-0x43 the write may not stick
#     there; check the flash log.
function Mode-EfsRestore([int]$com) {
    $donorEfs = Join-Path $IMAGES '02-0-EFS2-donor.oob'
    if (-not (Test-Path $donorEfs)) {
        Say "This kit copy has no donor EFS image (images\02-0-EFS2-donor.oob). Aborting." Red
        return
    }
    if ((Get-Item $donorEfs).Length -ne ($EFS_LEN * $RAWBLOCK)) {
        Say "Donor EFS image has the wrong size - corrupt kit copy. Aborting." Red
        return
    }
    Enter-Loader $com
    New-OutDir
    $raw = Mode-Backup $com            # keep whatever is there now, always
    Say ""
    Say "################################################################" Red
    Say "#  DONOR EFS FLASH - the device will carry the DONOR's IMEI!   #" Red
    Say "#  Use ONLY if the escalation ladder failed:                   #" Red
    Say "#    EfsFix -> EfsFix -EraseAllStale -> EfsWipe                 #" Red
    Say "#  MANDATORY AFTERWARDS: rewrite YOUR OWN device's IMEI (from  #" Red
    Say "#  its label) using imei_tool\ - do NOT keep the donor IMEI.   #" Red
    Say "################################################################" Red
    Say "Backup of your current EFS: $raw"
    # deliberately NOT bypassable with -Yes: identity-affecting operation
    $phrase = Read-Host "Type exactly: FLASH DONOR EFS   to proceed"
    if ($phrase -cne 'FLASH DONOR EFS') { Say "Aborted - nothing was changed." Yellow; return }
    Head "Flashing donor EFS2 @ block 0x14"
    $out = Invoke-QTool 'qwdirect_jmr.exe' "-p$com -k10 -fi -ub -uc -z128 -b14 `"$donorEfs`""
    $out | Out-File (Join-Path $OUTDIR 'efs_restore.log') -Encoding utf8
    if ($out -match 'error|Error|ERROR') { Say "Tool reported an error - check $OUTDIR\efs_restore.log" Yellow }
    Say "Donor EFS written." Green
    Say ""
    Say ">> AFTER the device boots: rewrite YOUR OWN IMEI with imei_tool\ <<" Red
    Reboot-AndWatch $com
}

function Reboot-AndWatch([int]$com) {
    Head "Rebooting device"
    Invoke-QTool 'qcommand.exe' "-p$com -c `"c 0b`"" | Out-Null
    Say "Reboot sent. Watching USB for up to 2 minutes..."
    $s = Wait-ForState @('NORMAL','CRASH') 120
    switch ($s.State) {
        'NORMAL' { Say "SUCCESS - device is up in normal mode (RNDIS network device present)." Green
                   Say "Open http://192.168.1.1/ (or http://jiofi.local.html) to check status." Green }
        'CRASH'  { Say "Device came back in 900E crash mode." Red
                   Say "Run:  revive.ps1 -Mode CrashLog   to read the crash reason." Red
                   Say "If it is the fs_logr message again, rerun -Mode EfsFix -EraseAllStale" Red }
        default  { Say "Device state after reboot: $($s.State) - check cable/power." Yellow }
    }
}

# =============================================================================
#  900E crash-dump reader (pure PowerShell Sahara memory-debug client)
# =============================================================================
#  NOTE: PS variables are case-insensitive - keep every name here unique!

function Mode-CrashLog([int]$com) {
    New-OutDir
    Head "Reading crash reason from 900E port COM$com (Sahara memory debug)"
    $dumpBase = 0x87C00000L      # SMEM area on MDM9x07 - holds the err_fatal string
    $dumpLen  = 0x200000L
    $sp = New-Object System.IO.Ports.SerialPort "COM$com", 115200, 'None', 8, 'One'
    $sp.ReadTimeout = 8000; $sp.WriteTimeout = 8000; $sp.ReadBufferSize = 1MB
    $sp.Open()
    try {
        function ReadExact([int]$n) {
            $buf = New-Object byte[] $n; $got = 0
            while ($got -lt $n) {
                $r = $sp.Read($buf, $got, $n - $got)
                if ($r -le 0) { throw "short read: $got/$n" }
                $got += $r
            }
            return ,$buf
        }
        $is64 = $false
        $hello = $null
        $sp.ReadTimeout = 3000
        try { $hello = ReadExact 48 } catch { Say "no hello - resumed session, continuing" }
        $sp.ReadTimeout = 8000
        if ($hello) {
            # hello response: cmd=2 len=48 ver=2 min=1 status=0 mode=2 (memory debug)
            $resp = New-Object byte[] 48
            [BitConverter]::GetBytes([uint32]2).CopyTo($resp, 0)
            [BitConverter]::GetBytes([uint32]48).CopyTo($resp, 4)
            [BitConverter]::GetBytes([uint32]2).CopyTo($resp, 8)
            [BitConverter]::GetBytes([uint32]1).CopyTo($resp, 12)
            [BitConverter]::GetBytes([uint32]0).CopyTo($resp, 16)
            [BitConverter]::GetBytes([uint32]2).CopyTo($resp, 20)
            $sp.Write($resp, 0, 48)
            $hdr8 = ReadExact 8
            $pcmd = [BitConverter]::ToUInt32($hdr8, 0)
            $plen = [BitConverter]::ToUInt32($hdr8, 4)
            $null = ReadExact ([int]($plen - 8))
            if ($pcmd -eq 0x11) { $is64 = $true }
            elseif ($pcmd -ne 9) { throw "unexpected Sahara cmd $pcmd - replug device and retry" }
        }
        function MemRead([uint64]$rdA, [uint64]$rdN) {
            if ($is64) {
                $pk = New-Object byte[] 24
                [BitConverter]::GetBytes([uint32]0x12).CopyTo($pk, 0)
                [BitConverter]::GetBytes([uint32]24).CopyTo($pk, 4)
                [BitConverter]::GetBytes([uint64]$rdA).CopyTo($pk, 8)
                [BitConverter]::GetBytes([uint64]$rdN).CopyTo($pk, 16)
            } else {
                $pk = New-Object byte[] 16
                [BitConverter]::GetBytes([uint32]0x0A).CopyTo($pk, 0)
                [BitConverter]::GetBytes([uint32]16).CopyTo($pk, 4)
                [BitConverter]::GetBytes([uint32]$rdA).CopyTo($pk, 8)
                [BitConverter]::GetBytes([uint32]$rdN).CopyTo($pk, 12)
            }
            $sp.Write($pk, 0, $pk.Length)
            return ReadExact ([int]$rdN)
        }
        $ms = New-Object IO.MemoryStream
        $cursor = [uint64]$dumpBase; $left = [uint64]$dumpLen
        while ($left -gt 0) {
            $take = [Math]::Min([uint64]65536, $left)
            $dd = MemRead $cursor $take
            $ms.Write($dd, 0, $dd.Length)
            $cursor += $take; $left -= $take
        }
        $dumpFile = Join-Path $OUTDIR 'smem_dump.bin'
        [IO.File]::WriteAllBytes($dumpFile, $ms.ToArray())
        Say "SMEM dump saved -> $dumpFile"
        # string scan for crash markers
        $bb = $ms.ToArray(); $runStart = -1; $found = @()
        for ($i = 0; $i -lt $bb.Length; $i++) {
            $c = $bb[$i]
            if ($c -ge 32 -and $c -le 126) { if ($runStart -lt 0) { $runStart = $i } }
            else {
                if ($runStart -ge 0 -and ($i - $runStart) -ge 8) {
                    $str = [Text.Encoding]::ASCII.GetString($bb, $runStart, $i - $runStart)
                    if ($str -match '(?i)err|fatal|assert|\.c:|crash|panic|abort|exception') { $found += $str }
                }
                $runStart = -1
            }
        }
        Head "Crash strings found"
        if ($found.Count -eq 0) {
            Say "No crash string in this window. The crash may be pre-SMEM-init (early boot)." Yellow
        }
        $isLogr = $false
        foreach ($str in $found) {
            Say "  $str" Yellow
            if ($str -match 'logr\.c.*Ran out of good blocks') { $isLogr = $true }
        }
        if ($isLogr) {
            Say ""
            Say ">> This is the EFS2 log-region wedge. THE FIX: put the device in EDL (9008)" Cyan
            Say ">> mode (test point / boot-timing - see README) and run: -Mode EfsFix" Cyan
        }
    } finally { $sp.Close() }
}

# =============================================================================
#  MAIN
# =============================================================================

Say ""
Say "JioFi M2 Ver-2 revival kit  (PEG_M2_B37 / MDM9x07 / Toshiba 512MiB NAND)" Cyan
Say "-------------------------------------------------------------------------"

# kit sanity
foreach ($need in @('qtool\qdload.exe','qtool\qcommand.exe','qtool\qrflash.exe',
                    'qtool\qwdirect_jmr.exe','qtool\qbadblock.exe','qtool\chipset.cfg',
                    'qtool\loaders\NPRG9x45p.bin','qtool\loaders\ENPRG9x45p.bin')) {
    if (-not (Test-Path (Join-Path $KIT $need))) {
        throw ("kit incomplete: missing $need`n`n" +
               "It looks like you're running from the source repo. The flash tools and`n" +
               "firmware are in the Release download, not in git. Get`n" +
               "JioFi_M2_Revival_Kit_v1.0.zip from the repo's Releases page, extract it,`n" +
               "and run revive.ps1 from inside the extracted folder.")
    }
}

$dev = Get-DeviceState
if ($Port) {
    $pnum = $Port -replace '\D',''
    if (-not $pnum) { throw "-Port expects e.g. COM3 or 3 (got '$Port')" }
    if ($dev.State -eq 'NONE') { $dev.State = 'EDL' }   # trust the user's port
    $dev.Com = [int]$pnum
    Say "COM port forced to COM$($dev.Com) by -Port." Yellow
}
Say "Detected device state: $($dev.State) $(if ($dev.Com) { "(COM$($dev.Com))" }) $($dev.Name)"

switch ($dev.State) {
    'NONE' {
        Say ""
        Say "No JioFi/Qualcomm device found on USB." Yellow
        Say " * Check cable (use the original / a data cable, not charge-only)."
        Say " * If the device is fully dead it should enumerate as 'QDLoader 9008'."
        Say " * If nothing appears at all, try holding WPS while inserting the battery,"
        Say "   or use the EDL test point (see README)."
        exit 1
    }
    'EDL_BADDRIVER' {
        Say ""
        Say "9008 port found but the driver is BROKEN (likely code 52, unsigned driver)." Red
        Say "Install a properly SIGNED Qualcomm HS-USB QDLoader 9008 driver (qcser)." Red
        Say "With Secure Boot ON, test-signed drivers will not load." Red
        exit 1
    }
    'NORMAL' {
        if ($Mode -in @('Auto','Diagnose')) {
            Say ""
            Say "Device appears HEALTHY (normal RNDIS boot). Nothing to revive." Green
            Say "Web UI: http://192.168.1.1/  (IMSI/ICCID blank = no SIM inserted)"
            exit 0
        }
        Say "Device is in NORMAL mode - mode '$Mode' needs EDL (9008). Aborting." Yellow
        exit 1
    }
    'CRASH' {
        if ($Mode -in @('Auto','CrashLog')) { Mode-CrashLog $dev.Com; exit 0 }
        Say "Device is in 900E crash mode - mode '$Mode' needs EDL (9008)." Yellow
        Say "Put the device into EDL first (see README), then rerun."
        exit 1
    }
    'EDL' {
        switch ($Mode) {
            'Auto'      { Mode-Diagnose $dev.Com }
            'Diagnose'  { Mode-Diagnose $dev.Com }
            'EfsFix'    { Mode-EfsFix   $dev.Com }
            'EfsWipe'   { Mode-EfsWipe  $dev.Com }
            'EfsRestore'{ Mode-EfsRestore $dev.Com }
            'FullFlash' { Mode-FullFlash $dev.Com }
            'Backup'    { Enter-Loader $dev.Com; Mode-Backup $dev.Com }
            'CrashLog'  { Say "Device is in EDL, not 900E - CrashLog needs the 900E port." Yellow }
        }
    }
}
Say ""
Say "Done. Logs/artifacts (if any): $OUTDIR"
