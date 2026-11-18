# ReLive Compressor - uninstaller
# Removes the app, shortcuts, settings, log and the Installed-apps entry.
# Never deletes recordings or test copies; only unfinished *.mp4.part temp files.
param(
    [string]$AppDir = $PSScriptRoot,
    [switch]$Quiet,
    [int]$WaitPid = 0
)
$AppName = 'ReLive Compressor'
Add-Type -AssemblyName System.Windows.Forms

# Run from a temp copy so the app folder itself can be deleted
if ($PSScriptRoot -eq $AppDir.TrimEnd('\')) {
    $tmp = Join-Path $env:TEMP 'ReLiveCompressor-Uninstall.ps1'
    Copy-Item $PSCommandPath $tmp -Force
    $q = if ($Quiet) { ' -Quiet' } else { '' }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`" -AppDir `"$AppDir`"$q -WaitPid $PID"
    exit
}

if (-not $Quiet) {
    $r = [Windows.Forms.MessageBox]::Show("Uninstall $AppName?`n`nYour recordings (and any test copies) are not touched.", $AppName, 'YesNo', 'Question')
    if ($r -ne 'Yes') { exit }
}

if ($WaitPid) { Wait-Process -Id $WaitPid -Timeout 15 -ErrorAction SilentlyContinue }

# stop tray app, worker and its ffmpeg
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like "*$($AppDir.TrimEnd('\'))\*" -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

# remove unfinished temp files and restore any original caught mid-swap
$settingsPath = Join-Path $AppDir 'settings.json'
if (Test-Path $settingsPath) {
    $S = Get-Content $settingsPath -Raw | ConvertFrom-Json
    foreach ($d in @($S.RecordingsFolder, $S.TestFolder)) {
        if ($d -and (Test-Path $d)) {
            Get-ChildItem -LiteralPath $d -Recurse -File -Filter '*.mp4.part' | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path $S.RecordingsFolder) {
        Get-ChildItem -LiteralPath $S.RecordingsFolder -Recurse -File -Filter '*.mp4.old' | ForEach-Object {
            $final = $_.FullName.Substring(0, $_.FullName.Length - 4)
            if (-not (Test-Path -LiteralPath $final)) { Rename-Item -LiteralPath $_.FullName -NewName (Split-Path $final -Leaf) }
        }
    }
}

Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) $AppName) -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ReLiveCompressor' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Classes\SystemFileAssociations\.mp4\shell\ReLiveCompressor' -Recurse -Force -ErrorAction SilentlyContinue

# only the app's own files, then the folder if that left it empty (never anything else someone put there)
$own = 'ReLiveCompressor.exe', 'ReLiveCompressor.ps1','MainWindow.ps1', 'MainWindow.xaml', 'Worker.ps1', 'Uninstall.ps1', 'Install.ps1', 'Launch.vbs', 'Setup.cmd',
       'ReLiveCompressor.ico', 'License.txt', 'ThirdPartyNotices.txt', 'FFmpeg-GPLv3.txt', 'ffmpeg.exe',
       'bitrate-src.jpg', 'bitrate-10.jpg', 'bitrate-20.jpg', 'bitrate-40.jpg',
       'settings.json', 'status.json', 'status.json.tmp', 'scan-cache.json', 'compress-log.csv', 'error.log', 'setup-log.txt',
       'pause.flag', 'stop.flag', 'show.flag', 'thumbs', 'compare', 'selection.json', 'incoming.txt', 'extra-dirs.txt'
foreach ($f in $own) { Remove-Item (Join-Path $AppDir $f) -Recurse -Force -ErrorAction SilentlyContinue }
Get-ChildItem $AppDir -Filter '*.setup-tmp' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
if (-not (Get-ChildItem $AppDir -Force -ErrorAction SilentlyContinue)) { Remove-Item $AppDir -Force -ErrorAction SilentlyContinue }

if (-not $Quiet) {
    $msg = if (Test-Path $AppDir) { "$AppName was removed, but some files in $AppDir could not be deleted. You can delete that folder yourself." }
           else { "$AppName has been completely removed." }
    [void][Windows.Forms.MessageBox]::Show($msg, $AppName)
}
