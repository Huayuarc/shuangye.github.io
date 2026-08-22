[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$wslProject = (wsl.exe -d MangoDev -- wslpath -a ($projectRoot -replace '\\', '/')).Trim()
if (-not $wslProject) { throw 'Unable to resolve project path in WSL.' }
wsl.exe -d MangoDev -- bash "$wslProject/build.sh"
if ($LASTEXITCODE -ne 0) { throw "Theos build failed with exit code $LASTEXITCODE." }

$control = Get-Content -LiteralPath (Join-Path $projectRoot 'control') -Raw
$match = [regex]::Match($control, '(?m)^Version:\s*(.+?)\s*$')
if (-not $match.Success) { throw 'Unable to read Version from control.' }
$version = $match.Groups[1].Value
$buildMatch = [regex]::Match($version, 'roothide(\d+)$')
if (-not $buildMatch.Success) { throw 'Version must end with roothide followed by a number.' }
$releaseName = 'Ntonia-PreferenceLoader-bate{0}_hide64e' -f $buildMatch.Groups[1].Value
$testDirectoryName = -join @([char]0x6D4B, [char]0x8BD5, [char]0x7248)
$releaseDir = Join-Path (Split-Path $projectRoot -Parent) (Join-Path $testDirectoryName $releaseName)
Get-ChildItem -LiteralPath $releaseDir -File | Sort-Object Name
