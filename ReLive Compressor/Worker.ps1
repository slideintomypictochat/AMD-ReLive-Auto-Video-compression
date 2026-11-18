# ReLive Compressor - worker
# Scans the recordings folder and compresses pending clips to AV1 (AMD AMF), one at a time.
#   -ScanOnly  : just count pending files and write status.json
#   -Recover   : only clean up after an interrupted run (.part / .old files)
#   -Files     : JSON file listing the clips to compress (picked on the Compress page or right-clicked in Explorer)
param(
    [switch]$ScanOnly,
    [switch]$Recover,
    [int]$MaxFiles = 0,   # 0 = no limit
    [string]$Files
)

$ErrorActionPreference = 'Stop'
$AppDir       = $PSScriptRoot
$SettingsPath = Join-Path $AppDir 'settings.json'
$StatusPath   = Join-Path $AppDir 'status.json'
$LogPath      = Join-Path $AppDir 'compress-log.csv'
$CachePath    = Join-Path $AppDir 'scan-cache.json'
$StopFlag     = Join-Path $AppDir 'stop.flag'
$PauseFlag    = Join-Path $AppDir 'pause.flag'

$S = Get-Content $SettingsPath -Raw | ConvertFrom-Json
$FFmpeg = $S.FFmpegPath
if (-not (Test-Path $FFmpeg)) { $FFmpeg = Join-Path $AppDir 'ffmpeg.exe' }

# ---------- helpers ----------

function Write-Status([hashtable]$h) {
    $h.Updated = (Get-Date).ToString('s')
    $h.WorkerPid = $PID
    $tmp = "$StatusPath.tmp"
    ($h | ConvertTo-Json -Compress) | Set-Content -Path $tmp -Encoding UTF8
    try { Move-Item -Force $tmp $StatusPath } catch { }   # tray may be reading it; next update wins
}

# Runs ffmpeg and returns its stderr text (PowerShell 5.1 turns native stderr into errors otherwise)
function Invoke-FFmpegText([string]$ffArgs) {
    $psi = New-Object Diagnostics.ProcessStartInfo $FFmpeg, $ffArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $null = $outTask.Result
    $err
}

# Reason codes behind the plain-language messages in the window (MainWindow.ps1 $ReasonText):
#   DISK_FULL, IN_USE, ENCODER, DAMAGED, MOVE_FOLDER, RECYCLE_TOO_BIG, SMALL, ALREADY, OTHER
function Get-FailReason([string]$text) {
    if ($text -match 'No space left|not enough space|disk is full') { 'DISK_FULL' }
    elseif ($text -match 'moov atom not found|Invalid data found|Duration mismatch|corrupt|truncat|Error while decoding|could not find codec parameters|End of file') { 'DAMAGED' }
    elseif ($text -match 'AMF|amf|encoder|Output codec') { 'ENCODER' }
    else { 'OTHER' }
}

# logs from 1.5 and older have no Reason column; Export-Csv -Append would drop it, so add it once
function Update-LogSchema {
    if (-not (Test-Path $LogPath)) { return }
    $header = Get-Content $LogPath -TotalCount 1
    if ($header -match '"Reason"') { return }
    $rows = @(Import-Csv $LogPath)
    if (-not $rows.Count) { Remove-Item $LogPath -Force; return }
    $rows | Select-Object *, @{ n = 'Reason'; e = { '' } } | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
}

function Write-Log($mode, $file, $codec, $origBytes, $newBytes, $seconds, $result, $note, $reason = '') {
    $row = [pscustomobject]@{
        Time    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Mode    = $mode
        File    = $file
        Codec   = $codec
        OrigMB  = [math]::Round($origBytes / 1MB, 1)
        NewMB   = if ($newBytes) { [math]::Round($newBytes / 1MB, 1) } else { '' }
        SavedPct = if ($newBytes) { [math]::Round(100 * (1 - $newBytes / $origBytes), 1) } else { '' }
        Seconds = [math]::Round($seconds, 0)
        Result  = $result
        Note    = $note
        Reason  = $reason
    }
    $row | Export-Csv -Path $LogPath -Append -NoTypeInformation -Encoding UTF8
}

