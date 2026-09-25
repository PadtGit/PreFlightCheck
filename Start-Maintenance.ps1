#Requires -Version 7.0
<#
.SYNOPSIS
    Opens the Windows 11 pre-backup maintenance dashboard.
.PARAMETER UiTestOutput
    Renders the dashboard to a PNG without running maintenance.
.PARAMETER UiPage
    Page to render during UI testing.
.PARAMETER UiState
    Dashboard state to render during UI testing.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile','',Justification='PowerShell 7 reads this UTF-8 interface file without a BOM.')]
param(
    [string]$UiTestOutput,
    [ValidateSet('Runbook','Audit','Applications','Cleanup','Health','SystemRepair','Dell')][string]$UiPage = 'Runbook',
    [ValidateSet('Idle','Running','Success','Review','ActionNeeded','Restart','Repair')][string]$UiState = 'Idle'
)

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Dashboard.Core.psm1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw '64-bit PowerShell 7 on Windows is required.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Use Start-Maintenance.cmd to open this window.' }
$startupPrincipal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $UiTestOutput -and -not $startupPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $elevated = [Diagnostics.ProcessStartInfo]::new((Join-Path -Path $PSHOME -ChildPath 'pwsh.exe'))
    $elevated.UseShellExecute = $true; $elevated.Verb = 'runas'; $elevated.WindowStyle = 'Hidden'
    foreach ($argument in @('-NoLogo','-NoProfile','-STA','-File',$PSCommandPath,'-UiPage',$UiPage,'-UiState',$UiState)) { [void]$elevated.ArgumentList.Add($argument) }
    [void][Diagnostics.Process]::Start($elevated)
    exit 0
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:root = $PSScriptRoot
$script:runRoot = Join-Path -Path $root -ChildPath 'GuiRuns'
$script:active = $null
$script:runDirectory = $null
$script:sessionDirectory = $null
$script:taskNumber = 0
$script:healthReady = $false
$script:taskStatus = 'IDLE — Ready'
$script:lastPage = 'Runbook'
$script:activeTask = $null
$script:taskStartedAt = $null
$script:liveActivityState = $null
[xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Pre-Backup Maintenance" Width="1120" Height="830" MinWidth="940" MinHeight="700" Background="#111A26" Foreground="#E9F1F7" WindowStartupLocation="CenterScreen">
<Window.Resources>
<Style TargetType="Button"><Setter Property="Padding" Value="10,5"/><Setter Property="Margin" Value="0,0,8,4"/><Setter Property="Background" Value="#2A3C50"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderThickness" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Left"/></Style>
<Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style>
<Style TargetType="CheckBox"><Setter Property="Foreground" Value="#E9F1F7"/><Setter Property="Margin" Value="0,5,0,8"/></Style>
</Window.Resources>
<Grid Margin="20" Background="#111A26"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="320"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<StackPanel><TextBlock Text="PRE-BACKUP MAINTENANCE" FontSize="26" FontWeight="Bold"/><TextBlock x:Name="Session" Foreground="#ADC0D2" Margin="0,6,0,16"/></StackPanel>
<Grid Grid.Row="1" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="285"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,6,0"><StackPanel x:Name="Tasks"><TextBlock Text="GUIDED RUN" Foreground="#74DCC7" Margin="0,0,0,3"/><Button x:Name="RunbookButton" Content="Run pre-backup sequence" Background="#14756C"/><TextBlock Text="SYSTEM" Foreground="#74DCC7" Margin="0,4,0,3"/><Button x:Name="AuditButton" Content="System review"/><TextBlock Text="MAINTENANCE" Foreground="#74DCC7" Margin="0,4,0,3"/><Button x:Name="ApplicationsButton" Content="WinGet applications"/><Button x:Name="HealthButton" Content="Windows health"/><Button x:Name="SystemRepairButton" Content="System Corruption Scan - Run"/><Button x:Name="CleanupButton" Content="Pre-backup cleanup"/><TextBlock Text="DELL — SEPARATE WEEKLY TASK" Foreground="#74DCC7" Margin="0,4,0,3"/><Button x:Name="DellButton" Content="Dell drivers &amp; firmware"/></StackPanel></ScrollViewer>
<Grid Grid.Column="1" Margin="20,0,0,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<StackPanel><TextBlock x:Name="Heading" FontSize="22" FontWeight="Bold"/><TextBlock x:Name="Description" Margin="0,8,0,5"/><TextBlock x:Name="Access" Foreground="#F3C87F" Margin="0,0,0,12"/></StackPanel>
<ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Options">
<TextBlock x:Name="InputLabel"/><TextBox x:Name="ValueInput" Padding="7" Margin="0,4,0,9"/>
<TextBlock x:Name="SelectionCount" Foreground="#74DCC7" Margin="0,0,0,6"/>
<StackPanel x:Name="ApplicationActions"><TextBlock Text="ACTIONS" Foreground="#74DCC7" Margin="0,4,0,4"/><Button x:Name="InstallUpgradeButton" Content="Install/Upgrade Applications"/><Button x:Name="UninstallButton" Content="Uninstall Applications"/><Button x:Name="UpgradeAllButton" Content="Upgrade all Applications"/><TextBlock Text="SELECTION" Foreground="#74DCC7" Margin="0,4,0,4"/><Button x:Name="ShowInstalledButton" Content="Show Installed Apps"/><Button x:Name="ClearSelectionButton" Content="Clear Selection"/></StackPanel>
<CheckBox x:Name="OptionOne"/><CheckBox x:Name="OptionTwo"/>
<Border x:Name="NoticeBorder" Background="#1A2938" Padding="12" Margin="0,10,0,8"><TextBlock x:Name="Notice" Foreground="#ADC0D2"/></Border>
</StackPanel></ScrollViewer>
<WrapPanel Grid.Row="2"><Button x:Name="Preview" Content="Run review" Background="#14756C"/><Button x:Name="Apply" Content="Apply changes…" Background="#964B38"/></WrapPanel>
</Grid></Grid>
<Grid Grid.Row="2"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><Grid Margin="0,0,0,6"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="LIVE ACTIVITY / RESULT" Foreground="#74DCC7" FontWeight="Bold" VerticalAlignment="Center"/><Border x:Name="StatusBorder" Grid.Column="1" HorizontalAlignment="Right" Background="#172534" BorderBrush="#4A6178" BorderThickness="1" CornerRadius="3" Padding="9,4"><TextBlock x:Name="Status" Text="IDLE — Ready" Foreground="#ADC0D2" FontWeight="SemiBold"/></Border></Grid><Grid Grid.Row="1" Margin="0,0,0,8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="CurrentOperation" Text="Current operation: Waiting to start" Foreground="#E9F1F7" FontWeight="SemiBold" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="ElapsedTask" Grid.Column="1" Text="Elapsed: 00:00:00" Foreground="#ADC0D2" Margin="16,0,0,0" TextWrapping="NoWrap"/></Grid><Grid Grid.Row="1" Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><ProgressBar x:Name="ActivityProgress" Height="7" Minimum="0" Maximum="100" IsIndeterminate="False" Value="0" Foreground="#74DCC7" Background="#172534" BorderBrush="#2D5B68"/><TextBlock x:Name="ActivityProgressText" Grid.Column="1" Text="Ready" Foreground="#ADC0D2" HorizontalAlignment="Right" MinWidth="70" Margin="10,-5,0,0" TextWrapping="NoWrap"/></Grid></Grid><TextBox x:Name="Console" Grid.Row="2" IsReadOnly="True" Background="#080D14" Foreground="#D7E7E1" FontFamily="Consolas" FontSize="13" Padding="10" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Text="Choose a task. Live activity and the final result will appear here."/></Grid>
<DockPanel Grid.Row="3" Margin="0,12,0,0"><StackPanel Orientation="Horizontal" DockPanel.Dock="Right"><Button x:Name="OpenResults" Content="Open result summary" IsEnabled="False"/><Button x:Name="OpenResultFolder" Content="Open result folder" IsEnabled="False"/><Button x:Name="OpenGuide" Content="Guide"/></StackPanel><TextBlock Text="Detailed output is saved automatically." Foreground="#ADC0D2" VerticalAlignment="Center"/></DockPanel>
</Grid></Window>
'@
$script:window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
foreach ($name in @('Session','Tasks','RunbookButton','AuditButton','ApplicationsButton','CleanupButton','HealthButton','SystemRepairButton','DellButton','Heading','Description','Access','Options','InputLabel','ValueInput','SelectionCount','ApplicationActions','InstallUpgradeButton','UninstallButton','UpgradeAllButton','ShowInstalledButton','ClearSelectionButton','OptionOne','OptionTwo','NoticeBorder','Notice','Preview','Apply','Console','OpenResults','OpenResultFolder','OpenGuide','StatusBorder','Status','CurrentOperation','ElapsedTask','ActivityProgress','ActivityProgressText')) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Session.Text = if ($isAdmin) { 'Administrator session • guided order • one combined session log' } else { 'UI test session • no maintenance will run' }
function Set-DashboardStatus {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Updates only dashboard presentation controls and performs no system state changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Idle','Running','Success','Review','ActionNeeded','Restart','Repair')][string]$State,
        [string]$Label
    )

    $style = Get-DashboardStateStyle -State $State
    $Status.Text = if ([string]::IsNullOrWhiteSpace($Label)) { $style.Label } else { $Label }
    $Status.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($style.Foreground)
    $StatusBorder.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($style.Background)
    $StatusBorder.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString($style.Border)
}
function Set-LiveActivityPresentation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Updates only dashboard presentation controls and performs no system state changes.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$State)

    $CurrentOperation.Text = "Current operation: $($State.CurrentOperation)"
    $CurrentOperation.ToolTip = [string]$State.CurrentOperation
    $ElapsedTask.Text = "Elapsed: $($State.ElapsedText)"
    $ActivityProgress.Visibility = 'Visible'
    if ($null -eq $State.Percentage) {
        $ActivityProgress.IsIndeterminate = $true
        $ActivityProgress.Value = 0
        $ActivityProgressText.Text = 'Working…'
    } else {
        $ActivityProgress.IsIndeterminate = $false
        $ActivityProgress.Value = [double]$State.Percentage
        $ActivityProgressText.Text = $State.Percentage.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + '%'
    }
}
Set-DashboardStatus -State Idle
function Update-CleanupAvailability {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Updates only dashboard controls; maintenance retains its confirmation and execution guards.')]
    [CmdletBinding()]
    param()
    $taskRunning = $script:active -and -not $script:active.HasExited
    $Apply.IsEnabled = -not $taskRunning
    if (-not $taskRunning) { $Status.Text = $script:taskStatus }
    if ($script:lastPage -ne 'Cleanup') { return }
    $Apply.IsEnabled = -not $taskRunning -and $script:healthReady
    if ($script:healthReady) {
        $Apply.Content = 'Clean reviewed items…'
        $Access.Text = 'Health checks passed in this session. Preview cleanup and review the results before applying changes.'
    } else {
        $Apply.Content = 'Cleanup locked'
        $Access.Text = 'CLEANUP LOCKED: Run normal Windows health checks successfully before applying cleanup. Preview is available.'
        if (-not $taskRunning) {
            if ($Status.Text -match '^(RESTART|REPAIR|ACTION NEEDED|WINDOWS REPAIR RECOMMENDED|NEEDS ATTENTION|REVIEW)\b') {
                $Status.Text = 'CLEANUP LOCKED - ' + $Status.Text
            } else {
                $Status.Text = 'CLEANUP LOCKED - run Windows health checks first'
            }
        }
    }
}
function Show-DashboardWarning {
    [CmdletBinding()]
    param([string]$Message, [string]$Title, [ValidateSet('Stop','Warning')][string]$Icon)
    [void][Windows.MessageBox]::Show($window, $Message, $Title, 'OK', $Icon)
}
function Show-Page {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Runbook','Audit','Applications','Cleanup','Health','SystemRepair','Dell')][string]$Page)
    $script:lastPage = $Page
    $ApplicationActions.Visibility = if ($Page -eq 'Applications') { 'Visible' } else { 'Collapsed' }
    $SelectionCount.Visibility = if ($Page -eq 'Applications') { 'Visible' } else { 'Collapsed' }
    $ValueInput.Visibility = 'Collapsed'; $InputLabel.Visibility = 'Collapsed'; $OptionOne.Visibility = 'Collapsed'; $OptionTwo.Visibility = 'Collapsed'; $NoticeBorder.Visibility = 'Visible'; $Preview.Visibility = 'Visible'; $Apply.Visibility = 'Visible'
    switch ($Page) {
        'Runbook' {
            $Heading.Text = 'Guided pre-backup run'; $Description.Text = 'Run system review, Windows health, update preview and cleanup in the safe order.'; $Access.Text = 'Administrator session required. The run stops before cleanup if repair or restart is needed.'
            $InputLabel.Text = 'Minimum temporary-file age in days (7 to 365)'; $InputLabel.Visibility = 'Visible'; $ValueInput.Visibility = 'Visible'; $ValueInput.Text = '14'
            $OptionOne.Content = 'Also empty my Recycle Bin during cleanup'; $OptionOne.Visibility = 'Visible'; $OptionOne.IsChecked = $false
            $OptionTwo.Content = 'Also clear the Delivery Optimization cache'; $OptionTwo.Visibility = 'Visible'; $OptionTwo.IsChecked = $false
            $Notice.Text = 'Creates one timestamped session log. A restart or recommended repair stops the sequence before cleanup and backup.'; $Preview.Visibility = 'Collapsed'; $Apply.Content = 'Start guided run…'
        }
        'Audit' {
            $Heading.Text = 'System review'; $Description.Text = 'Collect disk, volume, restart, security, event, VSS and temporary-file information.'; $Access.Text = 'Read-only. The elevated dashboard always collects VSS writer details.'
            $Notice.Text = 'This is an assessment. A clean report cannot guarantee that every file, application, or backup is healthy.'; $Preview.Content = 'Run system review'; $Apply.Visibility = 'Collapsed'
        }
        'Applications' {
            $Heading.Text = 'WinGet application updates'; $Description.Text = 'Preview updates and choose exact package IDs for selected actions. Upgrade all applies to all WinGet-eligible packages.'; $Access.Text = 'Upgrade all may include vendor utilities or driver packages. Review drivers and firmware separately; avoid Upgrade all if unsure.'
            $InputLabel.Text = 'Selected exact application IDs, comma separated'; $InputLabel.Visibility = 'Visible'; $ValueInput.Visibility = 'Visible'; $ValueInput.Text = ''
            $SelectionCount.Text = 'Selected Apps: 0'; $Notice.Text = 'Selected actions use the exact IDs you enter. Upgrade all uses WinGet eligibility and does not apply the selected-ID Dell/firmware exclusions.'; $Preview.Content = 'Preview available updates'; $Apply.Visibility = 'Collapsed'
        }
        'Cleanup' {
            $Heading.Text = 'Pre-backup cleanup'; $Description.Text = 'Measure and remove old regular files only from the user and Windows temporary folders.'; $Access.Text = 'Actual cleanup requires a successful Windows health check in this dashboard session.'
            $InputLabel.Text = 'Minimum file age in days (7 to 365)'; $InputLabel.Visibility = 'Visible'; $ValueInput.Visibility = 'Visible'; $ValueInput.Text = '14'
            $OptionOne.Content = 'Also empty my Recycle Bin'; $OptionOne.Visibility = 'Visible'; $OptionOne.IsChecked = $false
            $OptionTwo.Content = 'Also clear the Delivery Optimization cache'; $OptionTwo.Visibility = 'Visible'; $OptionTwo.IsChecked = $false
            $Notice.Text = 'Folders, recent files and linked locations are preserved. Optional items are applied only during cleanup, after confirmation.'; $Preview.Content = 'Preview cleanup'; $Apply.Content = 'Clean reviewed items…'
        }
        'Health' {
            $Heading.Text = 'Windows health'; $Description.Text = 'Run component-store, protected-file and online file-system checks; repair only when selected.'; $Access.Text = 'Administrator permission required. AC power and a quiet maintenance window are checked.'
            $OptionOne.Content = 'After successful repair checks, clean superseded Windows components'; $OptionOne.Visibility = 'Visible'; $OptionOne.IsChecked = $false
            $Notice.Text = 'Run the check first. After repair, review the logs, restart if requested, then explicitly run health checks again to unlock cleanup. No automatic restart or irreversible component base reset occurs.'; $Preview.Content = 'Run health checks'; $Apply.Content = 'Repair Windows…'
        }
        'SystemRepair' {
            $Heading.Text = 'System Corruption Scan'; $Description.Text = 'Run the WinUtil-style disk, protected-file and Windows image repair sequence.'; $Access.Text = 'Administrator permission required. The scan may repair Windows files and DISM may request a restart.'
            $Notice.Text = 'Runs chkdsk /scan /perf, sfc /scannow, then dism /online /cleanup-image /restorehealth. Review the logs, restart if requested, then run Windows health checks to unlock cleanup. No automatic restart occurs.'; $Preview.Visibility = 'Collapsed'; $Apply.Content = 'Run corruption scan…'
        }
        'Dell' {
            $Heading.Text = 'Dell drivers and firmware'; $Description.Text = 'Show installed BIOS information and open the official Dell G5 5590 support page.'; $Access.Text = 'Separate weekly, attended review. No update is downloaded or installed.'
            $Notice.Text = 'Before a BIOS update: verify a backup, connect AC, close apps, have the BitLocker recovery key available, and follow the exact Dell package instructions.'; $Preview.Content = 'Open Dell review'; $Apply.Visibility = 'Collapsed'
        }
    }
    Update-CleanupAvailability
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
    param([switch]$ApplyChanges, [string]$RequestedAction)
    try {
        if ($script:active -and -not $script:active.HasExited) { throw 'Finish the running task first.' }
        $task = $script:lastPage
        $request = @{ Task = $task }
        $requiresAdmin = $false
        $mutationRequested = [bool]$ApplyChanges -or $RequestedAction -in @('Install','Uninstall','UpgradeAll')
        switch ($script:lastPage) {
            'Runbook' {
                if (-not $ApplyChanges) { return }
                $request.Task = 'PreBackupRun'; $request.MinimumAgeDays = Get-CleanupAge
                $request.EmptyRecycleBin = [bool]$OptionOne.IsChecked; $request.ClearDeliveryCache = [bool]$OptionTwo.IsChecked
                $requiresAdmin = $true
            }
            'Audit' { $requiresAdmin = $true }
            'Applications' {
                if ($RequestedAction -eq 'Installed') {
                    $request.Task = 'InstalledApps'
                } elseif ($RequestedAction -eq 'UpgradeAll') {
                    $request.Task = 'UpdateAll'
                } elseif ($RequestedAction -eq 'Uninstall') {
                    $ids = @($ValueInput.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($ids.Count -eq 0) { throw 'Select at least one exact application ID to uninstall.' }
                    $request.Task = 'UpdateUninstall'; $request.ApplicationId = $ids
                } elseif ($RequestedAction -eq 'Install') {
                    $ids = @($ValueInput.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($ids.Count -eq 0) { throw 'Preview the list, then enter at least one exact application ID.' }
                    $request.Task = 'UpdateInstall'; $request.ApplicationId = $ids
                } else { $request.Task = 'UpdatePreview' }
            }
            'Cleanup' {
                $request.MinimumAgeDays = Get-CleanupAge
                if ($ApplyChanges) {
                    if (-not $script:healthReady) { throw 'Run Windows health checks first. Cleanup stays locked until this dashboard session records a healthy result with no restart required.' }
                    $request.Task = 'Clean'; $request.EmptyRecycleBin = [bool]$OptionOne.IsChecked; $request.ClearDeliveryCache = [bool]$OptionTwo.IsChecked; $requiresAdmin = $true
                }
                else { $request.Task = 'CleanPreview' }
            }
            'Health' {
                $requiresAdmin = $true
                if ($ApplyChanges) { $request.Task = 'HealthRepair'; $request.ComponentCleanup = [bool]$OptionOne.IsChecked }
                else { $request.Task = 'HealthCheck' }
            }
            'SystemRepair' {
                $requiresAdmin = $true
                $request.Task = 'SystemRepair'
            }
            'Dell' { $request.Task = 'DellReview' }
        }
        if ($mutationRequested) {
            $choice = [Windows.MessageBox]::Show($window, "Apply the selected $($Heading.Text.ToLowerInvariant()) action? Save work, close applications, connect AC power, and confirm no backup or update is running.", 'Confirm maintenance', 'YesNo', 'Warning')
            if ($choice -ne 'Yes') { return }
        }
        if (-not $script:sessionDirectory) {
            $script:sessionDirectory = Join-Path -Path $runRoot -ChildPath ([datetime]::Now.ToString('yyyyMMdd-HHmmss') + '-session-' + [guid]::NewGuid().ToString('N').Substring(0,8))
            [void][IO.Directory]::CreateDirectory($script:sessionDirectory)
            @('PRE-BACKUP MAINTENANCE SESSION', "Started: $([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))", "Computer: $env:COMPUTERNAME", 'All dashboard tasks from this launch are recorded below.') | Set-Content -LiteralPath (Join-Path -Path $script:sessionDirectory -ChildPath 'session.log') -Encoding UTF8
        }
        $script:taskNumber++
        $taskFolder = '{0:D2}-{1}-{2}' -f $script:taskNumber,$request.Task,[guid]::NewGuid().ToString('N').Substring(0,6)
        $script:runDirectory = Join-Path -Path $script:sessionDirectory -ChildPath $taskFolder
        [void][IO.Directory]::CreateDirectory($runDirectory)
        $requestPath = Join-Path -Path $runDirectory -ChildPath 'request.json'
        $request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -Encoding utf8
        $worker = Join-Path -Path $root -ChildPath 'Invoke-GuiTask.ps1'
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path -Path $PSHOME -ChildPath 'pwsh.exe'))
        $start.UseShellExecute = $true; $start.WindowStyle = 'Hidden'
        if ($requiresAdmin -and -not $isAdmin) { $start.Verb = 'runas' }
        foreach ($argument in @('-NoLogo','-NoProfile','-File',$worker,'-RequestPath',$requestPath)) { [void]$start.ArgumentList.Add($argument) }
        $script:active = [Diagnostics.Process]::Start($start)
        $script:activeTask = [string]$request.Task
        $script:taskStartedAt = [datetime]::Now
        $script:liveActivityState = $null
        $Tasks.IsEnabled = $false; $Options.IsEnabled = $false; $Preview.IsEnabled = $false; $Apply.IsEnabled = $false
        $OpenResults.IsEnabled = $false; $OpenResultFolder.IsEnabled = $false
        $currentStepPath = Join-Path -Path $runDirectory -ChildPath 'GuidedReport\current-step.txt'
        $script:liveActivityState = Get-LiveActivityState -Task $script:activeTask -ConsolePath (Join-Path -Path $runDirectory -ChildPath 'console.txt') -ActivityPath $currentStepPath -StartedAt $script:taskStartedAt
        Set-LiveActivityPresentation -State $script:liveActivityState
        $Console.Text = $script:liveActivityState.ConsoleText
        $Console.ScrollToEnd()
        Set-DashboardStatus -State Running
        Update-CleanupAvailability
    } catch {
        $Console.Text = "Task could not start.`r`n$($_.Exception.Message)"
        Set-DashboardStatus -State ActionNeeded -Label 'ACTION NEEDED — Task could not start'
        [void][Windows.MessageBox]::Show($window, $_.Exception.Message, 'Unable to start', 'OK', 'Error')
    }
}
$RunbookButton.Add_Click({ Show-Page Runbook }); $AuditButton.Add_Click({ Show-Page Audit }); $ApplicationsButton.Add_Click({ Show-Page Applications }); $CleanupButton.Add_Click({ Show-Page Cleanup }); $HealthButton.Add_Click({ Show-Page Health }); $SystemRepairButton.Add_Click({ Show-Page SystemRepair }); $DellButton.Add_Click({ Show-Page Dell })
$Preview.Add_Click({ Start-DashboardTask }); $Apply.Add_Click({ Start-DashboardTask -ApplyChanges })
$InstallUpgradeButton.Add_Click({ Start-DashboardTask -RequestedAction Install }); $UninstallButton.Add_Click({ Start-DashboardTask -RequestedAction Uninstall }); $UpgradeAllButton.Add_Click({ Start-DashboardTask -RequestedAction UpgradeAll }); $ShowInstalledButton.Add_Click({ Start-DashboardTask -RequestedAction Installed }); $ClearSelectionButton.Add_Click({ $ValueInput.Text = '' })
$ValueInput.Add_TextChanged({ if ($script:lastPage -eq 'Applications') { $count = @($ValueInput.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }); $SelectionCount.Text = "Selected Apps: $($count.Count)" } })
$OpenResults.Add_Click({
    $summaryPath = if ($script:runDirectory) { Join-Path -Path $script:runDirectory -ChildPath 'summary.txt' } else { $null }
    if ($summaryPath -and (Test-Path -LiteralPath $summaryPath)) { Start-Process -FilePath $summaryPath }
    elseif ($script:runDirectory -and (Test-Path -LiteralPath $script:runDirectory)) {
        [void][Windows.MessageBox]::Show('No result summary was saved. Opening the result folder instead.', 'Result summary unavailable', 'OK', 'Warning')
        Start-Process -FilePath explorer.exe -ArgumentList ('"' + $script:runDirectory + '"')
    } else { [void][Windows.MessageBox]::Show('Run a task first.') }
})
$OpenResultFolder.Add_Click({
    $resultDirectory = if ($script:runDirectory -and (Test-Path -LiteralPath $script:runDirectory)) { $script:runDirectory } else { $script:sessionDirectory }
    if ($resultDirectory) { Start-Process -FilePath explorer.exe -ArgumentList ('"' + $resultDirectory + '"') }
    else { [void][Windows.MessageBox]::Show('Run a task first.') }
})
$OpenGuide.Add_Click({ Start-Process -FilePath (Join-Path -Path $root -ChildPath 'README.md') })
$timer = [Windows.Threading.DispatcherTimer]::new(); $timer.Interval = [timespan]::FromMilliseconds(700)
$timer.Add_Tick({
    if (-not $script:active) { return }
    try {
        if ($script:active.HasExited) {
            if ($script:taskStartedAt) {
                try {
                    $completedActivity = Get-LiveActivityState -Task $script:activeTask -ConsolePath (Join-Path -Path $runDirectory -ChildPath 'console.txt') -ActivityPath (Join-Path -Path $runDirectory -ChildPath 'GuidedReport\current-step.txt') -StartedAt $script:taskStartedAt -PreviousState $script:liveActivityState
                    $ElapsedTask.Text = "Elapsed: $($completedActivity.ElapsedText)"
                } catch {
                    $fallbackElapsed = [datetime]::Now - $script:taskStartedAt
                    $ElapsedTask.Text = 'Elapsed: {0:D2}:{1:D2}:{2:D2}' -f ([long][Math]::Floor($fallbackElapsed.TotalHours)), $fallbackElapsed.Minutes, $fallbackElapsed.Seconds
                }
            }
            $ActivityProgress.IsIndeterminate = $false
            $ActivityProgress.Value = 0
            $ActivityProgress.Visibility = 'Collapsed'
            $completedRequestPath = Join-Path -Path $runDirectory -ChildPath 'request.json'
            if (Test-Path -LiteralPath $completedRequestPath) {
                $completedRequest = Get-Content -LiteralPath $completedRequestPath -Raw | ConvertFrom-Json
                if ($completedRequest.Task -in @('HealthCheck','HealthRepair','SystemRepair','PreBackupRun')) { $script:healthReady = $false }
            }
            $summaryPath = Join-Path -Path $runDirectory -ChildPath 'summary.txt'
            $hasSummary = Test-Path -LiteralPath $summaryPath
            $CurrentOperation.Text = if ($hasSummary) { 'Current operation: Finished — see saved result' } else { 'Current operation: Finished — result unavailable' }
            $CurrentOperation.ToolTip = $CurrentOperation.Text.Substring('Current operation: '.Length)
            $ActivityProgressText.Text = if ($hasSummary) { 'Result saved' } else { 'Finished' }
            $Console.Text = if ($hasSummary) { Get-Content -LiteralPath $summaryPath -Raw } else { "ACTION NEEDED — No summary was saved.`r`nOpen the result folder for console.txt and report files." }
            $Console.ScrollToHome()
            $finishedPath = Join-Path -Path $runDirectory -ChildPath 'finished.json'
            if (Test-Path -LiteralPath $finishedPath) {
                $finished = Get-Content -LiteralPath $finishedPath -Raw | ConvertFrom-Json
                if ($finished.Task -in @('HealthRepair','SystemRepair')) { $script:healthReady = $false }
                elseif ($finished.Task -in @('HealthCheck','PreBackupRun')) {
                    $script:healthReady = [bool]$finished.HealthReady -and $finished.ExitCode -eq 0
                }
                $displayState = if ($finished.PSObject.Properties['DisplayState']) { [string]$finished.DisplayState } elseif ($finished.RestartRequired) { 'Restart' } elseif ($finished.RepairRecommended) { 'Repair' } elseif ($finished.ExitCode -eq 0) { 'Success' } elseif ($finished.ExitCode -eq 2) { 'Review' } else { 'ActionNeeded' }
                $statusLabel = if ($finished.PSObject.Properties['StatusLabel']) { [string]$finished.StatusLabel } else { $null }
                if ($hasSummary) { Set-DashboardStatus -State $displayState -Label $statusLabel }
                else { Set-DashboardStatus -State ActionNeeded -Label 'ACTION NEEDED — Result summary missing' }
                $script:taskStatus = $Status.Text
                if ($finished.RestartRequired) {
                    $script:healthReady = $false
                    Set-DashboardStatus -State Restart
                    $script:taskStatus = $Status.Text
                    Show-DashboardWarning -Message 'Restart Windows before running cleanup or starting the Veeam backup. After restarting, open the dashboard and begin a new guided run.' -Title 'Restart required' -Icon Stop
                } elseif ($finished.RepairRecommended) {
                    $script:healthReady = $false
                    Set-DashboardStatus -State Repair
                    $script:taskStatus = $Status.Text
                    Show-DashboardWarning -Message 'Windows health checks recommend repair or manual review. Open the saved results and run Repair Windows before cleanup.' -Title 'Repair recommended' -Icon Warning
                }
            } else { Set-DashboardStatus -State ActionNeeded -Label 'ACTION NEEDED — Result metadata missing'; $script:taskStatus = $Status.Text }
            $script:active.Dispose(); $script:active = $null
            $script:activeTask = $null
            $script:taskStartedAt = $null
            $script:liveActivityState = $null
            $Tasks.IsEnabled = $true; $Options.IsEnabled = $true; $Preview.IsEnabled = $true
            $OpenResults.IsEnabled = $true; $OpenResultFolder.IsEnabled = $true
            Update-CleanupAvailability
        } else {
            $activityPath = Join-Path -Path $runDirectory -ChildPath 'console.txt'
            $currentStepPath = Join-Path -Path $runDirectory -ChildPath 'GuidedReport\current-step.txt'
            $script:liveActivityState = Get-LiveActivityState -Task $script:activeTask -ConsolePath $activityPath -ActivityPath $currentStepPath -StartedAt $script:taskStartedAt -PreviousState $script:liveActivityState
            Set-LiveActivityPresentation -State $script:liveActivityState
            $Console.Text = $script:liveActivityState.ConsoleText
            $Console.ScrollToEnd()
        }
    } catch { Set-DashboardStatus -State Running -Label 'RUNNING — Waiting for the next activity update' }
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
    foreach ($page in @('Runbook','Audit','Applications','Cleanup','Health','SystemRepair','Dell')) { Show-Page -Page $page; if ($Heading.Text.Length -eq 0) { throw "Page failed: $page" } }
    Show-Page -Page $UiPage
    if ($UiPage -eq 'Cleanup') {
        foreach ($invalid in @('0','6','366','1.5','abc')) { $ValueInput.Text = $invalid; $rejected = $false; try { Get-CleanupAge | Out-Null } catch { $rejected = $true }; if (-not $rejected) { throw "Invalid age accepted: $invalid" } }
        $ValueInput.Text = '14'; if ((Get-CleanupAge) -ne 14) { throw 'Valid cleanup age rejected.' }
    }
    Set-DashboardStatus -State $UiState
    if ($UiState -eq 'Running') {
        $CurrentOperation.Text = 'Current operation: DISM-Health: Restoring the component store'
        $ElapsedTask.Text = 'Elapsed: 00:01:42'
        $ActivityProgress.IsIndeterminate = $false
        $ActivityProgress.Value = 42.5
        $ActivityProgressText.Text = '42.5%'
        $Console.Text = @('[RUNNING] DISM-Health: Restoring the component store','[=================42.5%=================]','Restoring the Windows component store…','Detailed output continues in the saved console log.') -join [Environment]::NewLine
    } elseif ($UiState -ne 'Idle') {
        $style = Get-DashboardStateStyle -State $UiState
        $CurrentOperation.Text = 'Current operation: Finished — see saved result'
        $ElapsedTask.Text = 'Elapsed: 00:06:18'
        $ActivityProgress.IsIndeterminate = $false
        $ActivityProgress.Value = 0
        $ActivityProgress.Visibility = 'Collapsed'
        $ActivityProgressText.Text = 'Result saved'
        $Console.Text = @($style.Label,'Task: PreBackupRun','Finished: 2026-09-23 10:11:12','Next: Review the saved result before continuing.','Detailed output: C:\GuiRuns\fixture\console.txt','Results: C:\GuiRuns\fixture') -join [Environment]::NewLine
        $OpenResults.IsEnabled = $true; $OpenResultFolder.IsEnabled = $true
    }
    $surface = $window.Content; $surface.Measure([Windows.Size]::new(1080,790)); $surface.Arrange([Windows.Rect]::new(0,0,1080,790)); $surface.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(1080,790,96,96,[Windows.Media.PixelFormats]::Pbgra32); $bitmap.Render($surface)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create([IO.Path]::GetFullPath($UiTestOutput)); try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $resultActionState = if ($OpenResults.IsEnabled -and $OpenResultFolder.IsEnabled) { 'enabled' } else { 'disabled' }
    Write-Output "PASS: seven dashboard pages and the $UiState state rendered. $($CurrentOperation.Text); Progress: $($ActivityProgressText.Text); Result actions: $resultActionState. Cleanup input limits were validated. No maintenance ran."
} else { $timer.Start(); try { [void]$window.ShowDialog() } finally { $timer.Stop() } }
