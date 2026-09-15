#Requires -Version 7.0
<#
.SYNOPSIS
    Opens the Windows 11 pre-backup maintenance dashboard.
.PARAMETER UiTestOutput
    Renders the dashboard to a PNG without running maintenance.
.PARAMETER UiPage
    Page to render during UI testing.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile','',Justification='PowerShell 7 reads this UTF-8 interface file without a BOM.')]
param(
    [string]$UiTestOutput,
    [ValidateSet('Audit','Applications','Cleanup','Health','Dell')][string]$UiPage = 'Cleanup'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw '64-bit PowerShell 7 on Windows is required.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Use Start-Maintenance.cmd to open this window.' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:root = $PSScriptRoot
$script:runRoot = Join-Path -Path $root -ChildPath 'GuiRuns'
$script:active = $null
$script:runDirectory = $null
$script:lastPage = 'Audit'
[xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Pre-Backup Maintenance" Width="1120" Height="780" MinWidth="940" MinHeight="650" Background="#111A26" Foreground="#E9F1F7" WindowStartupLocation="CenterScreen">
<Window.Resources>
<Style TargetType="Button"><Setter Property="Padding" Value="12,9"/><Setter Property="Margin" Value="0,0,8,8"/><Setter Property="Background" Value="#2A3C50"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderThickness" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Left"/></Style>
<Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style>
<Style TargetType="CheckBox"><Setter Property="Foreground" Value="#E9F1F7"/><Setter Property="Margin" Value="0,5,0,8"/></Style>
</Window.Resources>
<Grid Margin="20"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="220"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<StackPanel><TextBlock Text="PRE-BACKUP MAINTENANCE" FontSize="26" FontWeight="Bold"/><TextBlock x:Name="Session" Foreground="#ADC0D2" Margin="0,6,0,16"/></StackPanel>
<Grid Grid.Row="1" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="285"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<StackPanel x:Name="Tasks"><TextBlock Text="SYSTEM" Foreground="#74DCC7" Margin="0,0,0,7"/><Button x:Name="AuditButton" Content="System review"/><TextBlock Text="MAINTENANCE" Foreground="#74DCC7" Margin="0,10,0,7"/><Button x:Name="ApplicationsButton" Content="WinGet applications"/><Button x:Name="CleanupButton" Content="Pre-backup cleanup"/><Button x:Name="HealthButton" Content="Windows health"/><TextBlock Text="DELL — SEPARATE WEEKLY TASK" Foreground="#74DCC7" Margin="0,10,0,7"/><Button x:Name="DellButton" Content="Dell drivers &amp; firmware"/></StackPanel>
<Grid Grid.Column="1" Margin="20,0,0,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<StackPanel><TextBlock x:Name="Heading" FontSize="22" FontWeight="Bold"/><TextBlock x:Name="Description" Margin="0,8,0,5"/><TextBlock x:Name="Access" Foreground="#F3C87F" Margin="0,0,0,12"/></StackPanel>
<ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Options">
<TextBlock x:Name="InputLabel"/><TextBox x:Name="ValueInput" Padding="7" Margin="0,4,0,9"/>
<CheckBox x:Name="OptionOne"/><CheckBox x:Name="OptionTwo"/>
<Border x:Name="NoticeBorder" Background="#1A2938" Padding="12" Margin="0,10,0,8"><TextBlock x:Name="Notice" Foreground="#ADC0D2"/></Border>
</StackPanel></ScrollViewer>
<WrapPanel Grid.Row="2"><Button x:Name="Preview" Content="Run review" Background="#14756C"/><Button x:Name="Apply" Content="Apply changes…" Background="#964B38"/></WrapPanel>
</Grid></Grid>
<Grid Grid.Row="2"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="RESULT" Foreground="#74DCC7" FontWeight="Bold" Margin="0,0,0,6"/><TextBox x:Name="Console" Grid.Row="1" IsReadOnly="True" Background="#080D14" Foreground="#BFE9D9" FontFamily="Consolas" FontSize="13" Padding="10" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Text="Choose a task. Results will appear here."/></Grid>
<DockPanel Grid.Row="3" Margin="0,12,0,0"><StackPanel Orientation="Horizontal" DockPanel.Dock="Right"><Button x:Name="OpenResults" Content="Open results"/><Button x:Name="OpenGuide" Content="Guide"/></StackPanel><TextBlock x:Name="Status" Text="Ready" VerticalAlignment="Center"/></DockPanel>
</Grid></Window>
'@
$script:window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
foreach ($name in @('Session','Tasks','AuditButton','ApplicationsButton','CleanupButton','HealthButton','DellButton','Heading','Description','Access','Options','InputLabel','ValueInput','OptionOne','OptionTwo','NoticeBorder','Notice','Preview','Apply','Console','OpenResults','OpenGuide','Status')) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Session.Text = if ($isAdmin) { 'Administrator session • one task at a time • reports saved automatically' } else { 'Standard session • Windows will request permission only for cleanup or health work' }
function Show-Page {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Audit','Applications','Cleanup','Health','Dell')][string]$Page)
    $script:lastPage = $Page
    $ValueInput.Visibility = 'Collapsed'; $InputLabel.Visibility = 'Collapsed'; $OptionOne.Visibility = 'Collapsed'; $OptionTwo.Visibility = 'Collapsed'; $NoticeBorder.Visibility = 'Visible'; $Preview.Visibility = 'Visible'; $Apply.Visibility = 'Visible'
    switch ($Page) {
        'Audit' {
            $Heading.Text = 'System review'; $Description.Text = 'Collect disk, volume, restart, security, event, VSS and temporary-file information.'; $Access.Text = 'Read-only. Administrator access adds VSS writer details.'
            $Notice.Text = 'This is an assessment. A clean report cannot guarantee that every file, application, or backup is healthy.'; $Preview.Content = 'Run system review'; $Apply.Visibility = 'Collapsed'
        }
        'Applications' {
            $Heading.Text = 'WinGet application updates'; $Description.Text = 'Preview all detected application updates, then install only exact package IDs you select.'; $Access.Text = 'Applications only. Dell drivers, BIOS and firmware are excluded.'
            $InputLabel.Text = 'Exact application IDs, comma separated'; $InputLabel.Visibility = 'Visible'; $ValueInput.Visibility = 'Visible'; $ValueInput.Text = ''
            $Notice.Text = 'Preview first. Unknown-version, pinned, forced, automatic-all, agreement auto-acceptance and automatic reboot options are not used.'; $Preview.Content = 'Preview updates'; $Apply.Content = 'Install selected apps…'
        }
        'Cleanup' {
            $Heading.Text = 'Pre-backup cleanup'; $Description.Text = 'Measure and remove old regular files only from the user and Windows temporary folders.'; $Access.Text = 'Preview is read-only. Cleanup requests Administrator permission.'
            $InputLabel.Text = 'Minimum file age in days (7 to 365)'; $InputLabel.Visibility = 'Visible'; $ValueInput.Visibility = 'Visible'; $ValueInput.Text = '14'
            $OptionOne.Content = 'Also empty my Recycle Bin'; $OptionOne.Visibility = 'Visible'; $OptionOne.IsChecked = $false
            $OptionTwo.Content = 'Also clear the Delivery Optimization cache'; $OptionTwo.Visibility = 'Visible'; $OptionTwo.IsChecked = $false
            $Notice.Text = 'Folders, recent files and linked locations are preserved. Optional items are applied only during cleanup, after confirmation.'; $Preview.Content = 'Preview cleanup'; $Apply.Content = 'Clean reviewed items…'
        }
        'Health' {
            $Heading.Text = 'Windows health'; $Description.Text = 'Run component-store, protected-file and online file-system checks; repair only when selected.'; $Access.Text = 'Administrator permission required. AC power and a quiet maintenance window are checked.'
            $OptionOne.Content = 'After successful repair checks, clean superseded Windows components'; $OptionOne.Visibility = 'Visible'; $OptionOne.IsChecked = $false
            $Notice.Text = 'Run the check first. Repairs may need a restart. No automatic restart occurs, and the irreversible component base-reset option is never used.'; $Preview.Content = 'Run health checks'; $Apply.Content = 'Repair Windows…'
        }
        'Dell' {
            $Heading.Text = 'Dell drivers and firmware'; $Description.Text = 'Show installed BIOS information and open the official Dell G5 5590 support page.'; $Access.Text = 'Separate weekly, attended review. No update is downloaded or installed.'
            $Notice.Text = 'Before a BIOS update: verify a backup, connect AC, close apps, have the BitLocker recovery key available, and follow the exact Dell package instructions.'; $Preview.Content = 'Open Dell review'; $Apply.Visibility = 'Collapsed'
        }
    }
}
function Get-CleanupAge {
    [CmdletBinding()]
    param()
    $age = 0
    if (-not [int]::TryParse($ValueInput.Text.Trim(), [ref]$age) -or $age -lt 7 -or $age -gt 365) { throw 'Enter a whole number from 7 to 365 for minimum file age.' }
    return $age
}
function Start-DashboardTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='The UI confirms changes and the underlying scripts enforce their own safeguards.')]
    [CmdletBinding()]
    param([switch]$ApplyChanges)
    try {
        if ($script:active -and -not $script:active.HasExited) { throw 'Finish the running task first.' }
        $task = $script:lastPage
        $request = @{ Task = $task }
        $requiresAdmin = $false
        switch ($script:lastPage) {
            'Applications' {
                if ($ApplyChanges) {
                    $ids = @($ValueInput.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($ids.Count -eq 0) { throw 'Preview the list, then enter at least one exact application ID.' }
                    $request.Task = 'UpdateInstall'; $request.ApplicationId = $ids
                } else { $request.Task = 'UpdatePreview' }
            }
            'Cleanup' {
                $request.MinimumAgeDays = Get-CleanupAge
                if ($ApplyChanges) { $request.Task = 'Clean'; $request.EmptyRecycleBin = [bool]$OptionOne.IsChecked; $request.ClearDeliveryCache = [bool]$OptionTwo.IsChecked; $requiresAdmin = $true }
                else { $request.Task = 'CleanPreview' }
            }
            'Health' {
                $requiresAdmin = $true
                if ($ApplyChanges) { $request.Task = 'HealthRepair'; $request.ComponentCleanup = [bool]$OptionOne.IsChecked }
                else { $request.Task = 'HealthCheck' }
            }
            'Dell' { $request.Task = 'DellReview' }
        }
        if ($ApplyChanges) {
            $choice = [Windows.MessageBox]::Show($window, "Apply the selected $($Heading.Text.ToLowerInvariant()) action? Save work, close applications, connect AC power, and confirm no backup or update is running.", 'Confirm maintenance', 'YesNo', 'Warning')
            if ($choice -ne 'Yes') { return }
        }
        $script:runDirectory = Join-Path -Path $runRoot -ChildPath ([datetime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        [void][IO.Directory]::CreateDirectory($runDirectory)
        $requestPath = Join-Path -Path $runDirectory -ChildPath 'request.json'
        $request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -Encoding utf8
        $worker = Join-Path -Path $root -ChildPath 'Invoke-GuiTask.ps1'
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path -Path $PSHOME -ChildPath 'pwsh.exe'))
        $start.UseShellExecute = $true; $start.WindowStyle = 'Hidden'
        if ($requiresAdmin -and -not $isAdmin) { $start.Verb = 'runas' }
        foreach ($argument in @('-NoLogo','-NoProfile','-File',$worker,'-RequestPath',$requestPath)) { [void]$start.ArgumentList.Add($argument) }
        $script:active = [Diagnostics.Process]::Start($start)
        $Tasks.IsEnabled = $false; $Options.IsEnabled = $false; $Preview.IsEnabled = $false; $Apply.IsEnabled = $false
        $Console.Text = "Running $($request.Task)…`r`nResults: $runDirectory"; $Status.Text = 'Running'
    } catch { [void][Windows.MessageBox]::Show($window, $_.Exception.Message, 'Unable to start', 'OK', 'Error') }
}
$AuditButton.Add_Click({ Show-Page Audit }); $ApplicationsButton.Add_Click({ Show-Page Applications }); $CleanupButton.Add_Click({ Show-Page Cleanup }); $HealthButton.Add_Click({ Show-Page Health }); $DellButton.Add_Click({ Show-Page Dell })
$Preview.Add_Click({ Start-DashboardTask }); $Apply.Add_Click({ Start-DashboardTask -ApplyChanges })
$OpenResults.Add_Click({ if ($script:runDirectory) { Start-Process -FilePath explorer.exe -ArgumentList ('"' + $script:runDirectory + '"') } else { [void][Windows.MessageBox]::Show('Run a task first.') } })
$OpenGuide.Add_Click({ Start-Process -FilePath (Join-Path -Path $root -ChildPath 'README.md') })
$timer = [Windows.Threading.DispatcherTimer]::new(); $timer.Interval = [timespan]::FromMilliseconds(700)
$timer.Add_Tick({
    if (-not $script:active) { return }
    try {
        if ($script:active.HasExited) {
            $summaryPath = Join-Path -Path $runDirectory -ChildPath 'summary.txt'
            $Console.Text = if (Test-Path -LiteralPath $summaryPath) { Get-Content -LiteralPath $summaryPath -Raw } else { 'NEEDS ATTENTION - no summary was saved.' }
            $Console.ScrollToHome(); $Status.Text = ($Console.Text -split '\r?\n')[0]
            $script:active.Dispose(); $script:active = $null
            $Tasks.IsEnabled = $true; $Options.IsEnabled = $true; $Preview.IsEnabled = $true; $Apply.IsEnabled = $true
        }
    } catch { $Status.Text = 'Waiting for result…' }
})
$window.Add_Closing({ if ($script:active -and -not $script:active.HasExited) { $_.Cancel = $true; [void][Windows.MessageBox]::Show('Wait for the running task to finish before closing.') } })
$window.Add_ContentRendered({
    $window.WindowState = 'Normal'
    $window.Topmost = $true
    [void]$window.Activate()
    $window.Topmost = $false
})
Show-Page -Page $UiPage
if ($UiTestOutput) {
    foreach ($page in @('Audit','Applications','Cleanup','Health','Dell')) { Show-Page -Page $page; if ($Heading.Text.Length -eq 0) { throw "Page failed: $page" } }
    Show-Page -Page $UiPage
    if ($UiPage -eq 'Cleanup') {
        foreach ($invalid in @('0','6','366','1.5','abc')) { $ValueInput.Text = $invalid; $rejected = $false; try { Get-CleanupAge | Out-Null } catch { $rejected = $true }; if (-not $rejected) { throw "Invalid age accepted: $invalid" } }
        $ValueInput.Text = '14'; if ((Get-CleanupAge) -ne 14) { throw 'Valid cleanup age rejected.' }
    }
    $surface = $window.Content; $surface.Measure([Windows.Size]::new(1080,740)); $surface.Arrange([Windows.Rect]::new(0,0,1080,740)); $surface.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(1080,740,96,96,[Windows.Media.PixelFormats]::Pbgra32); $bitmap.Render($surface)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create([IO.Path]::GetFullPath($UiTestOutput)); try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Output 'PASS: five dashboard pages rendered and cleanup input limits were validated. No maintenance ran.'
} else { $timer.Start(); try { [void]$window.ShowDialog() } finally { $timer.Stop() } }