function Get-Log {
    if (Test-Path $LogPath) { @(Import-Csv $LogPath) } else { @() }
}

# written into every file we produce, so a compressed file is never compressed again (HEVC outputs look like recordings)
$Tag = 'Compressed by ReLive Compressor'

# Reads codec / duration / audio presence / our tag from "ffmpeg -i" (no ffprobe available)
function Get-MediaInfo([string]$path) {
    $text = Invoke-FFmpegText "-hide_banner -nostdin -i `"$path`""
    $info = [ordered]@{ Codec = $null; Duration = $null; HasAudio = $false; Tagged = $text.Contains($Tag) }
    if ($text -match 'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)') {
        $info.Duration = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($text -match 'Stream #\S+.*?: Video: (\w+)') { $info.Codec = $Matches[1] }
    $info.HasAudio = $text -match 'Stream #\S+.*?: Audio:'
    [pscustomobject]$info
}

# False while something (ReLive) still has the file open for writing; readers like the Adrenalin gallery are fine
function Test-FileFree([string]$path) {
    try { $fs = [IO.File]::Open($path, 'Open', 'Read', 'Read'); $fs.Close(); $true } catch { $false }
}

function Get-FreeBytes([string]$path) {
    $root = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $path).ProviderPath)
    (New-Object IO.DriveInfo $root).AvailableFreeSpace
}

function Get-RelativePath([string]$full) {
    $base = $S.RecordingsFolder.TrimEnd('\') + '\'
    if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($base.Length) }
    # a file added from elsewhere (right-click / drag and drop): keep its folder name
    Join-Path (Split-Path (Split-Path $full) -Leaf) (Split-Path $full -Leaf)
}

# One frame from the original and the same frame from the compressed copy, for the before/after viewer.
# Same naming as Get-ComparePath in MainWindow.ps1. Keeps the newest 20 pairs.
function Get-CompareKey([string]$path) {
    $md5 = [Security.Cryptography.MD5]::Create()
    (($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
}
function Save-CompareFrames([string]$original, [string]$compressed, [double]$duration) {
    $dir = Join-Path $AppDir 'compare'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $key = Get-CompareKey $original
    $at = [math]::Round([math]::Min(8, [math]::Max(0, $duration / 2)), 2).ToString([Globalization.CultureInfo]::InvariantCulture)
    foreach ($pair in @(@($original, 'a'), @($compressed, 'b'))) {
        $null = Invoke-FFmpegText "-hide_banner -nostdin -loglevel error -ss $at -i `"$($pair[0])`" -frames:v 1 -q:v 1 -y `"$(Join-Path $dir "$key-$($pair[1]).jpg")`""
    }
    Get-ChildItem -LiteralPath $dir -Filter '*-a.jpg' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName, ($_.FullName -replace '-a\.jpg$', '-b.jpg') -Force -ErrorAction SilentlyContinue
    }
}

