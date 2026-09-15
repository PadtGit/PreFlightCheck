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
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            $deleted++; $bytes += $length
        } catch { $failed++; Write-Warning "Skipped $($candidate.Path): $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Root = $Root; Deleted = $deleted; Skipped = $skipped; Failed = $failed; LogicalBytesDeleted = $bytes }
}

Export-ModuleMember -Function Get-PendingRestartState, Get-AcPowerState, Test-ContainedRegularPath, Get-AgedTemporaryFile, Remove-AgedTemporaryFile
