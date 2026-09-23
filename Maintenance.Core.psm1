#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-PendingRestartState {
    <#
    .SYNOPSIS
    Reads common Windows restart markers and reports inaccessible checks.
    #>
    [CmdletBinding()]
    param()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    $keys = @{
        ComponentServicing = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WindowsUpdate = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    }
    foreach ($name in $keys.Keys) {
        try {
            if (Test-Path -LiteralPath $keys[$name] -ErrorAction Stop) { $reasons.Add($name) }
        } catch { $unknown.Add("${name}: $($_.Exception.Message)") }
    }
    try {
        $manager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        $property = $manager.PSObject.Properties['PendingFileRenameOperations']
        if ($null -ne $property -and @($property.Value | Where-Object { $_ }).Count -gt 0) {
            $reasons.Add('PendingFileRenameOperations')
        }
    } catch { $unknown.Add($_.Exception.Message) }
    [pscustomobject]@{ Pending = $reasons.Count -gt 0; Reasons = @($reasons); Unknown = @($unknown) }
}

function Get-AcPowerState {
    <#
    .SYNOPSIS
    Reads Windows AC-line state without inferring it from battery charge status.
    #>
    [CmdletBinding()]
    param()
    if ($null -eq ('PreBackup.NativePower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PreBackup {
    [StructLayout(LayoutKind.Sequential)]
    public struct PowerStatus {
        public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public uint BatteryLifeTime, BatteryFullLifeTime;
    }
    public static class NativePower {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetSystemPowerStatus(out PowerStatus status);
    }
}
'@ -ErrorAction Stop
    }
    $status = New-Object -TypeName PreBackup.PowerStatus
    if (-not [PreBackup.NativePower]::GetSystemPowerStatus([ref]$status)) {
        throw 'Windows could not determine AC power status.'
    }
    [pscustomobject]@{ OnAC = $status.ACLineStatus -eq 1; Known = $status.ACLineStatus -ne 255; BatteryPercent = $status.BatteryLifePercent }
}

function Get-ReportReviewFinding {
    <#
    .SYNOPSIS
    Returns the review findings from one maintenance step with their source report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StepName,
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$ReportPath,
        [int]$ExitCode = 0
    )
    $findings = @($Report.Results | Where-Object { $_.Status -eq 'Review' })
    foreach ($finding in $findings) {
        [pscustomobject]@{
            Step = $StepName
            Check = [string]$finding.Step
            Detail = [string]$finding.Detail
            Report = $ReportPath
        }
    }
    if ($ExitCode -eq 2 -and $findings.Count -eq 0) {
        [pscustomobject]@{
            Step = $StepName
            Check = 'Report'
            Detail = 'Review the saved report; the step requested review without a detailed finding.'
            Report = $ReportPath
        }
    }
}

function Get-GuidedRunDisposition {
    <#
    .SYNOPSIS
    Classifies a guided run as stopped, completed with review, or completed clean.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Completed,
        [object[]]$ReviewFindings = @(),
        [string]$Failure
    )
    $reviewRequired = $ReviewFindings.Count -gt 0
    if (-not $Completed) {
        return [pscustomobject]@{ ExitCode = 1; ReviewRequired = $reviewRequired; Message = $Failure }
    }
    if ($reviewRequired) {
        return [pscustomobject]@{ ExitCode = 2; ReviewRequired = $true; Message = "Guided pre-backup run completed with $($ReviewFindings.Count) review finding(s)." }
    }
    [pscustomobject]@{ ExitCode = 0; ReviewRequired = $false; Message = 'Guided pre-backup run completed.' }
}

function Get-ReportFailureMessage {
    <#
    .SYNOPSIS
    Describes a failed maintenance step and points to its source report.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StepName,
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][int]$ExitCode
    )
    $failures = @($Report.Results | Where-Object { $_.Status -eq 'Failed' })
    $details = if ($failures.Count -gt 0) {
        (@($failures | ForEach-Object { "$($_.Step): $($_.Detail)" }) -join '; ')
    } else {
        "Step returned exit code $ExitCode."
    }
    "$StepName failed. $details Report: $ReportPath"
}