# Largest file the Recycle Bin on this drive accepts, in bytes (0 = it can't take files at all).
# Windows deletes bigger files for good, so those originals are kept instead.
function Get-RecycleLimit([string]$path) {
    try {
        $letter = ([IO.Path]::GetPathRoot($path)).TrimEnd('\')
        if ($letter -notmatch '^[A-Za-z]:$') { return 0 }        # network share: no Recycle Bin
        $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$letter'" -ErrorAction Stop
        $guid = [regex]::Match($vol.DeviceID, '\{[0-9A-Fa-f-]+\}').Value
        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$guid"
        $cfg = Get-ItemProperty $key -ErrorAction SilentlyContinue
        if ($cfg -and $cfg.NukeOnDelete -eq 1) { return 0 }
        if ($cfg -and $cfg.MaxCapacity) { return [double]$cfg.MaxCapacity * 1MB }
        [double]$vol.Capacity * 0.05                                # Windows' default size
    }
    catch { 0 }
}

# Undo/finish anything an interrupted run left behind
function Invoke-Recover {
    # folders of files added from outside the recordings folder (right-click / drag and drop)
    $extraList = Join-Path $AppDir 'extra-dirs.txt'
    $extra = if (Test-Path $extraList) { @(Get-Content $extraList | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique) } else { @() }
    $dirs = @()
    if (Test-Path $S.RecordingsFolder) { $dirs += @{ Path = $S.RecordingsFolder; Recurse = $true } }
    foreach ($d in $extra) { $dirs += @{ Path = $d; Recurse = $false } }
    foreach ($d in $dirs) {
        Get-ChildItem -LiteralPath $d.Path -Recurse:$d.Recurse -File -Filter '*.mp4.old' -ErrorAction SilentlyContinue | ForEach-Object {
            $final = $_.FullName.Substring(0, $_.FullName.Length - 4)
            if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $_.FullName -Force }   # swap finished, drop old copy
            else { Rename-Item -LiteralPath $_.FullName -NewName (Split-Path $final -Leaf) }    # swap not finished, restore original
        }
    }
    if ($S.TestFolder -and (Test-Path $S.TestFolder)) { $dirs += @{ Path = $S.TestFolder; Recurse = $true } }
    foreach ($d in $dirs) {
        Get-ChildItem -LiteralPath $d.Path -Recurse:$d.Recurse -File -Filter '*.mp4.part' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $extraList -ErrorAction SilentlyContinue
}

# Returns pending files (FileInfo + codec). Uses a cache keyed on size+mtime so rescans are fast.
function Get-Pending {
    $cache = @{}
    if (Test-Path $CachePath) {
        (Get-Content $CachePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cache[$_.Name] = $_.Value }
    }
    $log = Get-Log
    $failed = @{}; $tested = @{}
    foreach ($r in $log) {
        if ($r.Result -eq 'FAILED' -or $r.Result -eq 'KEPT') { $failed[$r.File] = $true }
        if ($r.Result -eq 'TEST-OK') { $tested[$r.File] = $true }
    }
    $cutoff = (Get-Date).AddMinutes(-10)
    $pending = New-Object System.Collections.Generic.List[object]
    $newCache = @{}
    foreach ($f in Get-ChildItem -LiteralPath $S.RecordingsFolder -Recurse -File -Filter '*.mp4' | Sort-Object LastWriteTime) {
        if ($f.LastWriteTime -gt $cutoff) { continue }                      # may still be recording
        $key = $f.FullName
        $stamp = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
        $c = if ($cache.ContainsKey($key)) { $cache[$key] } else { $null }
        if ($c -and $c.Stamp -eq $stamp) {
            $codec = $c.Codec
            $done = if ($null -ne $c.Done) { [bool]$c.Done } else { $codec -eq 'av1' }   # caches from 1.1 had no Done flag
        }
        else {
            $mi = Get-MediaInfo $key
            $codec = $mi.Codec
            $done = $mi.Tagged -or $codec -eq 'av1'
        }
        $newCache[$key] = @{ Stamp = $stamp; Codec = $codec; Done = $done }
        if (-not $codec -or $done) { continue }
        if ($failed.ContainsKey($key)) { continue }
        if ($S.Mode -eq 'Test' -and $tested.ContainsKey($key)) { continue }
        $wasTested = $tested.ContainsKey($key)
        if ($wasTested) { $script:PendingTested++ }   # has a test copy, original still uncompressed
        $pending.Add([pscustomobject]@{ File = $f; Codec = $codec; Tested = $wasTested })
    }
    ($newCache | ConvertTo-Json -Compress) | Set-Content $CachePath -Encoding UTF8
    , $pending
}

# One still frame per game folder (from its newest clip) for the Library page.
# Same naming as Get-ThumbPath in MainWindow.ps1.
function Update-Thumbnails {
    $thumbDir = Join-Path $AppDir 'thumbs'
    New-Item -ItemType Directory -Force $thumbDir | Out-Null
    $base = $S.RecordingsFolder.TrimEnd('\')
    $cutoff = (Get-Date).AddMinutes(-10)
    $newest = Get-ChildItem -LiteralPath $S.RecordingsFolder -Recurse -File -Filter '*.mp4' |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Group-Object DirectoryName |
        ForEach-Object { $_.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    foreach ($f in $newest) {
        $rel = if ($f.DirectoryName.Length -gt $base.Length) { $f.DirectoryName.Substring($base.Length + 1) } else { '_root' }
        $thumb = Join-Path $thumbDir (($rel -replace '[\\/:*?"<>|]', '_') + '.jpg')
        if (Test-Path -LiteralPath $thumb) { continue }
        foreach ($at in 8, 0) {   # 8 s in skips fade-ins; very short clips fall back to the first frame
            $null = Invoke-FFmpegText "-hide_banner -nostdin -loglevel error -ss $at -i `"$($f.FullName)`" -frames:v 1 -vf scale=400:-2 -q:v 4 -y `"$thumb`""
            if (Test-Path -LiteralPath $thumb) { break }
        }
    }
}

# Test mode: newest clip from different game folders, so the sample is varied
function Select-TestSet($pending) {
    $pending | Group-Object { $_.File.DirectoryName } |
        ForEach-Object { $_.Group | Sort-Object { $_.File.LastWriteTime } -Descending | Select-Object -First 1 } |
        Sort-Object { $_.File.LastWriteTime } -Descending |
        Select-Object -First ([int]$S.TestCount)
}

# Runs ffmpeg, streaming -progress into status.json. Returns exit code (or -1 if stopped).
function Invoke-Encode([string]$in, [string]$out, [double]$duration, [double]$targetKbps, [bool]$hwDecode, [hashtable]$status) {
    $hw = if ($hwDecode) { '-hwaccel d3d11va ' } else { '' }
    $b = [int]$targetKbps; $max = [int]($targetKbps * 1.6)
    $tagHevc = if ($Encoder.Codec -eq 'hevc') { '-tag:v hvc1 ' } else { '' }   # hvc1 plays in Windows Photos / QuickTime
    # Peak-constrained VBR: AMF's quality-based modes (qvbr/hqvbr) ignore the bitrate and swing from 3 to 50 Mbps
    $ffArgs = "-hide_banner -nostdin -nostats -loglevel error -y $hw-i `"$in`" -map 0:v:0 -map 0:a? " +
            "-c:v $($Encoder.Name) -usage transcoding -quality $($S.Preset) -rc vbr_peak -b:v ${b}k -maxrate ${max}k -bufsize $($max * 2)k $tagHevc" +
            "-c:a copy -map_metadata 0 -metadata comment=`"$Tag`" -movflags +faststart -progress pipe:1 -f mp4 `"$out`""
    $psi = New-Object Diagnostics.ProcessStartInfo $FFmpeg, $ffArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $status.FfmpegPid = $p.Id
    $last = [DateTime]::MinValue
    $inBytes = (Get-Item -LiteralPath $in).Length
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        if ($line -match '^out_time_us=(\d+)' -and $duration -gt 0) {
            $status.Percent = [math]::Min(99.9, [math]::Round(([double]$Matches[1] / 1e6) / $duration * 100, 1))
        }
        # time left for the whole queue: ffmpeg's speed (x realtime) turned into input bytes per second
        elseif ($line -match '^speed=\s*([\d.]+)x' -and $duration -gt 0) {
            $bps = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) * $inBytes / $duration
            if ($bps -gt 0) {
                $script:Bps = if ($script:Bps) { 0.8 * $script:Bps + 0.2 * $bps } else { $bps }   # smoothed
                $left = (1 - $status.Percent / 100) * $inBytes + $script:BytesAfter
                $status.EtaSeconds = [int]($left / $script:Bps)
            }
        }
        if (((Get-Date) - $last).TotalSeconds -ge 2) {
            Write-Status $status; $last = Get-Date
            if (Test-Path $StopFlag) { try { $p.Kill() } catch {}; $p.WaitForExit(); return -1 }
        }
    }
    $p.WaitForExit()
    $script:LastFfmpegError = $errTask.Result.Trim()
    $p.ExitCode
}

# ---------- main ----------

$mutex = New-Object Threading.Mutex($false, 'Local\ReLiveCompressorWorker')
if (-not $mutex.WaitOne(0)) { exit 0 }    # another worker is already running
try {
    Remove-Item $StopFlag -ErrorAction SilentlyContinue
    Invoke-Recover
    if ($Recover) { exit 0 }

    try { Update-LogSchema } catch { }
    $script:PendingTested = 0
    $pending = Get-Pending
    try { Update-Thumbnails } catch { }   # cosmetic only, never blocks compression
    if ($Files) {
        # exactly the clips that were picked, oldest first; also ones that failed before (a retry) and ones outside the recordings folder
        $byPath = @{}
        foreach ($item in $pending) { $byPath[$item.File.FullName.ToLowerInvariant()] = $item }
        $picked = Get-Content -LiteralPath $Files -Raw | ConvertFrom-Json
        $queue = foreach ($path in $picked) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $hit = $byPath[([string]$path).ToLowerInvariant()]
            if ($hit) { $hit; continue }
            $fi = Get-Item -LiteralPath $path
            $mi = Get-MediaInfo $fi.FullName
            if ($mi.Tagged -or $mi.Codec -eq 'av1') {
                Write-Log $S.Mode $fi.FullName $mi.Codec $fi.Length $null 0 'SKIPPED' 'Already compressed' 'ALREADY'; continue
            }
            [pscustomobject]@{ File = $fi; Codec = $mi.Codec; Tested = $false }
        }
        $queue = @($queue | Sort-Object { $_.File.LastWriteTime })
    }
    elseif ($S.Mode -eq 'Test') { $queue = @(Select-TestSet $pending) } else { $queue = $pending.ToArray() }
    if ($MaxFiles -gt 0) { $queue = @($queue | Select-Object -First $MaxFiles) }
    $pendingBytes = ($pending | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
    $status = @{
        State = 'scanned'; Mode = $S.Mode; File = $null; Percent = 0; FfmpegPid = $null
        Pending = $pending.Count; PendingGB = [math]::Round($pendingBytes / 1GB, 1); PendingTested = $script:PendingTested
        QueueTotal = $queue.Count; QueueDone = 0; Succeeded = 0; SavedGB = 0; LastScan = (Get-Date).ToString('s')
    }
    Write-Status $status

    # best hardware encoder this AMD GPU has: AV1 on RX 7000 and newer, HEVC on RX 400 - RX 6000.
    # HEVC needs ~25% more bitrate for the same quality on older cards. Without either, every file would fail, so stop here.
    $Encoder = $null
    foreach ($e in @(@{ Name = 'av1_amf'; Codec = 'av1'; Factor = 1.0; Cap = 0.5 }, @{ Name = 'hevc_amf'; Codec = 'hevc'; Factor = 1.25; Cap = 0.6 })) {
        $probe = [Diagnostics.Process]::Start((New-Object Diagnostics.ProcessStartInfo $FFmpeg, "-hide_banner -nostdin -loglevel error -f lavfi -i color=black:s=640x360:r=30 -frames:v 3 -c:v $($e.Name) -f null -" -Property @{ UseShellExecute = $false; CreateNoWindow = $true }))
        if (-not $probe.WaitForExit(30000)) { $probe.Kill(); $probe.WaitForExit() }
        if ($probe.ExitCode -eq 0) { $Encoder = $e; break }
    }
    if (-not $Encoder) { $status.State = 'noencoder'; Write-Status $status; exit 0 }
    $status.Encoder = $Encoder.Codec

    if ($ScanOnly -or $queue.Count -eq 0) { $status.State = 'idle'; Write-Status $status; exit 0 }

    # Move mode: if the destination drive is gone (unplugged USB drive), every file would fail the same way
    if ($S.Mode -eq 'Move') {
        $root = [IO.Path]::GetPathRoot([string]$S.MoveFolder)
        if (-not $root -or -not (Test-Path -LiteralPath $root)) {
            Write-Log $S.Mode $queue[0].File.FullName $queue[0].Codec $queue[0].File.Length $null 0 'SKIPPED' "Move folder not available: $($S.MoveFolder)" 'MOVE_FOLDER'
            $status.State = 'idle'; Write-Status $status; exit 0
        }
    }

    $recycle = $S.Mode -eq 'Replace' -and $S.RecycleOriginals
    if ($recycle) { Add-Type -AssemblyName Microsoft.VisualBasic }
    $script:BytesAfter = ($queue | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
    $script:Bps = 0
    $saved = 0
    foreach ($item in $queue) {
        while ((Test-Path $PauseFlag) -and -not (Test-Path $StopFlag)) { Start-Sleep -Seconds 2 }
        if (Test-Path $StopFlag) { break }
        $f = $item.File
        $script:BytesAfter -= $f.Length
        if (-not (Test-Path -LiteralPath $f.FullName)) { continue }
        if (-not (Test-FileFree $f.FullName)) {
            Write-Log $S.Mode $f.FullName $item.Codec $f.Length $null 0 'SKIPPED' 'Still being written - will retry' 'IN_USE'
            continue
        }

        switch ($S.Mode) {
            'Test'  { $outDir = Join-Path $S.TestFolder (Split-Path (Get-RelativePath $f.FullName)) }
            default { $outDir = $f.DirectoryName }
        }
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $final = Join-Path $outDir $f.Name
        $part = "$final.part"
        $base = $S.RecordingsFolder.TrimEnd('\') + '\'
        if (-not $f.FullName.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
            Add-Content (Join-Path $AppDir 'extra-dirs.txt') $outDir   # so an interrupted run can be cleaned up there too
        }

        if ((Get-FreeBytes $outDir) -lt ($f.Length * 0.5 + 2GB)) {
            Write-Log $S.Mode $f.FullName $item.Codec $f.Length $null 0 'SKIPPED' "Not enough free disk space on $([IO.Path]::GetPathRoot($outDir)) (needs $([math]::Ceiling(($f.Length * 0.5 + 2GB - (Get-FreeBytes $outDir)) / 1GB * 10) / 10) GB more)" 'DISK_FULL'
            continue
        }

        $status.State = 'running'; $status.File = $f.FullName; $status.Percent = 0
        Write-Status $status
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $src = Get-MediaInfo $f.FullName
        if (-not $src.Codec -or -not ($src.Duration -gt 0)) {
            Write-Log $S.Mode $f.FullName $item.Codec $f.Length $null 0 'FAILED' 'Could not read the recording (no video stream or length)' 'DAMAGED'
            $status.QueueDone++; continue
        }

        # target bitrate from settings, but never more than half of what the original uses (60% for HEVC)
        $srcKbps = if ($src.Duration -gt 0) { $f.Length * 8 / 1000 / $src.Duration } else { 1e9 }
        $targetKbps = [math]::Min([double]$S.TargetMbps * 1000 * $Encoder.Factor, $srcKbps * $Encoder.Cap)

        $code = Invoke-Encode $f.FullName $part $src.Duration $targetKbps $true $status
        if ($code -gt 0) { $code = Invoke-Encode $f.FullName $part $src.Duration $targetKbps $false $status }   # retry with CPU decode
        if ($code -eq -1) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue; break }

        # ---- verify before touching the original ----
        $problem = $null
        if ($code -ne 0) { $problem = "ffmpeg exit $code $script:LastFfmpegError" }
        elseif (-not (Test-Path -LiteralPath $part)) { $problem = 'No output file' }
        else {
            $out = Get-MediaInfo $part
            $outLen = (Get-Item -LiteralPath $part).Length
            if ($out.Codec -ne $Encoder.Codec) { $problem = "Output codec is '$($out.Codec)'" }
            elseif ([math]::Abs($out.Duration - $src.Duration) -gt 1) { $problem = "Duration mismatch $($out.Duration) vs $($src.Duration)" }
            elseif ($src.HasAudio -and -not $out.HasAudio) { $problem = 'Audio missing in output' }
            elseif ($outLen -ge $f.Length) { $problem = 'Output not smaller than original' }
        }
        if (-not $problem -and $recycle -and $f.Length -gt (Get-RecycleLimit $f.FullName)) {
            $problem = 'Too big for the Recycle Bin, original kept'
        }
        if ($problem) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            $result = 'FAILED'; $reason = Get-FailReason $problem
            if ($problem -eq 'Output not smaller than original') { $result = 'KEPT'; $reason = 'SMALL' }
            if ($problem -like 'Too big for the Recycle Bin*') { $result = 'KEPT'; $reason = 'RECYCLE_TOO_BIG' }
            Write-Log $S.Mode $f.FullName $item.Codec $f.Length $null $sw.Elapsed.TotalSeconds $result $problem $reason
            $status.QueueDone++; continue
        }

        # before/after frames, taken while the original still exists
        try { Save-CompareFrames $f.FullName $part $src.Duration } catch { }

        # ---- swap in the compressed file ----
        $created = $f.CreationTime; $modified = $f.LastWriteTime
        $reason = 'IN_USE'
        try {
            switch ($S.Mode) {
                'Test' {
                    Move-Item -LiteralPath $part -Destination $final -Force
                    $result = 'TEST-OK'
                }
                'Move' {
                    $dest = Join-Path $S.MoveFolder (Get-RelativePath $f.FullName)
                    $reason = 'MOVE_FOLDER'
                    New-Item -ItemType Directory -Force -Path (Split-Path $dest) -ErrorAction Stop | Out-Null
                    $reason = 'IN_USE'
                    Move-Item -LiteralPath $f.FullName -Destination $dest -Force
                    Move-Item -LiteralPath $part -Destination $final -Force
                    $result = 'OK-MOVED'
                }
                default {
                    if ($recycle) {
                        # original goes to the Recycle Bin under its own name, so restoring it puts it back as it was
                        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
                        Move-Item -LiteralPath $part -Destination $final -Force
                        $result = 'OK'
                        break
                    }
                    $old = "$($f.FullName).old"
                    Rename-Item -LiteralPath $f.FullName -NewName (Split-Path $old -Leaf)
                    Move-Item -LiteralPath $part -Destination $final -Force
                    Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue   # leftover .old is cleaned up next run
                    $result = 'OK'
                }
            }
        }
        catch {
            # original is open in another program (e.g. a video player): leave it as it was and retry next run
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            $why = if ($reason -eq 'MOVE_FOLDER') { "Move folder not available: $($S.MoveFolder)" } else { "In use, will retry: $($_.Exception.Message)" }
            Write-Log $S.Mode $f.FullName $item.Codec $f.Length $null $sw.Elapsed.TotalSeconds 'SKIPPED' $why $reason
            continue
        }
        $newItem = Get-Item -LiteralPath $final
        $newItem.CreationTime = $created; $newItem.LastWriteTime = $modified
        Write-Log $S.Mode $f.FullName $item.Codec $f.Length $newItem.Length $sw.Elapsed.TotalSeconds $result $(if ($recycle) { 'Original in Recycle Bin' } else { '' })
        $status.QueueDone++; $status.Succeeded++
        if ($S.Mode -ne 'Test') {
            $saved += $f.Length - $newItem.Length
            $status.SavedGB = [math]::Round($saved / 1GB, 2)
            if ($item.Tested) { $status.PendingTested = [math]::Max(0, $status.PendingTested - 1) }
        }
        # a test copy also takes the file off Test mode's waiting list (the next scan skips it)
        $status.Pending = [math]::Max(0, $status.Pending - 1)
        $status.PendingGB = [math]::Max(0, [math]::Round($status.PendingGB - $f.Length / 1GB, 1))
    }
    $status.State = 'idle'; $status.File = $null; $status.FfmpegPid = $null; $status.Percent = 0; $status.EtaSeconds = $null
    Write-Status $status
}
finally {
    $mutex.ReleaseMutex()
}
