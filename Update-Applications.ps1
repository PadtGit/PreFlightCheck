#Requires -Version 5.1
<#
.SYNOPSIS
    Previews WinGet application updates or installs explicitly selected updates.
.DESCRIPTION
    Preview is the default. Installation requires -Install and exact package IDs.
    Dell BIOS, firmware and drivers are intentionally outside this workflow.
.PARAMETER ApplicationId
    Exact IDs copied from the preview, for example Microsoft.PowerToys.
.PARAMETER Install
    Installs only the exact IDs supplied in ApplicationId.
.PARAMETER ReportDirectory
    Directory where the maintenance script creates a unique report folder.
.EXAMPLE
    .\Update-Applications.ps1
.EXAMPLE
    .\Update-Applications.ps1 -ApplicationId Microsoft.PowerToys -Install
.EXAMPLE
    .\Update-Applications.ps1 -ApplicationId Microsoft.PowerToys -Install -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string[]]$ApplicationId = @(),
    [switch]$Install,
    [string]$ReportDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'Reports')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Install -and $ApplicationId.Count -eq 0) {
    throw 'Supply at least one exact ApplicationId when using -Install.'
}
if (-not $Install -and $ApplicationId.Count -gt 0) {
    throw 'ApplicationId is only used with -Install. Run without parameters to preview updates.'
}
$maintenanceScript = Join-Path -Path $PSScriptRoot -ChildPath 'PreBackupMaintenance.ps1'
$parameters = @{ Mode = 'Updates'; ReportDirectory = $ReportDirectory }
if ($Install) {
    $parameters.ApplicationId = $ApplicationId
    $parameters.MaintenanceWindowConfirmed = $true
}
if ($WhatIfPreference) { $parameters.WhatIf = $true }
& $maintenanceScript @parameters
exit $LASTEXITCODE
