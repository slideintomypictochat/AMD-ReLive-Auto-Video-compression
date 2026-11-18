# ReLive Compressor - installer (per-user, no admin needed)
# Normally run by "ReLive Compressor Setup.exe", which unpacks the files into AppDir first.
#   powershell -ExecutionPolicy Bypass -File Install.ps1 [-AppDir <folder>] [-FFmpeg C:\path\ffmpeg.exe]
#       [-NoStartup] [-DesktopShortcut] [-NoLaunch]
param(
    [string]$FFmpeg = '',
    [string]$AppDir = (Join-Path $env:LOCALAPPDATA 'Programs\ReLive Compressor'),
    [string]$Version = '1.6.1',
    [string]$Publisher = 'ReLive Compressor',
    [switch]$NoStartup,
    [switch]$DesktopShortcut,
    [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'
$AppName = 'ReLive Compressor'
$Src     = $PSScriptRoot
$AppDir  = [IO.Path]::GetFullPath($AppDir).TrimEnd('\')
$Menu    = Join-Path ([Environment]::GetFolderPath('Programs')) $AppName
$Startup = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
$Desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
$RegKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ReLiveCompressor'
$Exe     = Join-Path $AppDir 'ReLiveCompressor.exe'   # runs the scripts, so Windows shows "ReLive Compressor" and never a PowerShell window
$ownFFmpeg = Join-Path $AppDir 'ffmpeg.exe'

if (-not $FFmpeg) { $FFmpeg = if (Test-Path $ownFFmpeg) { $ownFFmpeg } else { Join-Path $Src 'ffmpeg.exe' } }
if (-not (Test-Path $FFmpeg)) { throw "ffmpeg.exe not found at $FFmpeg (pass -FFmpeg <path>)" }

# stop a running copy before overwriting files
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='ReLiveCompressor.exe' OR Name='wscript.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and ($_.CommandLine -like "*$AppDir\*" -or $_.ExecutablePath -like "$AppDir\*") } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $AppDir | Out-Null
if ((Resolve-Path $Src).Path.TrimEnd('\') -ne (Resolve-Path $AppDir).Path.TrimEnd('\')) {
    foreach ($f in 'ReLiveCompressor.exe', 'ReLiveCompressor.ps1', 'MainWindow.ps1', 'MainWindow.xaml', 'Worker.ps1', 'Uninstall.ps1',
                   'bitrate-src.jpg', 'bitrate-10.jpg', 'bitrate-20.jpg', 'bitrate-40.jpg',
                   'ReLiveCompressor.ico', 'License.txt', 'ThirdPartyNotices.txt', 'FFmpeg-GPLv3.txt') {
        if (Test-Path (Join-Path $Src $f)) { Copy-Item (Join-Path $Src $f) $AppDir -Force }
    }
}
if (-not (Test-Path $Exe)) { throw "ReLiveCompressor.exe not found in $AppDir" }
# launchers from 1.1 that started powershell.exe directly
foreach ($old in 'Launch.vbs', 'Setup.cmd', 'setup-log.txt') { Remove-Item (Join-Path $AppDir $old) -Force -ErrorAction SilentlyContinue }
# own copy of ffmpeg so the app keeps working if the original folder is removed
if ((Resolve-Path $FFmpeg).Path -ne $ownFFmpeg -and -not (Test-Path $ownFFmpeg)) { Copy-Item $FFmpeg $ownFFmpeg -Force }

$settingsPath = Join-Path $AppDir 'settings.json'
$videos = [Environment]::GetFolderPath('MyVideos')
# the folder AMD Software (Adrenalin) records to, if it's set and exists
$adrenalin = (Get-ItemProperty 'HKCU:\Software\AMD\DVR' -ErrorAction SilentlyContinue).CaptureFileOutput
$recordings = if ($adrenalin -and (Test-Path -LiteralPath $adrenalin)) { $adrenalin.TrimEnd('\') } else { Join-Path $videos 'Radeon ReLive' }
if (-not (Test-Path $settingsPath)) {
    # fresh install starts safe: Test mode (originals untouched) and automatic compression off; the welcome guide asks the rest
    [ordered]@{
        AutoEnabled      = $false
        Mode             = 'Test'
        RecordingsFolder = $recordings
        TestFolder       = Join-Path $videos 'ReLive Compression Test'
        MoveFolder       = Join-Path $videos 'ReLive Originals'
        TestCount        = 5
        TargetMbps       = 20
        Preset           = 'balanced'
        IdleMinutes      = 10
        FFmpegPath       = $ownFFmpeg
        RecycleOriginals = $true
        CheckUpdates     = $true
        FirstRun         = $true
    } | ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
}
else {
    # kept settings from an earlier install: point them at this folder's ffmpeg
    $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $existing.FFmpegPath = $ownFFmpeg
    $existing | ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
}

# shortcuts
$sh = New-Object -ComObject WScript.Shell
New-Item -ItemType Directory -Force $Menu | Out-Null
function New-Shortcut($path, $arguments, $desc) {
    $l = $sh.CreateShortcut($path)
    $l.TargetPath = $Exe; $l.Arguments = $arguments; $l.WorkingDirectory = $AppDir; $l.Description = $desc
    $l.IconLocation = "$Exe,0"
    $l.Save()
}
New-Shortcut (Join-Path $Menu "$AppName.lnk") '' 'Compress Radeon ReLive recordings'
New-Shortcut (Join-Path $Menu "Uninstall $AppName.lnk") '/uninstall' "Remove $AppName"
if ($NoStartup) { Remove-Item $Startup -ErrorAction SilentlyContinue }
else { New-Shortcut $Startup '/tray' 'Compress Radeon ReLive recordings' }
if ($DesktopShortcut) { New-Shortcut $Desktop '' 'Compress Radeon ReLive recordings' }

# File Explorer: right-click an .mp4 > "Compress with ReLive Compressor" (this user only)
$verb = 'HKCU:\Software\Classes\SystemFileAssociations\.mp4\shell\ReLiveCompressor'
New-Item -Force "$verb\command" | Out-Null
Set-ItemProperty $verb 'MUIVerb' 'Compress with ReLive Compressor'
Set-ItemProperty $verb 'Icon' "$Exe,0"
Set-ItemProperty $verb 'MultiSelectModel' 'Player'      # no 15-file limit; one call per selected file
Set-Item "$verb\command" "`"$Exe`" /add `"%1`""

# entry in Settings > Apps > Installed apps
New-Item -Force $RegKey | Out-Null
$sizeKB = [int]((Get-ChildItem $AppDir -File | Measure-Object Length -Sum).Sum / 1KB)
$props = @{
    DisplayName     = $AppName
    DisplayVersion  = $Version
    Publisher       = $Publisher
    InstallLocation = $AppDir
    InstallDate     = (Get-Date).ToString('yyyyMMdd')
    DisplayIcon     = "$Exe,0"
    UninstallString = "`"$Exe`" /uninstall"
}
foreach ($k in $props.Keys) { Set-ItemProperty $RegKey $k $props[$k] }
Set-ItemProperty $RegKey NoModify 1 -Type DWord
Set-ItemProperty $RegKey NoRepair 1 -Type DWord
Set-ItemProperty $RegKey EstimatedSize $sizeKB -Type DWord

if (-not $NoLaunch) { Start-Process $Exe }
Write-Host "$AppName $Version installed to $AppDir."
