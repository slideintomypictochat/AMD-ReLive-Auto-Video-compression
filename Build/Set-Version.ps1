# Writes one version number (e.g. 1.6.1) into every place that carries it, so they never disagree:
# Setup.cs, AppHost.cs, Setup.manifest and Install.ps1. The app reads its own version from ReLiveCompressor.exe.
#   powershell -ExecutionPolicy Bypass -File Set-Version.ps1 -Version 1.6.1
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must look like 1.6.1 (got '$Version')" }
$four = "$Version.0"
$App = Join-Path $PSScriptRoot '..\ReLive Compressor'

$edits = @(
    @((Join-Path $PSScriptRoot 'Setup.cs'),       'AssemblyVersion\("[\d.]+"\)',              "AssemblyVersion(`"$four`")"),
    @((Join-Path $PSScriptRoot 'Setup.cs'),       'AssemblyFileVersion\("[\d.]+"\)',          "AssemblyFileVersion(`"$four`")"),
    @((Join-Path $PSScriptRoot 'Setup.cs'),       'public const string Version = "[\d.]+";',  "public const string Version = `"$Version`";"),
    @((Join-Path $PSScriptRoot 'AppHost.cs'),     'AssemblyVersion\("[\d.]+"\)',              "AssemblyVersion(`"$four`")"),
    @((Join-Path $PSScriptRoot 'AppHost.cs'),     'AssemblyFileVersion\("[\d.]+"\)',          "AssemblyFileVersion(`"$four`")"),
    @((Join-Path $PSScriptRoot 'Setup.manifest'), '(<assemblyIdentity version=")[\d.]+(")',    "`${1}$four`${2}"),
    @((Join-Path $App 'Install.ps1'),             "\[string\]\`$Version = '[\d.]+'",          "[string]`$Version = '$Version'")
)
foreach ($e in $edits) {
    $text = [IO.File]::ReadAllText($e[0])
    if ($text -notmatch $e[1]) { throw "Version pattern not found in $($e[0]): $($e[1])" }
    $new = [regex]::Replace($text, $e[1], $e[2])
    if ($new -ne $text) { [IO.File]::WriteAllText($e[0], $new, (New-Object Text.UTF8Encoding $true)) }
}
Write-Host "Version set to $Version"
