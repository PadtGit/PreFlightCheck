#Requires -Version 7.0
<#
.SYNOPSIS
    Executes one validated dashboard request and saves a concise result.
.PARAMETER RequestPath
    JSON request created by Start-Maintenance.ps1.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requestFile = Get-Item -LiteralPath $RequestPath -ErrorAction Stop
$runDirectory = $requestFile.Directory.FullName
$root = $PSScriptRoot
$request = Get-Content -LiteralPath $requestFile.FullName -Raw | ConvertFrom-Json
$allowedTasks = @('Audit','UpdatePreview','UpdateInstall','CleanPreview','Clean','HealthCheck','HealthRepair','DellReview')
if ($request.Task -notin $allowedTasks) { throw 'Unknown dashboard task.' }
$windowsPowerShell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scriptPath = Join-Path -Path $root -ChildPath 'PreBackupMaintenance.ps1'
$arguments = @('-NoLogo','-NoProfile','-File',$scriptPath)
switch ($request.Task) {
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
    'DellReview' {
        $scriptPath = Join-Path -Path $root -ChildPath 'Weekly-DellReview.ps1'
        $arguments = @('-NoLogo','-NoProfile','-File',$scriptPath)
    }
}
$reportRoot = Join-Path -Path $runDirectory -ChildPath 'Report'
if ($request.Task -ne 'DellReview') { $arguments += @('-ReportDirectory',$reportRoot) }
$start = [Diagnostics.ProcessStartInfo]::new($windowsPowerShell)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($argument in $arguments) { [void]$start.ArgumentList.Add([string]$argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
[void]$process.Start()
$outputTask = $process.StandardOutput.ReadToEndAsync()
$errorTask = $process.StandardError.ReadToEndAsync()
$process.WaitForExit()
$output = $outputTask.Result
$errors = $errorTask.Result
$consolePath = Join-Path -Path $runDirectory -ChildPath 'console.txt'
($output + $errors).Trim() | Set-Content -LiteralPath $consolePath -Encoding utf8
$exitCode = $process.ExitCode
$process.Dispose()
$headline = switch ($exitCode) {
    0 { 'OK - task completed' }
    2 { 'REVIEW - open the saved report' }
    default { "NEEDS ATTENTION - exit code $exitCode" }
}
$summary = @($headline, "Task: $($request.Task)", "Finished: $([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))", '', ($output + $errors).Trim()) -join [Environment]::NewLine
$summary | Set-Content -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'summary.txt') -Encoding utf8
@{ ExitCode = $exitCode; Task = $request.Task; Finished = [datetime]::Now.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'finished.json') -Encoding utf8
exit $exitCode
