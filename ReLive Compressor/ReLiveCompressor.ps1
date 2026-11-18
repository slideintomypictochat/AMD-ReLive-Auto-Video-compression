# ReLive Compressor - tray app
# Lives in the notification area. Starts Worker.ps1 when you're away from the PC (if automatic mode is on),
# pauses it the moment you come back, and opens the main window (MainWindow.ps1) from the icon.
param(
    [switch]$Show     # open the main window (Start menu shortcut); without it the app starts quietly in the tray
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RlcNative {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    public static double IdleSeconds() {
        LASTINPUTINFO i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i);
        GetLastInputInfo(ref i);
        return unchecked((uint)Environment.TickCount - i.dwTime) / 1000.0;
    }
    // 2 = busy/fullscreen app, 3 = D3D fullscreen (game), 4 = presentation mode
    public static bool FullscreenAppRunning() {
        int s; if (SHQueryUserNotificationState(out s) != 0) return false;
        return s == 2 || s == 3 || s == 4;
    }
    public static void Suspend(IntPtr h) { NtSuspendProcess(h); }
    public static void Resume(IntPtr h) { NtResumeProcess(h); }
}
'@

$AppDir       = $PSScriptRoot
$SettingsPath = Join-Path $AppDir 'settings.json'
$StatusPath   = Join-Path $AppDir 'status.json'
$PauseFlag    = Join-Path $AppDir 'pause.flag'
$ShowFlag     = Join-Path $AppDir 'show.flag'
$WorkerPath   = Join-Path $AppDir 'Worker.ps1'
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) 'ReLive Compressor.lnk'
$AppName      = 'ReLive Compressor'
$IconPath     = Join-Path $AppDir 'ReLiveCompressor.ico'
# runs the scripts in its own process, so Windows shows "ReLive Compressor" rather than PowerShell
$HostExe      = Join-Path $AppDir 'ReLiveCompressor.exe'
$SelectionPath = Join-Path $AppDir 'selection.json'   # clips picked on the Compress page, for Worker.ps1 -Files
$IncomingPath = Join-Path $AppDir 'incoming.txt'      # files added with Explorer's "Compress with ReLive Compressor"
# new versions are published as GitHub releases; each release carries update.json (see Build\Publish-Update.ps1)
$UpdateRepo   = 'slideintomypictochat/AMD-ReLive-Auto-Video-compression'
$AppVersion   = if (Test-Path $HostExe) { (Get-Item $HostExe).VersionInfo.FileVersion -replace '^(\d+\.\d+\.\d+)\.\d+$', '$1' } else { '0.0' }

trap { "$(Get-Date -Format s) $($_ | Out-String)" | Add-Content (Join-Path $AppDir 'error.log'); continue }

$mutex = New-Object Threading.Mutex($false, 'Local\ReLiveCompressorTray')
if (-not $mutex.WaitOne(0)) {
    # already running in the tray: ask that copy to bring up its window
    if ($Show) { New-Item -ItemType File -Force $ShowFlag | Out-Null }
    exit 0
}
Remove-Item $ShowFlag -ErrorAction SilentlyContinue

# ---------- state ----------
$script:Settings     = Get-Content $SettingsPath -Raw | ConvertFrom-Json
$script:Worker       = $null      # Process of the running Worker.ps1
$script:RunKind      = $null      # 'auto' | 'manual' | 'scan'
$script:Paused       = $false
$script:PausedByAuto = $false
$script:LastAutoTry  = [DateTime]::MinValue
$script:LastScan     = [DateTime]::MinValue
$script:Status       = $null
$script:QueuedFiles  = @()        # picked while another run was going; started when it finishes
$script:RunStarted   = Get-Date
$script:AwayStart    = $null      # when the user went idle (for the "while you were away" summary)
$script:AwaySummary  = $null      # @{ Count; SavedGB } shown on Home until dismissed
$script:UpdateTask   = $null      # pending update.json download (Task[string])
$script:Update       = $null      # update.json of a newer version
$script:UpdateState  = $null      # 'checking' | 'current' | 'available' | 'error'
$script:LastUpdateCheck = (Get-Date).AddDays(-1).AddMinutes(1)   # first check about a minute after start

