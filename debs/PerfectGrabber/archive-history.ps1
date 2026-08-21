[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = $PSScriptRoot
$projectRoot = Split-Path $sourceRoot -Parent
$testName = -join @([char]0x6D4B, [char]0x8BD5, [char]0x7248)
$formalName = -join @([char]0x6B63, [char]0x5F0F, [char]0x7248)
$historyName = -join @([char]0x5386, [char]0x53F2, [char]0x6784, [char]0x5EFA)
$logName = (-join @([char]0x66F4, [char]0x65B0, [char]0x65E5, [char]0x5FD7)) + '.txt'
$testRoot = Join-Path $projectRoot $testName
$formalRoot = Join-Path $projectRoot $formalName
$templatePath = Join-Path $sourceRoot 'history-release-notes-template.txt'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
New-Item -ItemType Directory -Path $formalRoot -Force | Out-Null

$records = @()
$sources = Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter '*.deb' |
    Where-Object {
        -not $_.FullName.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not $_.FullName.StartsWith($formalRoot, [StringComparison]::OrdinalIgnoreCase)
    }

foreach ($file in $sources) {
    $match = [regex]::Match($file.Name, '1\.1-7\+roothide(\d+)')
    if (-not $match.Success) { continue }
    $records += [PSCustomObject]@{
        VersionNumber = [int]$match.Groups[1].Value
        File = $file
        Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}

$archived = 0
$deduplicated = 0
$variants = 0

for ($number = 1; $number -le 31; $number++) {
    $version = "1.1-7+roothide$number"
    $releaseName = "Ntonia-PreferenceLoader-bate${number}_hide64e"
    $releaseDir = Join-Path $testRoot $releaseName
    $mainPackage = Join-Path $releaseDir 'Ntonia-PreferenceLoader.deb'
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null

    $candidates = @($records |
        Where-Object VersionNumber -eq $number |
        Sort-Object @{ Expression = { if ($_.File.FullName -like '*\source\packages\*') { 0 } else { 1 } } },
                    @{ Expression = { $_.File.FullName } })

    if (-not (Test-Path -LiteralPath $mainPackage)) {
        if ($candidates.Count -eq 0) { throw "Missing historical package for $version." }
        Move-Item -LiteralPath $candidates[0].File.FullName -Destination $mainPackage
        $archived++
        $candidates = @($candidates | Select-Object -Skip 1)
    }

    $mainHash = (Get-FileHash -LiteralPath $mainPackage -Algorithm SHA256).Hash
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.File.FullName)) { continue }
        if ($candidate.Hash -eq $mainHash) {
            [System.IO.File]::Delete($candidate.File.FullName)
            $deduplicated++
            continue
        }

        $historyDir = Join-Path $releaseDir $historyName
        New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
        $variantPath = Join-Path $historyDir $candidate.File.Name
        if (Test-Path -LiteralPath $variantPath) {
            $existingHash = (Get-FileHash -LiteralPath $variantPath -Algorithm SHA256).Hash
            if ($existingHash -eq $candidate.Hash) {
                [System.IO.File]::Delete($candidate.File.FullName)
                $deduplicated++
                continue
            }
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($candidate.File.Name)
            $variantPath = Join-Path $historyDir ("$baseName-$($candidate.Hash.Substring(0, 8)).deb")
        }
        Move-Item -LiteralPath $candidate.File.FullName -Destination $variantPath
        $variants++
    }

    $releaseLog = Join-Path $releaseDir $logName
    if (-not (Test-Path -LiteralPath $releaseLog)) {
        $date = (Get-Item -LiteralPath $mainPackage).LastWriteTime.ToString('yyyy-MM-dd')
        $notes = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)
        $notes = $notes.Replace('{{VERSION}}', $version).Replace('{{DATE}}', $date)
        [System.IO.File]::WriteAllText($releaseLog, $notes, $utf8NoBom)
    }

    $hash = (Get-FileHash -LiteralPath $mainPackage -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText(
        (Join-Path $releaseDir 'SHA256.txt'),
        "$hash  Ntonia-PreferenceLoader.deb`r`n",
        $utf8NoBom
    )

    $historyDir = Join-Path $releaseDir $historyName
    if (Test-Path -LiteralPath $historyDir) {
        $historyHashes = Get-ChildItem -LiteralPath $historyDir -File -Filter '*.deb' |
            Sort-Object Name |
            ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.Name }
        [System.IO.File]::WriteAllText(
            (Join-Path $historyDir 'SHA256.txt'),
            (($historyHashes -join "`r`n") + "`r`n"),
            $utf8NoBom
        )
    }

    $archive = Join-Path $releaseDir "$releaseName.zip"
    Compress-Archive -LiteralPath $mainPackage -DestinationPath $archive -CompressionLevel Optimal -Force
}

$versionDirectories = @(Get-ChildItem -LiteralPath $testRoot -Directory -Filter 'Ntonia-PreferenceLoader-bate*_hide64e')
Write-Output "Archived: $archived"
Write-Output "Deduplicated: $deduplicated"
Write-Output "Preserved variants: $variants"
Write-Output "Version directories: $($versionDirectories.Count)"
