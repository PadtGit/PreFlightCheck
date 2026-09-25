#Requires -Version 7.0
<#
.SYNOPSIS
    Executes one validated dashboard request and saves a concise result.
.PARAMETER RequestPath
    JSON request created by Start-Maintenance.ps1.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Dashboard.Core.psm1') -Force -ErrorAction Stop

function Receive-ProcessOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$ConsolePath
    )

    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ConsolePath), '', $utf8)
    $outputBuilder = [Text.StringBuilder]::new()
    $errorBuilder = [Text.StringBuilder]::new()
    $outputComplete = $false
    $errorComplete = $false
    $outputTask = $Process.StandardOutput.ReadLineAsync()
    $errorTask = $Process.StandardError.ReadLineAsync()

    while (-not ($outputComplete -and $errorComplete)) {
        $receivedLine = $false
        if (-not $outputComplete -and $outputTask.IsCompleted) {
            $line = $outputTask.GetAwaiter().GetResult()
            if ($null -eq $line) {
                $outputComplete = $true
            } else {
                [IO.File]::AppendAllText($ConsolePath, $line + [Environment]::NewLine, $utf8)
                [void]$outputBuilder.AppendLine($line)
                $outputTask = $Process.StandardOutput.ReadLineAsync()
            }
            $receivedLine = $true
        }
        if (-not $errorComplete -and $errorTask.IsCompleted) {
            $line = $errorTask.GetAwaiter().GetResult()
            if ($null -eq $line) {
                $errorComplete = $true
            } else {
                [IO.File]::AppendAllText($ConsolePath, $line + [Environment]::NewLine, $utf8)
                [void]$errorBuilder.AppendLine($line)
                $errorTask = $Process.StandardError.ReadLineAsync()
            }
            $receivedLine = $true
        }
        if (-not $receivedLine) { Start-Sleep -Milliseconds 40 }
    }

    $Process.WaitForExit()
    return [pscustomobject]@{
        Output = $outputBuilder.ToString().TrimEnd()
        Errors = $errorBuilder.ToString().TrimEnd()
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requestFile = Get-Item -LiteralPath $RequestPath -ErrorAction Stop
$runDirectory = $requestFile.Directory.FullName
$root = $PSScriptRoot
$request = Get-Content -LiteralPath $requestFile.FullName -Raw | ConvertFrom-Json
$allowedTasks = @('PreBackupRun','Audit','UpdatePreview','UpdateInstall','UpdateUninstall','UpdateAll','InstalledApps','CleanPreview','Clean','HealthCheck','HealthRepair','SystemRepair','DellReview')
if ($request.Task -notin $allowedTasks) { throw 'Unknown dashboard task.' }
$windowsPowerShell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scriptPath = Join-Path -Path $root -ChildPath 'PreBackupMaintenance.ps1'
$arguments = @('-NoLogo','-NoProfile','-File',$scriptPath)
switch ($request.Task) {
    'PreBackupRun' {
        $scriptPath = Join-Path -Path $root -ChildPath 'Invoke-PreBackupRun.ps1'
        $arguments = @('-NoLogo','-NoProfile','-File',$scriptPath,'-ReportDirectory',(Join-Path -Path $runDirectory -ChildPath 'GuidedReport'),'-MinimumAgeDays',[string][int]$request.MinimumAgeDays,'-MaintenanceWindowConfirmed')
        if ($request.EmptyRecycleBin) { $arguments += '-EmptyRecycleBin' }
        if ($request.ClearDeliveryCache) { $arguments += '-ClearDeliveryCache' }
    }
    'Audit' { $arguments += @('-Mode','Audit') }
    'UpdatePreview' { $arguments += @('-Mode','Updates') }
    'UpdateInstall' {
        $ids = @($request.ApplicationId)
        if ($ids.Count -eq 0) { throw 'Select at least one exact application ID.' }
        foreach ($id in $ids) {
            if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "Invalid application ID: $id" }
            if ($id -match '^(Dell|Alienware)\.' -or $id -match '(BIOS|Firmware)') { throw 'Dell and firmware updates belong in the separate weekly review.' }
        }
        $arguments += @('-Mode','Updates','-MaintenanceWindowConfirmed','-ApplicationId') + $ids
    }
    'UpdateUninstall' {
        $ids = @($request.ApplicationId)
        if ($ids.Count -eq 0) { throw 'Select at least one exact application ID to uninstall.' }
        $arguments += @('-Mode','Updates','-Uninstall','-MaintenanceWindowConfirmed','-ApplicationId') + $ids
    }
    'UpdateAll' { $arguments += @('-Mode','Updates','-UpgradeAll','-MaintenanceWindowConfirmed') }
    'InstalledApps' { $arguments += @('-Mode','Updates','-ShowInstalled') }
    'CleanPreview' { $arguments += @('-Mode','Clean','-MinimumAgeDays',[string][int]$request.MinimumAgeDays,'-WhatIf') }
    'Clean' {
        $arguments += @('-Mode','Clean','-MinimumAgeDays',[string][int]$request.MinimumAgeDays,'-MaintenanceWindowConfirmed')
        if ($request.EmptyRecycleBin) { $arguments += '-EmptyRecycleBin' }
        if ($request.ClearDeliveryCache) { $arguments += '-ClearDeliveryCache' }
    }
    'HealthCheck' { $arguments += @('-Mode','Health','-MaintenanceWindowConfirmed') }
    'HealthRepair' {
        $arguments += @('-Mode','Health','-RepairWindows','-MaintenanceWindowConfirmed')
        if ($request.ComponentCleanup) { $arguments += '-ComponentCleanup' }
    }
    'SystemRepair' { $arguments += @('-Mode','SystemRepair','-MaintenanceWindowConfirmed') }
    'DellReview' {
        $scriptPath = Join-Path -Path $root -ChildPath 'Weekly-DellReview.ps1'
        $arguments = @('-NoLogo','-NoProfile','-File',$scriptPath)
    }
}
$reportRoot = Join-Path -Path $runDirectory -ChildPath 'Report'
if ($request.Task -notin @('DellReview','PreBackupRun')) { $arguments += @('-ReportDirectory',$reportRoot) }
$start = [Diagnostics.ProcessStartInfo]::new($windowsPowerShell)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($argument in $arguments) { [void]$start.ArgumentList.Add([string]$argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
[void]$process.Start()
$consolePath = Join-Path -Path $runDirectory -ChildPath 'console.txt'
[void](Receive-ProcessOutput -Process $process -ConsolePath $consolePath)
$exitCode = $process.ExitCode
$process.Dispose()
$restartRequired = $false
$repairRecommended = $false
$healthReady = $false
$reviewFindings = @()
$machineReport = Get-ChildItem -LiteralPath $runDirectory -Filter report.json -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($machineReport) {
    $machineResult = Get-Content -LiteralPath $machineReport.FullName -Raw | ConvertFrom-Json
    if ($machineResult.PSObject.Properties['RestartRequired']) { $restartRequired = [bool]$machineResult.RestartRequired }
    if ($machineResult.PSObject.Properties['RepairRecommended']) { $repairRecommended = [bool]$machineResult.RepairRecommended }
    if ($machineResult.PSObject.Properties['HealthReady']) { $healthReady = [bool]$machineResult.HealthReady }
}
$guidedResultPath = Join-Path -Path $runDirectory -ChildPath 'GuidedReport\guided-result.json'
if (Test-Path -LiteralPath $guidedResultPath) {
    $guidedResult = Get-Content -LiteralPath $guidedResultPath -Raw | ConvertFrom-Json
    $restartRequired = [bool]$guidedResult.RestartRequired
    $repairRecommended = [bool]$guidedResult.RepairRecommended
    $healthReady = [bool]$guidedResult.HealthReady
    $reviewFindings = @($guidedResult.ReviewFindings)
}
$finishedAt = [datetime]::Now
$presentation = Get-GuiResultPresentation -ExitCode $exitCode -RestartRequired $restartRequired -RepairRecommended $repairRecommended -ReviewFindingCount $reviewFindings.Count
$summary = Format-GuiTaskSummary -Presentation $presentation -Task $request.Task -Finished $finishedAt -ReviewFindings $reviewFindings -RunDirectory $runDirectory -ConsolePath $consolePath
$summary | Set-Content -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'summary.txt') -Encoding utf8
$finished = [ordered]@{ ExitCode = $exitCode; Task = $request.Task; Finished = $finishedAt.ToString('o'); DisplayState = $presentation.State; StatusLabel = $presentation.StatusLabel; RestartRequired = $restartRequired; RepairRecommended = $repairRecommended; HealthReady = $healthReady; ReviewRequired = ($exitCode -eq 2 -or $reviewFindings.Count -gt 0); ReviewFindings = $reviewFindings; Console = $consolePath; Results = $runDirectory }
$finished | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'finished.json') -Encoding utf8
$sessionDirectory = $requestFile.Directory.Parent.FullName
$sessionLog = Join-Path -Path $sessionDirectory -ChildPath 'session.log'
@('', ('=' * 72), "Task: $($request.Task)", "Finished: $($finished.Finished)", "Exit code: $exitCode", "Restart required: $restartRequired", "Repair recommended: $repairRecommended", "Results: $runDirectory", '', $summary) | Add-Content -LiteralPath $sessionLog -Encoding UTF8
exit $exitCode