function Save-Settings {
    ($script:Settings | ConvertTo-Json) | Set-Content $SettingsPath -Encoding UTF8
}

function Read-Status {
    try { $script:Status = Get-Content $StatusPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
}

function Test-WorkerRunning { $script:Worker -and -not $script:Worker.HasExited }

function Get-FfmpegProcess {
    if (-not $script:Status -or -not $script:Status.FfmpegPid) { return $null }
    $p = Get-Process -Id $script:Status.FfmpegPid -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'ffmpeg') { $p } else { $null }
}

# ---------- icons ----------
# app logo (ReLiveCompressor.ico) with a status dot in the corner
function New-StateIcon([string]$hex) {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $logo = New-Object Drawing.Icon $Icons.Logo, 32, 32
    $g.DrawIcon($logo, (New-Object Drawing.Rectangle 0, 0, 32, 32))
    # top-right corner is the empty one (the arrows run top-left and bottom-right)
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(16, 16, 16))), 17, 0, 15, 15)
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($hex))), 19, 2, 11, 11)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
# fallback when the .ico is missing: red square with the play button and "compress" arrows, same as the window's logo
function New-LogoIcon {
    $bmp = New-Object Drawing.Bitmap 64, 64
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#E5202E'))), 0, 0, 64, 64)
    $k = 64 * 0.92 / 24; $o = 2.56
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), (2.0 * $k)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $lines = @(@(1, 1, 6.2, 6.2), @(6.2, 2.6, 6.2, 6.2), @(6.2, 6.2, 2.6, 6.2), @(23, 23, 17.8, 17.8), @(17.8, 21.4, 17.8, 17.8), @(17.8, 17.8, 21.4, 17.8))
    foreach ($l in $lines) { $g.DrawLine($pen, $o + $l[0] * $k, $o + $l[1] * $k, $o + $l[2] * $k, $o + $l[3] * $k) }
    $g.DrawEllipse((New-Object Drawing.Pen ([Drawing.Color]::White), (1.6 * $k)), $o + 6.1 * $k, $o + 6.1 * $k, 11.8 * $k, 11.8 * $k)
    $g.FillPolygon([Drawing.Brushes]::White, [Drawing.PointF[]]@(
        (New-Object Drawing.PointF ($o + 9.9 * $k), ($o + 8.4 * $k)), (New-Object Drawing.PointF ($o + 9.9 * $k), ($o + 15.6 * $k)), (New-Object Drawing.PointF ($o + 16 * $k), ($o + 12 * $k))))
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$Icons = @{ Logo = if (Test-Path $IconPath) { New-Object Drawing.Icon $IconPath } else { New-LogoIcon } }
$Icons.Off     = New-StateIcon '#7A7A7A'
$Icons.On      = New-StateIcon '#2F7DE1'
$Icons.Running = New-StateIcon '#2EA043'
$Icons.Paused  = New-StateIcon '#D29922'

