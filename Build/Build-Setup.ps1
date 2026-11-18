# Builds "ReLive Compressor Setup.exe": regenerates the icon, zips the app files + ffmpeg.exe
# into payload.zip and compiles Setup.cs around it with the C# compiler that ships with Windows.
#   powershell -ExecutionPolicy Bypass -File Build-Setup.ps1 [-FFmpeg <path to ffmpeg.exe>]
param(
    [string]$FFmpeg = (Join-Path $PSScriptRoot 'ffmpeg\ffmpeg.exe'),   # own copy, so builds don't depend on an installed app
    [string]$OutDir = (Join-Path $PSScriptRoot '..\dist')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$App   = (Resolve-Path (Join-Path $PSScriptRoot '..\ReLive Compressor')).Path
$Stage = Join-Path $env:TEMP 'ReLiveCompressor-build'
$Csc   = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$Fx    = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$Exe    = Join-Path $OutDir 'ReLive Compressor Setup.exe'

if (-not (Test-Path $FFmpeg)) { throw "ffmpeg.exe not found at $FFmpeg" }

# 1. icon
& (Join-Path $PSScriptRoot 'Make-Icon.ps1') -Out (Join-Path $App 'ReLiveCompressor.ico')

# 2. payload
Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $Stage 'files') | Out-Null
$files = 'ReLiveCompressor.ps1', 'MainWindow.ps1', 'MainWindow.xaml', 'Worker.ps1', 'Install.ps1', 'Uninstall.ps1',
         'ReLiveCompressor.ico', 'License.txt', 'ThirdPartyNotices.txt', 'FFmpeg-GPLv3.txt',
         'bitrate-src.jpg', 'bitrate-10.jpg', 'bitrate-20.jpg', 'bitrate-40.jpg'
foreach ($f in $files) { Copy-Item (Join-Path $App $f) (Join-Path $Stage 'files') }
Copy-Item $FFmpeg (Join-Path $Stage 'files\ffmpeg.exe')

# ReLiveCompressor.exe: hosts the scripts so Windows shows the app's own name and icon, not PowerShell
$sma = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll'
& $Csc /nologo /target:winexe /optimize+ "/out:$(Join-Path $Stage 'files\ReLiveCompressor.exe')" "/win32icon:$(Join-Path $App 'ReLiveCompressor.ico')" "/reference:$sma" (Join-Path $PSScriptRoot 'AppHost.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed on AppHost.cs ($LASTEXITCODE)" }
$zip = Join-Path $Stage 'payload.zip'
[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $Stage 'files'), $zip, 'Optimal', $false)
Write-Host ("payload.zip: {0:N1} MB" -f ((Get-Item $zip).Length / 1MB))

# 3. compile
$cscArgs = @(
    '/nologo', '/target:winexe', '/optimize+', '/platform:anycpu',
    "/out:$Exe",
    "/win32icon:$(Join-Path $App 'ReLiveCompressor.ico')",
    "/win32manifest:$(Join-Path $PSScriptRoot 'Setup.manifest')",
    "/resource:$zip,payload.zip",
    "/reference:$Fx\System.IO.Compression.dll",
    '/reference:System.Management.dll', '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
    (Join-Path $PSScriptRoot 'Setup.cs')
)
& $Csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Remove-Item $Stage -Recurse -Force
Write-Host ("Built {0} ({1:N1} MB)" -f $Exe, ((Get-Item $Exe).Length / 1MB))
