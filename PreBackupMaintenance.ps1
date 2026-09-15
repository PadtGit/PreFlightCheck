#Requires -Version 5.1
<#
.SYNOPSIS
    Conservative Windows 11 pre-backup maintenance and diagnostic reporting.
.DESCRIPTION
    Defaults to Audit. Clean removes only aged files from known temporary folders.
    Health runs diagnostics; repairs and component cleanup require separate switches.
    Updates inventories software and offers supported update entry points.
    Firmware installation is deliberately a separate attended maintenance operation.
    No automatic reboot, snapshot deletion, update cache reset or network reset.
    Reports describe observations, not a guarantee of system or backup integrity.
.PARAMETER Mode
    Audit, Clean, Health or Updates. Audit makes no maintenance changes.
.PARAMETER MinimumAgeDays
    Both creation and modification dates must be older than this limit (default 14).
.PARAMETER EmptyRecycleBin
    Explicitly empty the executing user's Recycle Bin in Clean mode.
.PARAMETER ClearDeliveryCache
    Explicitly clear the Delivery Optimization cache in Clean mode.
.PARAMETER RepairWindows
    Health mode only: DISM repair followed by SFC repair instead of verification.
.PARAMETER ComponentCleanup
    Health mode only: remove superseded components after DISM succeeds.
.PARAMETER ApplicationId
    Updates mode only: exact WinGet IDs selected by the operator for installation.
.PARAMETER MaintenanceWindowConfirmed
    Required for actual Clean, Health or selected application updates: work saved,
    no backup or update installation in progress, and a recovery copy is available.
.PARAMETER OpenUpdatePages
    In Updates mode, open Windows Update and Microsoft Store. Dell is separate.
.PARAMETER ReportDirectory
    Destination for uniquely named logs, inventory and machine-readable results.
.EXAMPLE
    .\PreBackupMaintenance.ps1
.EXAMPLE
    .\PreBackupMaintenance.ps1 -Mode Clean -WhatIf
.EXAMPLE
    .\PreBackupMaintenance.ps1 -Mode Clean -MaintenanceWindowConfirmed
.EXAMPLE
    .\PreBackupMaintenance.ps1 -Mode Health -RepairWindows -MaintenanceWindowConfirmed
.EXAMPLE
    .\PreBackupMaintenance.ps1 -Mode Updates -OpenUpdatePages
.NOTES
    Use an elevated Windows PowerShell 5.1 session for full Windows-module support.
    Exit 0 = routine completed; 1 = failures or unavailable essential checks;
    2 = warnings/review needed. Never use these codes as an automatic backup veto.
    WhatIf still creates reports and performs read-only checks.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Audit','Clean','Health','Updates')][string]$Mode = 'Audit',
    [ValidateRange(7,365)][int]$MinimumAgeDays = 14,
    [switch]$EmptyRecycleBin,
    [switch]$ClearDeliveryCache,
    [switch]$RepairWindows,
    [switch]$ComponentCleanup,
    [string[]]$ApplicationId = @(),
    [switch]$MaintenanceWindowConfirmed,
    [switch]$OpenUpdatePages,
    [string]$ReportDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'Reports')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Maintenance.Core.psm1') -Force
if (($EmptyRecycleBin -or $ClearDeliveryCache) -and $Mode -ne 'Clean') { throw 'Cleanup switches require Clean mode.' }
if (($RepairWindows -or $ComponentCleanup) -and $Mode -ne 'Health') { throw 'Repair switches require Health mode.' }
if (($ApplicationId.Count -gt 0 -or $OpenUpdatePages) -and $Mode -ne 'Updates') { throw 'Update switches require Updates mode.' }
foreach ($id in $ApplicationId) {
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "Invalid exact application ID: $id" }
    if ($id -match '^(Dell|Alienware)\.' -or $id -match '(BIOS|Firmware)') { throw 'Manage Dell and firmware updates separately using Weekly-DellReview.ps1.' }
}