# ---------- worker control ----------
# Worker.ps1 in its own hidden process: through ReLiveCompressor.exe, or powershell.exe when run from the source folder
function New-WorkerStartInfo([string]$workerArgs) {
    $psi = if (Test-Path $HostExe) { New-Object Diagnostics.ProcessStartInfo $HostExe, "/worker $workerArgs" }
           else { New-Object Diagnostics.ProcessStartInfo 'powershell.exe', "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WorkerPath`" $workerArgs" }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi
}

# cleans up after an interrupted run (.part / .old files)
function Invoke-WorkerRecover { [Diagnostics.Process]::Start((New-WorkerStartInfo '-Recover')).WaitForExit() }

function Start-Worker([string]$kind, [string[]]$files) {
    if (Test-WorkerRunning) { return }
    Remove-Item $PauseFlag -ErrorAction SilentlyContinue
    $workerArgs = if ($kind -eq 'scan') { '-ScanOnly' } else { '' }
    if ($files) {
        ConvertTo-Json -InputObject @($files) | Set-Content $SelectionPath -Encoding UTF8
        $workerArgs = "-Files `"$SelectionPath`""
    }
    $script:Worker = [Diagnostics.Process]::Start((New-WorkerStartInfo $workerArgs))
    $script:RunKind = $kind
    $script:RunFiles = @($files)
    $script:RunStarted = Get-Date
    $script:Paused = $false; $script:PausedByAuto = $false
    if ($kind -eq 'scan') { $script:LastScan = Get-Date }
}

function Suspend-Worker([bool]$byAuto) {
    if (-not (Test-WorkerRunning) -or $script:Paused) { return }
    New-Item -ItemType File -Force $PauseFlag | Out-Null
    $ff = Get-FfmpegProcess
    if ($ff) { [RlcNative]::Suspend($ff.Handle) }
    $script:Paused = $true; $script:PausedByAuto = $byAuto
}

function Resume-Worker {
    if (-not $script:Paused) { return }
    Remove-Item $PauseFlag -ErrorAction SilentlyContinue
    $ff = Get-FfmpegProcess
    if ($ff) { [RlcNative]::Resume($ff.Handle) }
    $script:Paused = $false; $script:PausedByAuto = $false
}

function Stop-Worker {
    if (Test-WorkerRunning) {
        $ff = Get-FfmpegProcess
        if ($ff) { try { $ff.Kill(); $ff.WaitForExit(5000) | Out-Null } catch { } }
        try { $script:Worker.Kill(); $script:Worker.WaitForExit(5000) | Out-Null } catch { }
        # clean up the half-written .part file (originals are untouched until a file is verified)
        Invoke-WorkerRecover
    }
    Remove-Item $PauseFlag -ErrorAction SilentlyContinue
    $script:Worker = $null; $script:RunKind = $null
    $script:Paused = $false; $script:PausedByAuto = $false
    Remove-Item $SelectionPath -ErrorAction SilentlyContinue
    Read-Status
}

# ---------- actions shared by the tray menu and the window ----------
function Set-AutoEnabled([bool]$on) {
    # Test mode never runs on its own; the dialog lets the user switch to Replace or Move right there
    if ($on -and $script:Settings.Mode -eq 'Test' -and -not (Show-TestModeDialog)) { return $false }
    $script:Settings.AutoEnabled = $on
    Save-Settings
    if (-not $on -and $script:RunKind -eq 'auto') { Stop-Worker }
    $script:LastAutoTry = [DateTime]::MinValue
    Update-Ui
    Show-Balloon $(if ($on) { "Automatic compression is ON. It runs after $($script:Settings.IdleMinutes) idle minutes and pauses when you're back." } else { 'Automatic compression is OFF. Nothing will run until you turn it back on.' })
    $true
}

function Set-StartWithWindows([bool]$on) {
    if (-not $on) { Remove-Item $StartupLnk -ErrorAction SilentlyContinue }
    elseif (-not (Test-Path $StartupLnk)) {
        $sh = New-Object -ComObject WScript.Shell
        $l = $sh.CreateShortcut($StartupLnk)
        $l.TargetPath = $HostExe; $l.Arguments = '/tray'; $l.WorkingDirectory = $AppDir
        $l.IconLocation = "$HostExe,0"
        $l.Save()
    }
    Update-Ui
}

function Invoke-CompressNowToggle {
    if ((Test-WorkerRunning) -and $script:RunKind -ne 'scan') { $script:QueuedFiles = @(); Stop-Worker; Show-Balloon 'Stopped. The file in progress was discarded; its original is untouched.' }
    else {
        if (Test-WorkerRunning) { Stop-Worker }
        Start-Worker 'manual'
        Show-Balloon $(if ($script:Settings.Mode -eq 'Test') { "Test run started - copies go to $($script:Settings.TestFolder)" } else { 'Compression started.' })
    }
    Update-Ui
}

# Compress exactly these files now (Compress page, Explorer right-click, drag and drop).
# While another compression runs they're queued and start as soon as it finishes.
function Start-SelectedCompression([string[]]$paths) {
    $paths = @($paths | Where-Object { $_ } | Select-Object -Unique)
    if (-not $paths.Count) { return }
    $what = if ($paths.Count -eq 1) { '1 video' } else { "$($paths.Count) videos" }
    if ((Test-WorkerRunning) -and $script:RunKind -ne 'scan') {
        $script:QueuedFiles = @(@($script:QueuedFiles) + $paths | Select-Object -Unique)
        Show-Balloon "$what added - they start when the current compression finishes."
    }
    else {
        if (Test-WorkerRunning) { Stop-Worker }
        Start-Worker 'manual' $paths
        Show-Balloon $(if ($script:Settings.Mode -eq 'Test') { "Compressing $what - test copies go to $($script:Settings.TestFolder)" } else { "Compressing $what." })
    }
    Update-Ui
}

function Invoke-PauseToggle { if ($script:Paused) { Resume-Worker } else { Suspend-Worker $false }; Update-Ui }

function Invoke-Uninstall {
    $r = [Windows.Forms.MessageBox]::Show("Uninstall $AppName?`n`nThis stops it, removes the app, its shortcuts, settings and log. Your recordings (and any test copies) are not touched.", $AppName, 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Stop-Worker
    $tmp = Join-Path $env:TEMP 'ReLiveCompressor-Uninstall.ps1'
    Copy-Item (Join-Path $AppDir 'Uninstall.ps1') $tmp -Force
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`" -AppDir `"$AppDir`" -Quiet -WaitPid $PID"
    Exit-App
}

function Exit-App {
    $tray.Visible = $false
    if ($script:Win) { $script:Win.Hide() }
    [Windows.Forms.Application]::Exit()
}

# ---------- updates ----------
function Compare-Version([string]$a, [string]$b) {
    try { ([version]($a -replace '^v', '')).CompareTo([version]($b -replace '^v', '')) } catch { 0 }
}

# Downloads update.json in the background; the timer picks up the result (Receive-UpdateCheck).
function Start-UpdateCheck {
    if ($script:UpdateTask) { return }
    $script:LastUpdateCheck = Get-Date
    $url = if ($script:Settings.UpdateUrl) { $script:Settings.UpdateUrl } else { "https://github.com/$UpdateRepo/releases/latest/download/update.json" }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Headers['User-Agent'] = "ReLiveCompressor/$AppVersion"
        $wc.CachePolicy = New-Object Net.Cache.RequestCachePolicy ([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $script:UpdateTask = $wc.DownloadStringTaskAsync([Uri]$url)
        $script:UpdateState = 'checking'
    }
    catch { $script:UpdateState = 'error' }
}

function Receive-UpdateCheck {
    $t = $script:UpdateTask
    if (-not $t -or -not $t.IsCompleted) { return }
    $script:UpdateTask = $null
    $u = $null
    if (-not $t.IsFaulted -and -not $t.IsCanceled) { try { $u = $t.Result | ConvertFrom-Json } catch { } }
    if (-not $u -or -not $u.version) { $script:UpdateState = 'error'; Update-MainWindow; return }   # offline, or nothing published yet: stay quiet
    if ((Compare-Version $u.version $AppVersion) -gt 0) {
        $script:Update = $u; $script:UpdateState = 'available'
        if ([string]$script:Settings.UpdateNotified -ne [string]$u.version) {
            Set-Setting 'UpdateNotified' ([string]$u.version); Save-Settings
            Show-Balloon "Update available: ReLive Compressor $($u.version). Open the app to install it."
        }
    }
    else { $script:Update = $null; $script:UpdateState = 'current' }
    Update-MainWindow
}

# ---------- tray UI ----------
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip

$miOpen   = New-Object Windows.Forms.ToolStripMenuItem 'Open ReLive Compressor'
$miOpen.Font = New-Object Drawing.Font $miOpen.Font, ([Drawing.FontStyle]::Bold)
$miStatus = New-Object Windows.Forms.ToolStripMenuItem 'Starting...'
$miStatus.Enabled = $false
$miAuto   = New-Object Windows.Forms.ToolStripMenuItem 'Automatic compression (when idle)'
$miNow    = New-Object Windows.Forms.ToolStripMenuItem 'Compress all waiting now'
$miPause  = New-Object Windows.Forms.ToolStripMenuItem 'Pause'
$miSet    = New-Object Windows.Forms.ToolStripMenuItem 'Settings...'
$miUninst = New-Object Windows.Forms.ToolStripMenuItem 'Uninstall...'
$miExit   = New-Object Windows.Forms.ToolStripMenuItem 'Exit'
[void]$menu.Items.AddRange(@(
    $miOpen, (New-Object Windows.Forms.ToolStripSeparator),
    $miStatus, $miAuto, $miNow, $miPause, (New-Object Windows.Forms.ToolStripSeparator),
    $miSet, $miUninst, $miExit))
$tray.ContextMenuStrip = $menu

function Get-StatusText {
    $s = $script:Status
    if ((Test-WorkerRunning) -and $script:RunKind -ne 'scan' -and $s -and $s.State -eq 'running' -and $s.File) {
        $name = [IO.Path]::GetFileNameWithoutExtension($s.File)
        $verb = if ($script:Paused) { 'Paused' } else { 'Compressing' }
        $n = "$([int]$s.QueueDone + 1)/$($s.QueueTotal)"
        $eta = if ($s.EtaSeconds -and -not $script:Paused) { " - $(Format-Eta $s.EtaSeconds) left" } else { '' }
        return "$verb $n - $($s.Percent)%$eta - $name"
    }
    if (Test-WorkerRunning) { return 'Checking recordings...' }
    if ($s -and $s.State -eq 'noencoder') { return "No hardware video encoder found - needs an AMD Radeon RX 400 or newer" }
    if ($s -and $null -ne $s.Pending) {
        if ($s.Mode -eq 'Test' -and [int]$s.Pending -gt 0) { return "Test mode - $($s.Pending) files waiting ($($s.PendingGB) GB)" }
        if ([int]$s.Pending -eq 0) { return 'All recordings are compressed' }
        return "$($s.Pending) files waiting ($($s.PendingGB) GB)"
    }
    'Idle'
}

function Update-Ui {
    $running = (Test-WorkerRunning) -and $script:RunKind -ne 'scan'
    $text = Get-StatusText
    $miStatus.Text = $text
    $tip = "$AppName - $text"
    $tray.Text = if ($tip.Length -gt 63) { $tip.Substring(0, 60) + '...' } else { $tip }
    $miAuto.Checked = [bool]$script:Settings.AutoEnabled
    $miNow.Text = if ($running) { 'Stop compressing' } else { 'Compress all waiting now' }
    $miPause.Enabled = $running
    $miPause.Text = if ($script:Paused) { 'Resume' } else { 'Pause' }
    $tray.Icon = if ($running -and $script:Paused) { $Icons.Paused }
                 elseif ($running) { $Icons.Running }
                 elseif ($script:Settings.AutoEnabled) { $Icons.On }
                 else { $Icons.Off }
    Update-MainWindow
}

function Format-Eta($seconds) {
    $m = [math]::Ceiling([double]$seconds / 60)
    if ($m -le 1) { 'about a minute' } elseif ($m -lt 60) { "about $m min" } else { "about $([math]::Floor($m / 60)) h $($m % 60) min" }
}

function Show-Balloon([string]$text) {
    $tray.ShowBalloonTip(5000, $AppName, $text, [Windows.Forms.ToolTipIcon]::Info)
}

. (Join-Path $AppDir 'MainWindow.ps1')

# ---------- menu actions ----------
$miOpen.add_Click({ Show-MainWindow 'Home' })
$miAuto.add_Click({ [void](Set-AutoEnabled (-not $script:Settings.AutoEnabled)) })
$miNow.add_Click({ Invoke-CompressNowToggle })
$miPause.add_Click({ Invoke-PauseToggle })
$miSet.add_Click({ Show-MainWindow 'Settings' })
$miUninst.add_Click({ Invoke-Uninstall })
$miExit.add_Click({
    if ((Test-WorkerRunning) -and $script:RunKind -ne 'scan') {
        $r = [Windows.Forms.MessageBox]::Show('A compression is running. Exit and stop it?', $AppName, 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
    }
    Stop-Worker
    Exit-App
})
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-MainWindow 'Home' } })

# ---------- the loop: every 2 s ----------
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({
    if (Test-Path $ShowFlag) { Remove-Item $ShowFlag -ErrorAction SilentlyContinue; Show-MainWindow 'Home' }
    Read-Status
    $idle = [RlcNative]::IdleSeconds()
    $safe = ($idle -ge $script:Settings.IdleMinutes * 60) -and -not [RlcNative]::FullscreenAppRunning()

    # files from Explorer's right-click menu: wait until no more arrive (one process per selected file), then take them all
    if ((Test-Path $IncomingPath) -and ((Get-Date) - (Get-Item $IncomingPath).LastWriteTime).TotalSeconds -ge 1) {
        $added = @()
        try { $added = @(Get-Content $IncomingPath -ErrorAction Stop); Remove-Item $IncomingPath -ErrorAction Stop } catch { $added = @() }
        if ($added.Count) { Add-VideosFromPaths $added }
    }

    # "while you were away": remember when you left; when you're back, sum up what automatic runs did meanwhile
    if ($safe -and -not $script:AwayStart) { $script:AwayStart = (Get-Date).AddSeconds(-$idle) }
    elseif ($idle -lt 5 -and $script:AwayStart) {
        $since = $script:AwayStart; $script:AwayStart = $null
        $rows = @(Get-LogRows | Where-Object { $_.Result -in 'OK', 'OK-MOVED' -and [datetime]$_.Time -ge $since })
        if ($rows.Count) {
            $gb = [math]::Round((($rows | ForEach-Object { [double]$_.OrigMB - [double]$_.NewMB } | Measure-Object -Sum).Sum) / 1024, 1)
            $script:AwaySummary = @{ Count = $rows.Count; SavedGB = $gb }
            Show-Balloon "While you were away: compressed $(Format-Count $rows.Count 'clip') and saved $gb GB."
        }
    }

    if ($script:Settings.CheckUpdates -ne $false -and ((Get-Date) - $script:LastUpdateCheck).TotalHours -ge 24) { Start-UpdateCheck }
    Receive-UpdateCheck

    if ($script:Worker -and $script:Worker.HasExited) {
        # a run just finished
        $kind = $script:RunKind
        $script:Worker = $null; $script:RunKind = $null; $script:Paused = $false
        Remove-Item $PauseFlag, $SelectionPath -ErrorAction SilentlyContinue
        Read-Status
        $s = $script:Status
        $problem = if ($kind -ne 'scan') { Get-RunProblem $script:RunStarted } else { $null }
        if ($kind -ne 'scan' -and $s -and [int]$s.Succeeded -gt 0) {
            $tail = if ($problem) { " $problem" } else { '' }
            if ($s.Mode -eq 'Test') { Show-Balloon "Test batch done: $($s.Succeeded) copies in $($script:Settings.TestFolder). Compare them, then pick Replace or Move in Settings.$tail" }
            else { Show-Balloon "Compressed $(Format-Count ([int]$s.Succeeded) 'recording') and saved $($s.SavedGB) GB.$tail" }
        }
        elseif ($problem) { Show-Balloon $problem }
        Update-MainWindowAfterRun
        if ($script:QueuedFiles.Count) {
            $next = $script:QueuedFiles; $script:QueuedFiles = @()
            Start-Worker 'manual' $next
        }
    }
    elseif ((Test-WorkerRunning) -and $script:RunKind -eq 'auto') {
        if (-not $safe -and -not $script:Paused) { Suspend-Worker $true }              # you're back: pause
        elseif ($safe -and $script:Paused -and $script:PausedByAuto) { Resume-Worker } # away again: continue
    }
    elseif (-not (Test-WorkerRunning)) {
        $now = Get-Date
        if ($script:Settings.AutoEnabled -and $script:Settings.Mode -ne 'Test' -and $safe -and ($now - $script:LastAutoTry).TotalMinutes -ge 10) {
            $script:LastAutoTry = $now
            Start-Worker 'auto'
        }
        elseif (($now - $script:LastScan).TotalMinutes -ge 30) {
            Start-Worker 'scan'       # keeps the "files waiting" count fresh
        }
    }
    Update-Ui
})

# ---------- start ----------
Invoke-WorkerRecover
Read-Status
Start-Worker 'scan'
Update-Ui
if ($script:Settings.FirstRun) {
    Show-MainWindow 'Home'
    Show-WelcomeGuide          # sets FirstRun to false once finished or skipped
}
elseif ($Show) { Show-MainWindow 'Home' }
$timer.Start()
[Windows.Forms.Application]::Run()

$timer.Stop()
$tray.Dispose()
$mutex.ReleaseMutex()
