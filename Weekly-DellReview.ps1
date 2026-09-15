#Requires -Version 5.1
<#
.SYNOPSIS
    Opens the official Dell G5 5590 driver page for a separate weekly review.
.DESCRIPTION
    Displays installed BIOS information. Does not install, download, schedule,
    flash firmware, or change BitLocker. The user reviews and applies Dell updates.
.EXAMPLE
    .\Weekly-DellReview.ps1
.EXAMPLE
    .\Weekly-DellReview.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bios = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
Write-Information -MessageData "Model: $($bios.SystemProductName); installed BIOS: $($bios.BIOSVersion); firmware date: $($bios.BIOSReleaseDate)" -InformationAction Continue
if ($bios.SystemManufacturer -notmatch 'Dell' -or $bios.SystemProductName -ne 'G5 5590') {
    throw 'This helper is for the Dell G5 5590. Select your actual model on Dell Support.'
}
Write-Information -MessageData 'Review once a week. Before installing: have a working backup, connect AC, close apps, and read the package instructions. For BIOS, confirm the recovery key is accessible and follow Dell BitLocker guidance. Restart when requested and verify protection afterward.' -InformationAction Continue
if ($PSCmdlet.ShouldProcess('Official Dell G5 5590 support page', 'Open weekly driver and firmware review')) {
    Start-Process -FilePath 'https://www.dell.com/support/home/en-us/product-support/product/g-series-15-5590-laptop/drivers' -WindowStyle Normal
}
