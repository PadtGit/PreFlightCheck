#Requires -Version 5.1
<#
.SYNOPSIS
    Conservative Windows 11 pre-backup maintenance and diagnostic reporting.
.DESCRIPTION
    Defaults to Audit. Clean removes only aged files from known temporary folders.
    Health runs diagnostics; repairs and component cleanup require separate switches.
    SystemRepair runs the WinUtil-style disk, protected-file and image repair sequence.
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
    [ValidateSet('Audit','Clean','Health','SystemRepair','Updates')][string]$Mode = 'Audit',
    [ValidateRange(7,365)][int]$MinimumAgeDays = 14,
    [switch]$EmptyRecycleBin,
    [switch]$ClearDeliveryCache,
    [switch]$RepairWindows,
    [switch]$ComponentCleanup,
    [switch]$Uninstall,
    [switch]$UpgradeAll,
    [switch]$ShowInstalled,
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
if (($Uninstall -or $UpgradeAll -or $ShowInstalled) -and $Mode -ne 'Updates') { throw 'Winget action switches require Updates mode.' }
if (($ApplicationId.Count -gt 0 -or $OpenUpdatePages) -and $Mode -ne 'Updates') { throw 'Update switches require Updates mode.' }
if (($Uninstall -or $ApplicationId.Count -gt 0) -and $Mode -eq 'Updates' -and -not $MaintenanceWindowConfirmed -and -not $WhatIfPreference) { throw 'Selected application changes require -MaintenanceWindowConfirmed.' }
if ($Uninstall -and $ApplicationId.Count -eq 0) { throw 'Uninstall requires at least one exact application ID.' }
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
    Write-Information -MessageData "[RUNNING] ${Name}: In progress..." -InformationAction Continue
    # Forward native output on the information stream so callers still receive
    # only the numeric exit code on the success stream. PowerShell also splits
    # carriage-return progress redraws into records for live dashboard updates.
    & $FilePath @Arguments 2>&1 | ForEach-Object {
        # SFC can write UTF-16 output that Windows PowerShell exposes with NUL
        # padding. Remove it so both live text and saved health conclusions read correctly.
        $line = ([string]$_).Replace([string][char]0, '')
        Write-Information -MessageData $line -InformationAction Continue
        $line
    } | Out-File -LiteralPath $log -Encoding utf8 -WhatIf:$false
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
        RepairRecommended = $false; RestartRequired = $false; RestartAfter = $null; HealthReady = $false
    }
    $identity = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $admin = $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $maintenance = $Mode -in @('Clean','Health','SystemRepair') -or $ApplicationId.Count -gt 0 -or $Uninstall -or $UpgradeAll
    Write-Information -MessageData '[RUNNING] System: Reading Windows and BIOS information...' -InformationAction Continue
    $os = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $bios = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
    $report.System = [pscustomobject]@{ Model = $bios.SystemProductName; Manufacturer = $bios.SystemManufacturer; BIOS = $bios.BIOSVersion; BIOSDate = $bios.BIOSReleaseDate; WindowsVersion = $os.DisplayVersion; Build = "$($os.CurrentBuild).$($os.UBR)"; Elevated = $admin; PowerShell = $PSVersionTable.PSVersion.ToString() }
    Add-Result -Step System -Status Observed -Detail ($report.System | ConvertTo-Json -Compress)
    Write-Information -MessageData '[RUNNING] Restart: Checking pending restart markers...' -InformationAction Continue
    $report.Restart = Get-PendingRestartState
    if ($report.Restart.Pending -or $report.Restart.Unknown.Count -gt 0) {
        Add-Result -Step Restart -Status Review -Detail ($report.Restart | ConvertTo-Json -Compress)
    } else { Add-Result -Step Restart -Status Observed -Detail 'No common restart markers found; this does not prove Windows Update is idle.' }
    Write-Information -MessageData '[RUNNING] Power: Checking AC power...' -InformationAction Continue
    try { $report.Power = Get-AcPowerState } catch { Add-Result -Step Power -Status Failed -Detail $_.Exception.Message }
    Write-Information -MessageData '[RUNNING] Storage: Reading disk and volume health...' -InformationAction Continue
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
        Write-Information -MessageData '[RUNNING] Events: Reviewing recent system and application errors...' -InformationAction Continue
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = @('System','Application'); Level = @(1,2); StartTime = (Get-Date).AddDays(-3) } -MaxEvents 100 -ErrorAction Stop)
        $events | Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message | Export-Csv -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'events.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false
        Add-Result -Step Events -Status Review -Detail "$($events.Count) recent error/critical events captured (maximum 100); occurrence alone is not proof of corruption."
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { Add-Result -Step Events -Status Observed -Detail 'No matching recent events.' }
        else { Add-Result -Step Events -Status Failed -Detail $_.Exception.Message }
    }
    try {
        Write-Information -MessageData '[RUNNING] Defender: Reading antivirus protection status...' -InformationAction Continue
        Get-MpComputerStatus | Select-Object AMRunningMode,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanAge | ConvertTo-Json | Out-File -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'defender.json') -Encoding utf8 -WhatIf:$false
        Add-Result -Step Defender -Status Observed -Detail 'Status recorded; no malware-free certification. Passive mode may reflect another antivirus product.'
    } catch { Add-Result -Step Defender -Status Review -Detail $_.Exception.Message }

    # These two known locations are the only automatic file-cleanup roots.
    $tempRoots = @((Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Temp'), (Join-Path -Path $env:SystemRoot -ChildPath 'Temp')) | Select-Object -Unique
    foreach ($root in $tempRoots) {
        try {
            $inventoryWarnings = @()
            Write-Information -MessageData "[RUNNING] TempInventory: Scanning $root for files older than $MinimumAgeDays days..." -InformationAction Continue
            $report.TempCandidates += @(Get-AgedTemporaryFile -Root $root -MinimumAgeDays $MinimumAgeDays -WarningVariable inventoryWarnings)
            if ($inventoryWarnings.Count -gt 0) { Add-Result -Step TempInventory -Status Review -Detail ($inventoryWarnings -join [Environment]::NewLine) }
        }
        catch { Add-Result -Step TempInventory -Status Review -Detail "${root}: $($_.Exception.Message)" }
    }
    Add-Result -Step TempInventory -Status Observed -Detail "$($report.TempCandidates.Count) aged temporary file candidates. Age reduces risk but does not prove a file is disposable."
    if ($maintenance -and -not $WhatIfPreference) {
        if ($Mode -in @('Clean','Health','SystemRepair') -and -not $admin) { throw 'Actual cleanup and health checks require Run as administrator.' }
        if (-not $MaintenanceWindowConfirmed) { throw 'Save work, close apps, verify recovery copy and no active backup/update; then use -MaintenanceWindowConfirmed.' }
        if ($null -eq $report.Power -or -not $report.Power.Known -or -not $report.Power.OnAC) { throw 'Actual maintenance requires confirmed AC power.' }
        if ($Mode -ne 'SystemRepair' -and ($report.Restart.Pending -or $report.Restart.Unknown.Count -gt 0)) { throw 'Review pending/unknown restart state before maintenance. This does not prohibit a protective backup.' }
        if ($report.Disks.Count -eq 0 -or @($report.Disks | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count -gt 0) { throw 'Disk health is unavailable or abnormal; protect data before maintenance.' }
        if ($report.VolumesBefore.Count -eq 0 -or @($report.VolumesBefore | Where-Object { $_.DriveType -eq 'Fixed' -and $_.HealthStatus -ne 'Healthy' }).Count -gt 0) { throw 'Volume health is unavailable or abnormal; protect data before maintenance.' }
    }
    if ($Mode -eq 'Clean') {
        foreach ($root in $tempRoots) {
            if ($PSCmdlet.ShouldProcess($root, "Remove only regular temporary files older than $MinimumAgeDays days")) {
                $cleanupWarnings = @()
                Write-Information -MessageData "[RUNNING] TempCleanup: Cleaning eligible files in $root..." -InformationAction Continue
                $cleanupResult = Remove-AgedTemporaryFile -Root $root -MinimumAgeDays $MinimumAgeDays -Confirm:$false -WarningVariable cleanupWarnings
                $report.Cleanup += $cleanupResult
                $cleanupStatus = 'Completed'
                if ($cleanupResult.Failed -gt 0 -or $cleanupWarnings.Count -gt 0) { $cleanupStatus = 'Review' }
                Add-Result -Step TempCleanup -Status $cleanupStatus -Detail ($cleanupResult | ConvertTo-Json -Compress)
                if ($cleanupWarnings.Count -gt 0) { Add-Result -Step TempCleanupWarnings -Status Review -Detail ($cleanupWarnings -join [Environment]::NewLine) }
            }
        }
        if ($EmptyRecycleBin -and $PSCmdlet.ShouldProcess('Current user Recycle Bin on all drives', 'Permanently empty reviewed contents')) {
            Write-Information -MessageData '[RUNNING] RecycleBin: Emptying the reviewed Recycle Bin...' -InformationAction Continue
            Clear-RecycleBin -Force -ErrorAction Stop
            Add-Result -Step RecycleBin -Status Completed -Detail 'Current user Recycle Bin emptied.'
        }
        if ($ClearDeliveryCache -and $PSCmdlet.ShouldProcess('Delivery Optimization cache', 'Delete cached delivery files')) {
            Write-Information -MessageData '[RUNNING] DeliveryCache: Clearing Delivery Optimization cache...' -InformationAction Continue
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Add-Result -Step DeliveryCache -Status Completed -Detail 'Delivery Optimization cache cleared.'
        }
    }
    if ($Mode -eq 'SystemRepair') {
        $report.HealthReady = $false
        if ($PSCmdlet.ShouldProcess('Windows system', 'Run WinUtil-style system corruption scan and repair')) {
            $diskCode = Invoke-LoggedProgram -Name SystemRepair-CHKDSK -FilePath "$env:SystemRoot\System32\cmd.exe" -Arguments @('/c','chkdsk /scan /perf') -AcceptedCodes @(0,1,2)
            if ($diskCode -in @(1,2)) {
                Add-Result -Step SystemRepair-CHKDSK -Status Review -Detail "CHKDSK returned $diskCode. Review the saved disk log before further maintenance."
            }
            [void](Invoke-LoggedProgram -Name SystemRepair-SFC -FilePath "$env:SystemRoot\System32\cmd.exe" -Arguments @('/c','sfc /scannow'))
            $repairCode = Invoke-LoggedProgram -Name SystemRepair-DISM -FilePath "$env:SystemRoot\System32\cmd.exe" -Arguments @('/c','dism /online /cleanup-image /restorehealth') -AcceptedCodes @(0,3010)
            if ($repairCode -eq 3010) {
                $report.RestartRequired = $true
                Add-Result -Step SystemRepair -Status Review -Detail 'RESTART REQUIRED: DISM repaired the image and requested a restart.'
            } else {
                Add-Result -Step SystemRepair -Status Completed -Detail 'WinUtil-style system corruption scan completed.'
            }
            Write-Information -MessageData '[RUNNING] RestartAfterSystemRepair: Checking restart state after repair...' -InformationAction Continue
            $report.RestartAfter = Get-PendingRestartState
            if ($report.RestartAfter.Pending -or $report.RestartAfter.Unknown.Count -gt 0) {
                $report.RestartRequired = $true
                Add-Result -Step RestartAfterSystemRepair -Status Review -Detail 'RESTART REQUIRED: Windows reports a pending or unknown restart state after repair.'
            }
            Add-Result -Step HealthGate -Status Review -Detail 'Cleanup remains locked. Review the repair logs, restart if requested, then explicitly run Windows health checks before cleanup.'
        }
    }
    if ($Mode -eq 'Health') {
        $report.HealthReady = $false
        $analysisCompleted = $false
        $integrityCompleted = $false
        $healthVolumes = @($report.VolumesBefore | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })
        $volumeChecksCompleted = $healthVolumes.Count -gt 0
        if (-not $volumeChecksCompleted) {
            Add-Result -Step FileSystemChecks -Status Review -Detail 'No eligible fixed NTFS volume with a drive letter was available to check. Review the storage inventory before cleanup.'
        }
        if ($PSCmdlet.ShouldProcess('Windows component store', 'Analyze space usage')) {
            [void](Invoke-LoggedProgram -Name ComponentAnalysis -FilePath "$env:SystemRoot\System32\DISM.exe" -Arguments @('/Online','/English','/Cleanup-Image','/AnalyzeComponentStore'))
            $analysisCompleted = $true
        }
        $healthOperation = '/ScanHealth'
        $sfcOperation = '/verifyonly'
        if ($RepairWindows) { $healthOperation = '/RestoreHealth'; $sfcOperation = '/scannow' }
        $componentHealthy = $false
        if ($PSCmdlet.ShouldProcess('Windows', "DISM $healthOperation then SFC $sfcOperation")) {
            $healthCode = Invoke-LoggedProgram -Name DISM-Health -FilePath "$env:SystemRoot\System32\DISM.exe" -Arguments @('/Online','/English','/Cleanup-Image',$healthOperation) -AcceptedCodes @(0,3010)
            if ($healthCode -eq 3010) {
                $report.RestartRequired = $true
                throw 'RESTART REQUIRED: DISM requests a restart. Restart Windows before cleanup or backup.'
            }
            $healthText = Get-Content -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'DISM-Health.txt') -Raw
            $componentHealthy = $healthText -match 'No component store corruption detected\.' -or ($RepairWindows -and $healthText -match 'The restore operation completed successfully\.')
            [void](Invoke-LoggedProgram -Name SFC -FilePath "$env:SystemRoot\System32\sfc.exe" -Arguments @($sfcOperation))
            $sfcText = Get-Content -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'SFC.txt') -Raw
            $integrityCompleted = $true
            $sfcHealthy = $sfcText -match 'Windows Resource Protection did not find any integrity violations\.'
            if ($RepairWindows) { $sfcHealthy = $sfcHealthy -or $sfcText -match 'Windows Resource Protection found corrupt files and successfully repaired them\.' }
            if (-not $componentHealthy -or -not $sfcHealthy) {
                $report.RepairRecommended = $true
                Add-Result -Step Integrity -Status Review -Detail 'Windows health output needs repair or manual review. Open the DISM and SFC logs before cleanup.'
            } else {
                Add-Result -Step Integrity -Status Observed -Detail 'DISM and SFC reported a healthy or successfully repaired Windows image. Native results cannot certify every application.'
            }
        }
        foreach ($volume in $healthVolumes) {
            if ($PSCmdlet.ShouldProcess("$($volume.DriveLetter):", 'Online file-system scan; defer fixes')) {
                $diskCode = Invoke-LoggedProgram -Name "CHKDSK-$($volume.DriveLetter)" -FilePath "$env:SystemRoot\System32\chkdsk.exe" -Arguments @("$($volume.DriveLetter):",'/scan') -AcceptedCodes @(0,1,2)
                if ($diskCode -in @(1,2)) {
                    Add-Result -Step "CHKDSK-$($volume.DriveLetter)" -Status Review -Detail "CHKDSK returned $diskCode. Review the saved disk log before cleanup."
                }
            } else { $volumeChecksCompleted = $false }
        }
        if ($ComponentCleanup -and $PSCmdlet.ShouldProcess('Windows component store', 'Remove superseded components; bypass normal cleanup grace period')) {
            if (-not $componentHealthy) { throw 'Component cleanup requires an explicit healthy or repaired DISM conclusion in this run. Review the log.' }
            Write-Information -MessageData '[RUNNING] RestartBeforeCleanup: Checking restart state...' -InformationAction Continue
            $restartBeforeCleanup = Get-PendingRestartState
            if ($restartBeforeCleanup.Pending -or $restartBeforeCleanup.Unknown.Count -gt 0) { throw 'Restart state changed during health work. Review before component cleanup.' }
            $cleanupCode = Invoke-LoggedProgram -Name ComponentCleanup -FilePath "$env:SystemRoot\System32\DISM.exe" -Arguments @('/Online','/English','/Cleanup-Image','/StartComponentCleanup') -AcceptedCodes @(0,3010)
            if ($cleanupCode -eq 3010) {
                $report.RestartRequired = $true
                Add-Result -Step ComponentCleanup -Status Review -Detail 'RESTART REQUIRED: restart Windows before cleanup or backup.'
            }
        }
        Write-Information -MessageData '[RUNNING] RestartAfterHealth: Checking restart state after health checks...' -InformationAction Continue
        $report.RestartAfter = Get-PendingRestartState
        if ($report.RestartAfter.Pending -or $report.RestartAfter.Unknown.Count -gt 0) {
            $report.RestartRequired = $true
            Add-Result -Step RestartAfterHealth -Status Review -Detail 'RESTART REQUIRED: Windows reports a pending or unknown restart state. Restart before cleanup or backup.'
        }
        $report.HealthReady = -not $WhatIfPreference -and -not $RepairWindows -and
            $analysisCompleted -and $integrityCompleted -and $volumeChecksCompleted -and
            -not $report.RepairRecommended -and -not $report.RestartRequired -and
            @($report.Results | Where-Object { $_.Status -in @('Review','Failed') }).Count -eq 0
        if ($report.HealthReady) { Add-Result -Step HealthGate -Status Completed -Detail 'Health checks passed the cleanup gate for this session.' }
        elseif ($RepairWindows) { Add-Result -Step HealthGate -Status Review -Detail 'Cleanup remains locked. Review the repair logs, restart if requested, then explicitly run Windows health checks before cleanup.' }
    }
    if ($Mode -eq 'Updates') {
        Write-Information -MessageData '[RUNNING] SoftwareInventory: Reading installed application information...' -InformationAction Continue
        $uninstallRoots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        foreach ($registryRoot in $uninstallRoots) {
            if (Test-Path -LiteralPath $registryRoot) {
                foreach ($key in @(Get-ChildItem -LiteralPath $registryRoot)) {
                    $entry = Get-ItemProperty -LiteralPath $key.PSPath
                    if ($entry.PSObject.Properties['DisplayName']) { $report.Software += $entry | Select-Object DisplayName,DisplayVersion,Publisher }
                }
            }
        }
        # Resolve only the App Installer alias in the user's WindowsApps directory.
        # Never execute a PATH-resolved or otherwise user-supplied executable while elevated.
        $wingetPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\WindowsApps\winget.exe'
        $wingetTrusted = $false
        Write-Information -MessageData '[RUNNING] WinGet: Checking availability and publisher signature...' -InformationAction Continue
        try {
            $wingetItem = Get-Item -LiteralPath $wingetPath -Force -ErrorAction Stop
            $windowsAppsRoot = [IO.Path]::GetFullPath((Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\WindowsApps')).TrimEnd('\') + '\'
            $resolvedWinget = [IO.Path]::GetFullPath($wingetItem.FullName)
            $signature = Get-AuthenticodeSignature -LiteralPath $resolvedWinget -ErrorAction Stop
            $wingetTrusted = $resolvedWinget.StartsWith($windowsAppsRoot, [StringComparison]::OrdinalIgnoreCase) -and
                $signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match '(?i)Microsoft'
        } catch { Add-Result -Step AppUpdates -Status Review -Detail "WinGet trust validation failed: $($_.Exception.Message)" }
        if ($wingetTrusted) {
            # No automatic source/package agreement acceptance; first-run prompts fail visibly.
            if (-not $ShowInstalled) {
                try {
                    $updateExit = Invoke-LoggedProgram -Name AvailableAppUpdates -FilePath $wingetPath -Arguments @('upgrade','--disable-interactivity') -AcceptedCodes @(0,-1978335189)
                    $availableOutput = Get-Content -LiteralPath (Join-Path -Path $runDirectory -ChildPath 'AvailableAppUpdates.txt') -Raw -ErrorAction Stop
                    if ([string]::IsNullOrWhiteSpace($availableOutput)) {
                        Add-Result -Step AvailableAppUpdatesOutput -Status Review -Detail 'WinGet returned no available-update output. Review AvailableAppUpdates.txt.'
                    } else {
                        Add-Result -Step AvailableAppUpdatesOutput -Status Observed -Detail $availableOutput.Trim()
                    }
                    if ($updateExit -ne 0) { Add-Result -Step AppUpdates -Status Observed -Detail 'WinGet reports no applicable upgrades.' }
                } catch { Add-Result -Step AppUpdates -Status Review -Detail $_.Exception.Message }
            }
            if ($ShowInstalled -and $PSCmdlet.ShouldProcess('Installed applications', 'List installed WinGet applications')) {
                [void](Invoke-LoggedProgram -Name InstalledApps -FilePath $wingetPath -Arguments @('list','--disable-interactivity'))
                $installedOutputPath = Join-Path -Path $runDirectory -ChildPath 'InstalledApps.txt'
                $installedOutput = Get-Content -LiteralPath $installedOutputPath -Raw -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($installedOutput)) {
                    Add-Result -Step InstalledAppsOutput -Status Review -Detail 'WinGet returned no installed-application output. Review InstalledApps.txt.'
                } else {
                    Add-Result -Step InstalledAppsOutput -Status Observed -Detail $installedOutput.Trim()
                }
            }
            if ($UpgradeAll -and $PSCmdlet.ShouldProcess('All supported applications', 'Upgrade all WinGet applications')) {
                [void](Invoke-LoggedProgram -Name UpgradeAll -FilePath $wingetPath -Arguments @('upgrade','--all','--disable-interactivity'))
                Write-Information -MessageData '[RUNNING] RestartAfterUpgradeAll: Checking restart state after updates...' -InformationAction Continue
                $upgradeAllRestart = Get-PendingRestartState
                if ($upgradeAllRestart.Pending -or $upgradeAllRestart.Unknown.Count -gt 0) {
                    $report.RestartRequired = $true
                    Add-Result -Step RestartAfterUpgradeAll -Status Review -Detail 'RESTART REQUIRED: an upgrade-all operation left a pending or unknown restart state. Restart before cleanup or backup.'
                }
            }
            foreach ($id in $ApplicationId) {
                if ($PSCmdlet.ShouldProcess($id, $(if ($Uninstall) { 'Uninstall selected exact WinGet application' } else { 'Install or upgrade selected exact WinGet application' }))) {
                    $wingetAction = if ($Uninstall) { @('uninstall','--id',$id,'--exact','--disable-interactivity') } else { @('install','--id',$id,'--exact','--disable-interactivity') }
                    $actionName = if ($Uninstall) { 'Uninstall' } else { 'InstallUpgrade' }
                    [void](Invoke-LoggedProgram -Name "$actionName-$id" -FilePath $wingetPath -Arguments $wingetAction)
                    Write-Information -MessageData '[RUNNING] RestartAfterUpdate: Checking restart state after application changes...' -InformationAction Continue
                    $restartAfterUpdate = Get-PendingRestartState
                    if ($restartAfterUpdate.Pending -or $restartAfterUpdate.Unknown.Count -gt 0) {
                        $report.RestartRequired = $true
                        Add-Result -Step RestartAfterUpdate -Status Review -Detail 'RESTART REQUIRED: an application change left a pending or unknown restart state. Restart before cleanup or backup.'
                        throw 'An application update left a pending or unknown restart state. Review and restart before further maintenance.'
                    }
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
        Write-Information -MessageData '[RUNNING] FinalSpace: Measuring free space after the task...' -InformationAction Continue
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
        if ($report.RestartRequired -or $report.RepairRecommended -or @($report.Results | Where-Object { $_.Status -in @('Review','Failed') }).Count -gt 0) {
            $report.HealthReady = $false
        }
        Write-Information -MessageData '[RUNNING] Reports: Saving results and review findings...' -InformationAction Continue
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

