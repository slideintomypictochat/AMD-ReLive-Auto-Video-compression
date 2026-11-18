# Publishes a new version: everyone who has ReLive Compressor installed gets "Update available" within a day.
#   powershell -ExecutionPolicy Bypass -File Build\Publish-Update.ps1 -Version 1.6.1 -Notes "Fixed X", "Added Y"
#
# What it does:
#   1. stamps the version everywhere (Set-Version.ps1) and builds the installer (Build-Setup.ps1)
#   2. writes update.json: version, download address, size and SHA-256 (the app refuses a download that doesn't match)
#   3. creates the GitHub release v<version> with ReLiveCompressorSetup.exe and update.json attached
# The app looks at https://github.com/<repo>/releases/latest/download/update.json, so the newest release wins.
#
# One-time setup: winget install GitHub.cli, then gh auth login. The repo needs at least one commit (git push) first.
# -NoUpload builds and writes the files to dist\release without publishing (to test, or to upload by hand).
# -Replace re-uploads the files to an existing release of the same version.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string[]]$Notes = @(),
    [switch]$NoUpload,
    [switch]$Replace
)
$ErrorActionPreference = 'Stop'
$Repo  = 'slideintomypictochat/AMD-ReLive-Auto-Video-compression'   # same as $UpdateRepo in ReLiveCompressor.ps1
$Asset = 'ReLiveCompressorSetup.exe'                                # no spaces: GitHub renames those

if (-not $NoUpload -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI not found. Install it once with 'winget install GitHub.cli', then run 'gh auth login'."
}

& (Join-Path $PSScriptRoot 'Set-Version.ps1') -Version $Version
& (Join-Path $PSScriptRoot 'Build-Setup.ps1')

$dist = (Resolve-Path (Join-Path $PSScriptRoot '..\dist')).Path
$out  = Join-Path $dist 'release'
New-Item -ItemType Directory -Force $out | Out-Null
$exe  = Join-Path $out $Asset
Copy-Item (Join-Path $dist 'ReLive Compressor Setup.exe') $exe -Force
$file = Get-Item $exe

$info = [ordered]@{
    version = $Version
    asset   = $Asset
    url     = "https://github.com/$Repo/releases/download/v$Version/$Asset"
    size    = $file.Length
    sha256  = (Get-FileHash $exe -Algorithm SHA256).Hash
    notes   = @($Notes)
    date    = (Get-Date).ToString('yyyy-MM-dd')
}
$json = Join-Path $out 'update.json'
[IO.File]::WriteAllText($json, ($info | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $json"

if ($NoUpload) { Write-Host "Not uploaded (-NoUpload). Files are in $out"; return }

$body = "## What's new`n" + (($Notes | ForEach-Object { "- $_" }) -join "`n") +
        "`n`nInstalled copies update themselves (Home shows **Update available**). New install: download **$Asset** and run it."
if ($Replace) {
    gh release upload "v$Version" $exe $json --repo $Repo --clobber
}
else {
    gh release create "v$Version" $exe $json --repo $Repo --title "ReLive Compressor $Version" --notes $body --latest
}
if ($LASTEXITCODE -ne 0) { throw "gh failed ($LASTEXITCODE)" }
Write-Host "Published ReLive Compressor ${Version}: https://github.com/$Repo/releases/tag/v$Version"