function Test-ContainedRegularPath {
    <#
    .SYNOPSIS
    Checks containment and rejects reparse points in a path and its ancestors.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($rootFull -eq [IO.Path]::GetPathRoot($rootFull).TrimEnd('\')) { return $false }
    if (-not $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    # Check the candidate and every ancestor, including ancestors above the root.
    # Never follow directory junctions, symlinks or cloud reparse points.
    $current = $pathFull
    try {
        while ($current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { break }
            $current = $parent.FullName
        }
    } catch { return $false }
    return $true
}

function Get-AgedTemporaryFile {
    <#
    .SYNOPSIS
    Enumerates old regular files without traversing reparse points.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [ValidateRange(7,365)][int]$MinimumAgeDays = 14)
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The temporary root must be a regular directory.'
    }
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$MinimumAgeDays)
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($rootItem.FullName)
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        if ($directory -ne $rootItem.FullName -and -not (Test-ContainedRegularPath -Root $Root -Path $directory)) { continue }
        try { $items = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
        catch { Write-Warning "Cannot enumerate ${directory}: $($_.Exception.Message)"; continue }
        foreach ($item in $items) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName); continue }
            if ($item.LastWriteTimeUtc -lt $cutoff -and $item.CreationTimeUtc -lt $cutoff) {
                if (Test-ContainedRegularPath -Root $Root -Path $item.FullName) {
                    [pscustomobject]@{ Root = $rootItem.FullName; Path = $item.FullName; Bytes = $item.Length; LastWriteTimeUtc = $item.LastWriteTimeUtc }
                }
            }
        }
    }
}

function Remove-TemporaryFileByHandle {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The exported Remove-AgedTemporaryFile caller performs the ShouldProcess check immediately before invoking this internal handle-level deletion helper.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($null -eq ('PreBackup.NativeFile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace PreBackup {
    public static class NativeFile {
        private const uint Delete = 0x00010000;
        private const uint ShareRead = 0x00000001;
        private const uint ShareWrite = 0x00000002;
        private const uint ShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint OpenReparsePoint = 0x00200000;
        private const int FileDispositionInfoEx = 21;
        private const uint DeleteFlag = 0x00000001;
        private const uint IgnoreReadonlyFlag = 0x00000010;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(IntPtr handle, int infoClass, ref uint info, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static void DeleteByHandle(string path) {
            IntPtr handle = CreateFile(path, Delete, ShareRead | ShareWrite | ShareDelete, IntPtr.Zero, OpenExisting, OpenReparsePoint, IntPtr.Zero);
            if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                uint disposition = DeleteFlag | IgnoreReadonlyFlag;
                if (!SetFileInformationByHandle(handle, FileDispositionInfoEx, ref disposition, sizeof(uint))) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            } finally { CloseHandle(handle); }
        }
    }
}
'@ -ErrorAction Stop
    }
    [PreBackup.NativeFile]::DeleteByHandle($Path)
}

function Remove-AgedTemporaryFile {
    <#
    .SYNOPSIS
    Revalidates and removes individual aged temporary files with WhatIf support.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Root, [ValidateRange(7,365)][int]$MinimumAgeDays = 14)
    $deleted = 0; $failed = 0; $skipped = 0; [long]$bytes = 0
    foreach ($candidate in @(Get-AgedTemporaryFile -Root $Root -MinimumAgeDays $MinimumAgeDays)) {
        if (-not $PSCmdlet.ShouldProcess($candidate.Path, 'Delete old temporary file')) { $skipped++; continue }
        try {
            # Revalidate immediately before removing an individual literal file.
            if (-not (Test-ContainedRegularPath -Root $Root -Path $candidate.Path)) { $skipped++; continue }
            $item = Get-Item -LiteralPath $candidate.Path -Force -ErrorAction Stop
            $cutoff = (Get-Date).ToUniversalTime().AddDays(-$MinimumAgeDays)
            if ($item.PSIsContainer -or $item.LastWriteTimeUtc -ge $cutoff -or $item.CreationTimeUtc -ge $cutoff) { $skipped++; continue }
            $length = $item.Length
            # Delete through an opened file handle so the final operation targets the
            # object that was opened, rather than resolving a second path target.
            Remove-TemporaryFileByHandle -Path $item.FullName
            $deleted++; $bytes += $length
        } catch { $failed++; Write-Warning "Skipped $($candidate.Path): $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Root = $Root; Deleted = $deleted; Skipped = $skipped; Failed = $failed; LogicalBytesDeleted = $bytes }
}

Export-ModuleMember -Function Get-PendingRestartState, Get-AcPowerState, Get-ReportReviewFinding, Get-GuidedRunDisposition, Get-ReportFailureMessage, Test-ContainedRegularPath, Get-AgedTemporaryFile, Remove-AgedTemporaryFile
