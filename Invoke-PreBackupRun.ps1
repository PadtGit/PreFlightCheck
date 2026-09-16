#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the guarded pre-backup sequence and creates one combined summary.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReportDirectory,
    [ValidateRange(7,365)][int]$MinimumAgeDays = 14,
    [switch]$EmptyRecycleBin,
    [switch]$ClearDeliveryCache,
    [switch]$MaintenanceWindowConfirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$maintenanceScript = Join-Path -Path $PSScriptRoot -ChildPath 'PreBackupMaintenance.ps1'
$windowsPowerShell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
[void][IO.Directory]::CreateDirectory($ReportDirectory)
$combinedLog = Join-Path -Path $ReportDirectory -ChildPath 'guided-run.log'
$resultPath = Join-Path -Path $ReportDirectory -ChildPath 'guided-result.json'
$steps = [System.Collections.Generic.List[object]]::new()
$restartRequired = $false
$repairRecommended = $false
$healthReady = $false
$failure = $null

function Write-RunLog {
    param([string]$Message)
    ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) | Add-Content -LiteralPath $combinedLog -Encoding UTF8
}

function Invoke-RunStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $stepRoot = Join-Path -Path $ReportDirectory -ChildPath $Name
    [void][IO.Directory]::CreateDirectory($stepRoot)
    Write-RunLog "START $Name"
    $output = & $windowsPowerShell -NoLogo -NoProfile -File $maintenanceScript @Arguments -ReportDirectory $stepRoot 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $output.Trim() | Set-Content -LiteralPath (Join-Path -Path $ReportDirectory -ChildPath "$Name-console.txt") -Encoding UTF8
    $reportFile = Get-ChildItem -LiteralPath $stepRoot -Filter report.json -File -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $reportFile) { throw "$Name did not create report.json." }
    $stepReport = Get-Content -LiteralPath $reportFile.FullName -Raw | ConvertFrom-Json
    $steps.Add([pscustomobject]@{ Step = $Name; ExitCode = $exitCode; Report = $reportFile.Directory.FullName })
    Write-RunLog "END $Name exit=$exitCode report=$($reportFile.Directory.FullName)"
    if ($exitCode -eq 1) { throw "$Name failed. Open its report before continuing." }
    return $stepReport
}

try {
    $identity = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The guided pre-backup run requires Administrator permission.' }
    if (-not $MaintenanceWindowConfirmed) { throw 'Confirm the maintenance window before starting the guided run.' }
    Write-RunLog 'Guided pre-backup run started. Order: review, health, updates preview, cleanup preview, cleanup, final review.'

    $audit = Invoke-RunStep -Name '01-SystemReview' -Arguments @('-Mode','Audit')
    if ($audit.Restart.Pending -or @($audit.Restart.Unknown).Count -gt 0) {
        $restartRequired = $true
        throw 'RESTART REQUIRED: restart Windows, then begin a new guided run.'
    }

    $health = Invoke-RunStep -Name '02-WindowsHealth' -Arguments @('-Mode','Health','-MaintenanceWindowConfirmed')
    $restartRequired = [bool]$health.RestartRequired
    $repairRecommended = [bool]$health.RepairRecommended
    $healthReady = [bool]$health.HealthReady
    if ($restartRequired) { throw 'RESTART REQUIRED: restart Windows before cleanup or backup.' }
    if ($repairRecommended -or -not $healthReady) { throw 'WINDOWS REPAIR RECOMMENDED: open the health report and run Repair Windows before cleanup.' }

    [void](Invoke-RunStep -Name '03-WinGetPreview' -Arguments @('-Mode','Updates'))
    [void](Invoke-RunStep -Name '04-CleanupPreview' -Arguments @('-Mode','Clean','-MinimumAgeDays',[string]$MinimumAgeDays,'-WhatIf'))

    $cleanupArguments = @('-Mode','Clean','-MinimumAgeDays',[string]$MinimumAgeDays,'-MaintenanceWindowConfirmed')
    if ($EmptyRecycleBin) { $cleanupArguments += '-EmptyRecycleBin' }
    if ($ClearDeliveryCache) { $cleanupArguments += '-ClearDeliveryCache' }
    [void](Invoke-RunStep -Name '05-Cleanup' -Arguments $cleanupArguments)

    $finalAudit = Invoke-RunStep -Name '06-FinalReview' -Arguments @('-Mode','Audit')
    if ($finalAudit.Restart.Pending -or @($finalAudit.Restart.Unknown).Count -gt 0) {
        $restartRequired = $true
        throw 'RESTART REQUIRED: restart Windows before starting the backup.'
    }
    Write-RunLog 'Guided run completed. Review the combined summary before starting the backup.'
} catch {
    Write-RunLog "STOP $($_.Exception.Message)"
    $failure = $_.Exception.Message
} finally {
    $result = [pscustomobject]@{
        Finished = (Get-Date).ToString('o')
        Completed = [string]::IsNullOrEmpty($failure)
        RestartRequired = $restartRequired
        RepairRecommended = $repairRecommended
        HealthReady = $healthReady
        Message = if ([string]::IsNullOrEmpty($failure)) { 'Guided pre-backup run completed.' } else { $failure }
        Steps = $steps
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    $result.Steps | Export-Csv -LiteralPath (Join-Path -Path $ReportDirectory -ChildPath 'guided-steps.csv') -NoTypeInformation -Encoding UTF8
}
if (-not $result.Completed) { Write-Error -Message $result.Message -ErrorAction Continue; exit 1 }
Write-Output 'OK - guided pre-backup run completed. Review guided-run.log and all step reports before starting the backup.'
exit 0