# Only one instance of this routine per logged-in Windows session.
$mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false,'Local\BobPreBackupMaintenance'
$locked = $false
$report = $null
$runDirectory = $null
function Add-Result {
    [CmdletBinding()]
    param([string]$Step, [ValidateSet('Observed','Completed','Review','Skipped','Failed')][string]$Status, [string]$Detail)
    $report.Results.Add([pscustomobject]@{ Time = (Get-Date).ToString('o'); Step = $Step; Status = $Status; Detail = $Detail })
    Write-Information -MessageData "[$Status] ${Step}: $Detail" -InformationAction Continue
}
function Invoke-LoggedProgram {
    [CmdletBinding()]
    param([string]$Name, [string]$FilePath, [string[]]$Arguments, [int[]]$AcceptedCodes = @(0))
    $log = Join-Path -Path $runDirectory -ChildPath ($Name + '.txt')
    & $FilePath @Arguments 2>&1 | Out-File -LiteralPath $log -Encoding utf8 -WhatIf:$false
    $code = $LASTEXITCODE
    if ($code -notin $AcceptedCodes) { throw "$Name returned $code. Review $log" }
    Add-Result -Step $Name -Status Observed -Detail "Exit $code. Full output: $log"
    return $code
}

try {
    try { $locked = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another maintenance instance is running.' }
    $runDirectory = Join-Path -Path ([IO.Path]::GetFullPath($ReportDirectory)) -ChildPath ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    # Report creation is intentional even under WhatIf.
    [void][IO.Directory]::CreateDirectory($runDirectory)
    $report = [pscustomobject]@{
        Started = (Get-Date).ToString('o'); Mode = $Mode; WhatIf = [bool]$WhatIfPreference
        Results = [System.Collections.Generic.List[object]]::new()
        System = $null; Restart = $null; Power = $null; Disks = @(); VolumesBefore = @(); VolumesAfter = @()
        TempCandidates = @(); Cleanup = @(); Software = @(); SpaceChange = @()
    }
    $identity = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $admin = $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $maintenance = $Mode -in @('Clean','Health') -or $ApplicationId.Count -gt 0
    $os = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $bios = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
    $report.System = [pscustomobject]@{ Model = $bios.SystemProductName; Manufacturer = $bios.SystemManufacturer; BIOS = $bios.BIOSVersion; BIOSDate = $bios.BIOSReleaseDate; WindowsVersion = $os.DisplayVersion; Build = "$($os.CurrentBuild).$($os.UBR)"; Elevated = $admin; PowerShell = $PSVersionTable.PSVersion.ToString() }
    Add-Result -Step System -Status Observed -Detail ($report.System | ConvertTo-Json -Compress)
    $report.Restart = Get-PendingRestartState
    if ($report.Restart.Pending -or $report.Restart.Unknown.Count -gt 0) {
        Add-Result -Step Restart -Status Review -Detail ($report.Restart | ConvertTo-Json -Compress)
    } else { Add-Result -Step Restart -Status Observed -Detail 'No common restart markers found; this does not prove Windows Update is idle.' }
    try { $report.Power = Get-AcPowerState } catch { Add-Result -Step Power -Status Failed -Detail $_.Exception.Message }
    try {
        # Read-only storage modules create noisy alias messages when the caller uses WhatIf.
        $savedWhatIf = $WhatIfPreference
        try {
            $WhatIfPreference = $false
            $report.VolumesBefore = @(Get-Volume | Select-Object DriveLetter,UniqueId,FileSystem,DriveType,Size,SizeRemaining,HealthStatus)
            $report.Disks = @(Get-PhysicalDisk | Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus)
        } finally { $WhatIfPreference = $savedWhatIf }
        if ($report.Disks.Count -eq 0 -or $report.VolumesBefore.Count -eq 0) { throw 'Storage inventory returned no data.' }
        foreach ($disk in $report.Disks) {
            if ($disk.HealthStatus -ne 'Healthy') { Add-Result -Step Disk -Status Review -Detail "$($disk.FriendlyName): $($disk.HealthStatus). Protect data before maintenance." }
        }
        foreach ($volume in $report.VolumesBefore) {
            if ($volume.DriveType -eq 'Fixed' -and $volume.Size -gt 0 -and $volume.SizeRemaining -lt 1GB) {
                Add-Result -Step Space -Status Review -Detail "Volume $($volume.UniqueId) has $([math]::Round($volume.SizeRemaining/1MB)) MB free. Check backup-job requirements, including recovery partitions."
            }
        }
    } catch { Add-Result -Step Storage -Status Failed -Detail $_.Exception.Message }
    if ($admin) {
        try { [void](Invoke-LoggedProgram -Name VSS-Writers -FilePath "$env:SystemRoot\System32\vssadmin.exe" -Arguments @('list','writers')) }
        catch { Add-Result -Step VSS -Status Failed -Detail $_.Exception.Message }
        try { [void](Invoke-LoggedProgram -Name VSS-Storage -FilePath "$env:SystemRoot\System32\vssadmin.exe" -Arguments @('list','shadowstorage')) }
        catch { Add-Result -Step VSS -Status Failed -Detail $_.Exception.Message }
    } else { Add-Result -Step VSS -Status Review -Detail 'Run elevated to collect VSS diagnostics. Writer health has not been verified.' }
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = @('System','Application'); Level = @(1,2); StartTime = (Get-Date).AddDays(-3) } -MaxEvents 100 -ErrorAction Stop)
        $events | Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message | Export-Csv -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'events.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false
        Add-Result -Step Events -Status Review -Detail "$($events.Count) recent error/critical events captured (maximum 100); occurrence alone is not proof of corruption."
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { Add-Result -Step Events -Status Observed -Detail 'No matching recent events.' }
        else { Add-Result -Step Events -Status Failed -Detail $_.Exception.Message }
    }
    try {
        Get-MpComputerStatus | Select-Object AMRunningMode,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanAge | ConvertTo-Json | Out-File -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'defender.json') -Encoding utf8 -WhatIf:$false
        Add-Result -Step Defender -Status Observed -Detail 'Status recorded; no malware-free certification. Passive mode may reflect another antivirus product.'
    } catch { Add-Result -Step Defender -Status Review -Detail $_.Exception.Message }

    # These two known locations are the only automatic file-cleanup roots.
    $tempRoots = @((Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Temp'), (Join-Path -Path $env:SystemRoot -ChildPath 'Temp')) | Select-Object -Unique
    foreach ($root in $tempRoots) {
        try {
            $inventoryWarnings = @()
            $report.TempCandidates += @(Get-AgedTemporaryFile -Root $root -MinimumAgeDays $MinimumAgeDays -WarningVariable inventoryWarnings)
            if ($inventoryWarnings.Count -gt 0) { Add-Result -Step TempInventory -Status Review -Detail ($inventoryWarnings -join [Environment]::NewLine) }
        }
        catch { Add-Result -Step TempInventory -Status Review -Detail "${root}: $($_.Exception.Message)" }
    }
    Add-Result -Step TempInventory -Status Observed -Detail "$($report.TempCandidates.Count) aged temporary file candidates. Age reduces risk but does not prove a file is disposable."
    if ($maintenance -and -not $WhatIfPreference) {
        if ($Mode -in @('Clean','Health') -and -not $admin) { throw 'Actual cleanup and health checks require Run as administrator.' }
        if (-not $MaintenanceWindowConfirmed) { throw 'Save work, close apps, verify recovery copy and no active backup/update; then use -MaintenanceWindowConfirmed.' }
        if ($null -eq $report.Power -or -not $report.Power.Known -or -not $report.Power.OnAC) { throw 'Actual maintenance requires confirmed AC power.' }
        if ($report.Restart.Pending -or $report.Restart.Unknown.Count -gt 0) { throw 'Review pending/unknown restart state before maintenance. This does not prohibit a protective backup.' }
        if ($report.Disks.Count -eq 0 -or @($report.Disks | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count -gt 0) { throw 'Disk health is unavailable or abnormal; protect data before maintenance.' }
        if ($report.VolumesBefore.Count -eq 0 -or @($report.VolumesBefore | Where-Object { $_.DriveType -eq 'Fixed' -and $_.HealthStatus -ne 'Healthy' }).Count -gt 0) { throw 'Volume health is unavailable or abnormal; protect data before maintenance.' }
    }
    if ($Mode -eq 'Clean') {
        foreach ($root in $tempRoots) {
            if ($PSCmdlet.ShouldProcess($root, "Remove only regular temporary files older than $MinimumAgeDays days")) {
                $cleanupWarnings = @()
                $cleanupResult = Remove-AgedTemporaryFile -Root $root -MinimumAgeDays $MinimumAgeDays -Confirm:$false -WarningVariable cleanupWarnings
                $report.Cleanup += $cleanupResult
                $cleanupStatus = 'Completed'
                if ($cleanupResult.Failed -gt 0 -or $cleanupWarnings.Count -gt 0) { $cleanupStatus = 'Review' }
                Add-Result -Step TempCleanup -Status $cleanupStatus -Detail ($cleanupResult | ConvertTo-Json -Compress)
                if ($cleanupWarnings.Count -gt 0) { Add-Result -Step TempCleanupWarnings -Status Review -Detail ($cleanupWarnings -join [Environment]::NewLine) }
            }
        }
        if ($EmptyRecycleBin -and $PSCmdlet.ShouldProcess('Current user Recycle Bin on all drives', 'Permanently empty reviewed contents')) {
            Clear-RecycleBin -Force -ErrorAction Stop
            Add-Result -Step RecycleBin -Status Completed -Detail 'Current user Recycle Bin emptied.'
        }
        if ($ClearDeliveryCache -and $PSCmdlet.ShouldProcess('Delivery Optimization cache', 'Delete cached delivery files')) {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Add-Result -Step DeliveryCache -Status Completed -Detail 'Delivery Optimization cache cleared.'
        }
    }
    if ($Mode -eq 'Health') {
        if ($PSCmdlet.ShouldProcess('Windows component store', 'Analyze space usage')) {
            [void](Invoke-LoggedProgram -Name ComponentAnalysis -FilePath "$env:SystemRoot\System32\DISM.exe" -Arguments @('/Online','/English','/Cleanup-Image','/AnalyzeComponentStore'))
        }
        $healthOperation = '/ScanHealth'
        $sfcOperation = '/verifyonly'
        if ($RepairWindows) { $healthOperation = '/RestoreHealth'; $sfcOperation = '/scannow' }
        $componentHealthy = $false
        if ($PSCmdlet.ShouldProcess('Windows', "DISM $healthOperation then SFC $sfcOperation")) {
            $healthCode = Invoke-LoggedProgram -Name DISM-Health -FilePath "$env:SystemRoot\System32\DISM.exe" -Arguments @('/Online','/English','/Cleanup-Image',$healthOperation) -AcceptedCodes @(0,3010)
            if ($healthCode -eq 3010) { throw 'DISM requests a restart. Stop maintenance and review its log.' }
            $healthText = Get-Content -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'DISM-Health.txt') -Raw
            $componentHealthy = $healthText -match 'No component store corruption detected\.' -or ($RepairWindows -and $healthText -match 'The restore operation completed successfully\.')
            [void](Invoke-LoggedProgram -Name SFC -FilePath "$env:SystemRoot\System32\sfc.exe" -Arguments @($sfcOperation))
            Add-Result -Step Integrity -Status Review -Detail 'Read DISM and SFC conclusions. Native exit success alone does not certify all files or applications.'
        }
        foreach ($volume in @($report.VolumesBefore | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })) {
            if ($PSCmdlet.ShouldProcess("$($volume.DriveLetter):", 'Online file-system scan; defer fixes')) {
                [void](Invoke-LoggedProgram -Name "CHKDSK-$($volume.DriveLetter)" -FilePath "$env:SystemRoot\System32\chkdsk.exe" -Arguments @("$($volume.DriveLetter):",'/scan'))
            }
        }
        if ($ComponentCleanup -and $PSCmdlet.ShouldProcess('Windows component store', 'Remove superseded components; bypass normal cleanup grace period')) {
            if (-not $componentHealthy) { throw 'Component cleanup requires an explicit healthy or repaired DISM conclusion in this run. Review the log.' }
            $restartBeforeCleanup = Get-PendingRestartState
            if ($restartBeforeCleanup.Pending -or $restartBeforeCleanup.Unknown.Count -gt 0) { throw 'Restart state changed during health work. Review before component cleanup.' }
            $cleanupCode = Invoke-LoggedProgram -Name ComponentCleanup -FilePath "$env:SystemRoot\System32\DISM.exe" -Arguments @('/Online','/English','/Cleanup-Image','/StartComponentCleanup') -AcceptedCodes @(0,3010)
            if ($cleanupCode -eq 3010) { Add-Result -Step ComponentCleanup -Status Review -Detail 'Restart requested.' }
        }
    }
    if ($Mode -eq 'Updates') {
        $uninstallRoots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        foreach ($registryRoot in $uninstallRoots) {
            if (Test-Path -LiteralPath $registryRoot) {
                foreach ($key in @(Get-ChildItem -LiteralPath $registryRoot)) {
                    $entry = Get-ItemProperty -LiteralPath $key.PSPath
                    if ($entry.PSObject.Properties['DisplayName']) { $report.Software += $entry | Select-Object DisplayName,DisplayVersion,Publisher }
                }
            }
        }
        $wingetPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\WindowsApps\winget.exe'
        $wingetCommand = Get-Command -Name winget.exe -ErrorAction SilentlyContinue
        if ($wingetCommand) { $wingetPath = $wingetCommand.Source }
        if (Test-Path -LiteralPath $wingetPath) {
            # No automatic source/package agreement acceptance; first-run prompts fail visibly.
            try {
                $updateExit = Invoke-LoggedProgram -Name AvailableAppUpdates -FilePath $wingetPath -Arguments @('upgrade','--disable-interactivity') -AcceptedCodes @(0,-1978335189)
                if ($updateExit -ne 0) { Add-Result -Step AppUpdates -Status Observed -Detail 'WinGet reports no applicable upgrades.' }
            } catch { Add-Result -Step AppUpdates -Status Review -Detail $_.Exception.Message }
            foreach ($id in $ApplicationId) {
                if ($PSCmdlet.ShouldProcess($id, 'Install selected exact WinGet application update')) {
                    [void](Invoke-LoggedProgram -Name "Update-$id" -FilePath $wingetPath -Arguments @('upgrade','--id',$id,'--exact','--disable-interactivity'))
                    $restartAfterUpdate = Get-PendingRestartState
                    if ($restartAfterUpdate.Pending -or $restartAfterUpdate.Unknown.Count -gt 0) { throw 'An application update left a pending or unknown restart state. Review and restart before further maintenance.' }
                }
            }
        } else { Add-Result -Step AppUpdates -Status Review -Detail 'WinGet is unavailable. Use application updaters and Microsoft Store.' }
        if ($OpenUpdatePages -and $PSCmdlet.ShouldProcess('Windows Update and Microsoft Store', 'Open attended update interfaces')) {
            Start-Process -FilePath 'ms-settings:windowsupdate' -WindowStyle Normal
            Start-Process -FilePath 'ms-windows-store://downloadsandupdates' -WindowStyle Normal
        }
    }
} catch {
    if ($null -ne $report) { Add-Result -Step Routine -Status Failed -Detail $_.Exception.Message }
    else { Write-Error -Message $_.Exception.Message -ErrorAction Continue }
} finally {
    if ($null -ne $report) {
        try {
            $savedWhatIf = $WhatIfPreference
            try { $WhatIfPreference = $false; $report.VolumesAfter = @(Get-Volume | Select-Object DriveLetter,UniqueId,SizeRemaining) }
            finally { $WhatIfPreference = $savedWhatIf }
            foreach ($volume in $report.VolumesBefore) {
                $after = @($report.VolumesAfter | Where-Object { $_.UniqueId -eq $volume.UniqueId })
                if ($after.Count -eq 1) {
                    $report.SpaceChange += [pscustomobject]@{ Drive = $volume.DriveLetter; Volume = $volume.UniqueId; FreeBeforeGB = [math]::Round($volume.SizeRemaining/1GB,3); FreeAfterGB = [math]::Round($after[0].SizeRemaining/1GB,3); NetChangeGB = [math]::Round(($after[0].SizeRemaining-$volume.SizeRemaining)/1GB,3) }
                }
            }
        } catch { Add-Result -Step FinalSpace -Status Review -Detail $_.Exception.Message }
        $report | ConvertTo-Json -Depth 8 | Out-File -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'report.json') -Encoding utf8 -WhatIf:$false
        $report.Results | Export-Csv -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'steps.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false
        Write-Information -MessageData "Reports: $runDirectory. Review warnings and tool output; backup restorability is not certified." -InformationAction Continue
    }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if ($null -eq $report -or @($report.Results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { exit 1 }
if (@($report.Results | Where-Object { $_.Status -eq 'Review' }).Count -gt 0) { exit 2 }
exit 0
