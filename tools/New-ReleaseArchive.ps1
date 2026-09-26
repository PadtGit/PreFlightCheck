#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a ready-to-run PreFlightCheck ZIP from the current checkout.
.DESCRIPTION
    Includes only runtime scripts, modules, version, license, and user documentation.
    The archive has one versioned root folder. It does not include local reports,
    test fixtures, or repository metadata.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repositoryRoot 'dist' }
$version = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw -ErrorAction Stop).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid VERSION: $version" }

$files = @(
    'Start-Maintenance.cmd', 'Start-Maintenance.ps1', 'Dashboard.Core.psm1',
    'Invoke-GuiTask.ps1', 'Invoke-PreBackupRun.ps1', 'Maintenance.Core.psm1',
    'PreBackupMaintenance.ps1', 'Update-Applications.ps1', 'Weekly-DellReview.ps1',
    'VERSION', 'README.md', 'CHANGELOG.md', 'LICENSE'
)
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $file) -PathType Leaf)) {
        throw "Release archive is missing required file: $file"
    }
}

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($outputRoot)
$archivePath = Join-Path $outputRoot "PreFlightCheck-$version.zip"
if (Test-Path -LiteralPath $archivePath) { throw "Release archive already exists: $archivePath" }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $entryName = "PreFlightCheck-$version/$file"
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, (Join-Path $repositoryRoot $file), $entryName,
            [IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $archive.Dispose()
}

Write-Output $archivePath
