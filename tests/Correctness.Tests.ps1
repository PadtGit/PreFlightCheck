[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester and extracted production script blocks consume fixture variables in child scopes.')]
param()

BeforeAll {
    $repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $maintenancePath = Join-Path $repositoryRoot 'PreBackupMaintenance.ps1'
    $dashboardPath = Join-Path $repositoryRoot 'Start-Maintenance.ps1'
    $maintenanceAst = [System.Management.Automation.Language.Parser]::ParseFile($maintenancePath, [ref]$null, [ref]$null)
    $dashboardAst = [System.Management.Automation.Language.Parser]::ParseFile($dashboardPath, [ref]$null, [ref]$null)
    $script:taskStatus = 'Ready'
    foreach ($functionName in @('Get-DashboardStateStyle', 'Update-CleanupAvailability', 'Show-DashboardWarning')) {
        $node = $dashboardAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $functionName }, $true)
        if ($node) { . ([scriptblock]::Create($node.Extent.Text)) }
    }
    function Set-DashboardStatus {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test adapter updates only a fixture control and performs no system state changes.')]
        [CmdletBinding()]
        param([string]$State, [string]$Label)
        if ($Label) { $Status.Text = $Label; return }
        $Status.Text = (Get-DashboardStateStyle -State $State).Label
    }
    # Execute the actual orchestration branches without the inventory/bootstrap or native tools.
    # AST selection is a test seam, not a source-text assertion.
    $modeBlocks = @{}
    foreach ($modeName in @('SystemRepair', 'Health', 'Updates')) {
        $condition = '$Mode -eq ''' + $modeName + ''''
        $node = $maintenanceAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.IfStatementAst] -and $ast.Clauses[0].Item1.Extent.Text -eq $condition }, $true)
        $modeBlocks[$modeName] = [scriptblock]::Create($node.Extent.Text)
    }
    foreach ($functionName in @('Add-Result', 'Invoke-LoggedProgram')) {
        $node = $maintenanceAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $functionName }, $true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    Import-Module (Join-Path $repositoryRoot 'Maintenance.Core.psm1') -Force

    function Invoke-ModeFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are consumed by the dot-sourced production mode branch.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'The dot-sourced production branch calls this fixture function PSCmdlet.ShouldProcess, exercising real WhatIf behavior.')]
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Mode, [switch]$RepairWindows, [switch]$ComponentCleanup, [switch]$UpgradeAll, [switch]$Uninstall, [switch]$ShowInstalled, [string[]]$ApplicationId = @())
        $OpenUpdatePages = $false
        . $modeBlocks[$Mode]
    }
}

Describe 'Health gate behavior' {
    BeforeEach {
        $script:runDirectory = $TestDrive
        $script:report = [pscustomobject]@{
            HealthReady = $false; RepairRecommended = $false; RestartRequired = $false; RestartAfter = $null
            Restart = [pscustomobject]@{ Pending = $false; Unknown = @() }
            Results = [System.Collections.Generic.List[object]]::new()
            VolumesBefore = @([pscustomobject]@{ DriveType = 'Fixed'; DriveLetter = 'C'; FileSystem = 'NTFS' })
        }
        $script:diskCode = 0
        $script:repairCode = 0
        $script:restartPending = $false
        $script:nativeCalls = [System.Collections.Generic.List[string]]::new()
        Mock Get-PendingRestartState { [pscustomobject]@{ Pending = $script:restartPending; Unknown = @() } }
        Mock Invoke-LoggedProgram {
            param($Name, $AcceptedCodes = @(0))
            $script:nativeCalls.Add($Name)
            $code = 0
            if ($Name -like '*CHKDSK*') { $code = $script:diskCode }
            if ($Name -eq 'SystemRepair-DISM') { $code = $script:repairCode }
            if ($code -notin $AcceptedCodes) { throw "$Name returned $code" }
            if ($Name -eq 'DISM-Health') { Set-Content (Join-Path $script:runDirectory 'DISM-Health.txt') 'No component store corruption detected.' }
            if ($Name -eq 'SFC') { Set-Content (Join-Path $script:runDirectory 'SFC.txt') 'Windows Resource Protection did not find any integrity violations.' }
            return $code
        }
    }

    It 'keeps cleanup locked after a successful SystemRepair and asks for a normal health check' {
        Invoke-ModeFixture -Mode SystemRepair
        $report.HealthReady | Should -BeFalse
        @($report.Results | Where-Object { $_.Step -eq 'HealthGate' -and $_.Status -eq 'Review' }).Count | Should -Be 1
    }

    It 'requires review for SystemRepair CHKDSK exit <Code>' -ForEach @(@{ Code = 1 }, @{ Code = 2 }) {
        $script:diskCode = $Code
        Invoke-ModeFixture -Mode SystemRepair
        $report.HealthReady | Should -BeFalse
        @($report.Results | Where-Object { $_.Step -eq 'SystemRepair-CHKDSK' -and $_.Status -eq 'Review' }).Count | Should -Be 1
        $nativeCalls | Should -Contain 'SystemRepair-DISM'
    }

    It 'preserves the restart requirement when SystemRepair DISM returns 3010' {
        $script:repairCode = 3010
        Invoke-ModeFixture -Mode SystemRepair
        $report.RestartRequired | Should -BeTrue
        $report.HealthReady | Should -BeFalse
    }

    It 'rechecks restart markers after SystemRepair' {
        $script:restartPending = $true
        Invoke-ModeFixture -Mode SystemRepair
        $report.RestartRequired | Should -BeTrue
        $report.HealthReady | Should -BeFalse
    }

    It 'unlocks cleanup after a completed normal health check' {
        Invoke-ModeFixture -Mode Health
        $report.HealthReady | Should -BeTrue
        $nativeCalls | Should -Contain 'CHKDSK-C'
    }

    It 'keeps cleanup locked when no fixed NTFS volume can be checked: <Inventory>' -ForEach @(
        @{ Inventory = 'empty inventory'; Volumes = @() }
        @{ Inventory = 'no drive letter'; Volumes = @(@{ DriveType = 'Fixed'; DriveLetter = $null; FileSystem = 'NTFS' }) }
        @{ Inventory = 'unsupported file system'; Volumes = @(@{ DriveType = 'Fixed'; DriveLetter = 'C'; FileSystem = 'ReFS' }) }
        @{ Inventory = 'removable volume'; Volumes = @(@{ DriveType = 'Removable'; DriveLetter = 'E'; FileSystem = 'NTFS' }) }
    ) {
        $report.VolumesBefore = @($Volumes | ForEach-Object { [pscustomobject]$_ })
        Invoke-ModeFixture -Mode Health
        $report.HealthReady | Should -BeFalse
        $volumeReview = @($report.Results | Where-Object { $_.Step -eq 'FileSystemChecks' -and $_.Status -eq 'Review' })
        $volumeReview.Count | Should -Be 1
        $volumeReview[0].Detail | Should -Match 'No eligible.*NTFS volume'
        @($nativeCalls | Where-Object { $_ -like 'CHKDSK-*' }).Count | Should -Be 0
    }

    It 'checks every eligible fixed NTFS volume before unlocking cleanup' {
        $report.VolumesBefore = @(
            [pscustomobject]@{ DriveType = 'Fixed'; DriveLetter = 'C'; FileSystem = 'NTFS' }
            [pscustomobject]@{ DriveType = 'Fixed'; DriveLetter = 'D'; FileSystem = 'NTFS' }
        )
        Invoke-ModeFixture -Mode Health
        $report.HealthReady | Should -BeTrue
        @($nativeCalls | Where-Object { $_ -like 'CHKDSK-*' }) -join '|' | Should -Be 'CHKDSK-C|CHKDSK-D'
    }

    It 'does not unlock cleanup from a Health WhatIf that runs no checks' {
        Invoke-ModeFixture -Mode Health -WhatIf
        $report.HealthReady | Should -BeFalse
        $nativeCalls.Count | Should -Be 0
    }

    It 'requires a separate normal health check after Health repair' {
        Invoke-ModeFixture -Mode Health -RepairWindows
        $report.HealthReady | Should -BeFalse
        @($report.Results | Where-Object { $_.Step -eq 'HealthGate' -and $_.Status -eq 'Review' }).Count | Should -Be 1
    }

    It 'does not unlock cleanup if an essential inventory check already failed' {
        $report.Results.Add([pscustomobject]@{ Step = 'Storage'; Status = 'Failed'; Detail = 'Inventory unavailable' })
        Invoke-ModeFixture -Mode Health
        $report.HealthReady | Should -BeFalse
    }

    It 'does not unlock cleanup while a recorded observation needs review' {
        $report.Results.Add([pscustomobject]@{ Step = 'Disk'; Status = 'Review'; Detail = 'Disk needs review' })
        Invoke-ModeFixture -Mode Health
        $report.HealthReady | Should -BeFalse
    }

    It 'requires review for normal Health CHKDSK exit <Code>' -ForEach @(@{ Code = 1 }, @{ Code = 2 }) {
        $script:diskCode = $Code
        { Invoke-ModeFixture -Mode Health } | Should -Not -Throw
        $report.HealthReady | Should -BeFalse
        @($report.Results | Where-Object { $_.Step -eq 'CHKDSK-C' -and $_.Status -eq 'Review' }).Count | Should -Be 1
    }
}

Describe 'Applications preview behavior' {
    BeforeAll {
        $showPage = $dashboardAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq 'Show-Page' }, $true)
        . ([scriptblock]::Create($showPage.Extent.Text))
        $startTask = $dashboardAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq 'Start-DashboardTask' }, $true)
        $requestSwitch = $startTask.Find({ param($ast) $ast -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)
        $requestMapping = [scriptblock]::Create($requestSwitch.Extent.Text)
        $previewClick = $dashboardAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $ast.Expression.Extent.Text -eq '$Preview' -and $ast.Member.Value -eq 'Add_Click' }, $true)
        $previewHandler = $previewClick.Arguments[0].ScriptBlock.GetScriptBlock()
        function Start-DashboardTask {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are consumed by the dot-sourced production request mapping.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This test double only returns a request from the real mapping; it never launches a task.')]
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([switch]$ApplyChanges, [string]$RequestedAction)
            $request = @{}
            . $requestMapping
            return $request
        }
    }

    It 'exposes a visible preview action that maps to UpdatePreview with no mutation switches' {
        $script:active = $null
        $script:taskStatus = 'Ready'
        foreach ($name in @('ApplicationActions','SelectionCount','ValueInput','InputLabel','OptionOne','OptionTwo','NoticeBorder','Preview','Apply','Heading','Description','Access','Notice','Status')) {
            Set-Variable -Name $name -Value ([pscustomobject]@{ Visibility = ''; Text = ''; Content = ''; IsChecked = $false; IsEnabled = $true })
        }
        Show-Page -Page Applications
        $Preview.Visibility | Should -Be 'Visible'
        $Preview.Content | Should -Be 'Preview available updates'
        $request = & $previewHandler
        $request.Task | Should -Be 'UpdatePreview'
        $request.ContainsKey('ApplicationId') | Should -BeFalse
    }

    It 'emits the saved available-update list into result output while retaining its complete log' {
        $script:runDirectory = $TestDrive
        $script:report = [pscustomobject]@{ Results = [System.Collections.Generic.List[object]]::new(); Software = @() }
        $script:previewText = "Name  Id  Version  Available`r`nExample  Example.App  1.0  2.0"
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like 'HK*' }
        Mock Get-Item { [pscustomobject]@{ FullName = (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe') } }
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation' } } }
        Mock Invoke-LoggedProgram {
            param($Name)
            Set-Content -LiteralPath (Join-Path $script:runDirectory ($Name + '.txt')) -Value $script:previewText
            return 0
        }
        $output = Invoke-ModeFixture -Mode Updates 6>&1 | Out-String
        $output | Should -Match 'Example.App'
        ($report.Results | Where-Object { $_.Step -eq 'AvailableAppUpdatesOutput' }).Detail | Should -Be $previewText
        (Get-Content (Join-Path $runDirectory 'AvailableAppUpdates.txt') -Raw).Trim() | Should -Be $previewText
    }
}

Describe 'Dashboard health eligibility from completed tasks' {
    BeforeAll {
        $tick = $dashboardAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $ast.Expression.Extent.Text -eq '$timer' -and $ast.Member.Value -eq 'Add_Tick' }, $true)
        $completionHandler = $tick.Arguments[0].ScriptBlock.GetScriptBlock()
    }

    BeforeEach {
        $script:runDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:runDirectory)
        $script:healthReady = $true
        $script:lastPage = 'Health'
        $script:taskStartedAt = $null
        $script:liveActivityState = $null
        $script:active = [pscustomobject]@{ HasExited = $true }
        $script:active | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        $Console = [pscustomobject]@{ Text = '' }
        $Console | Add-Member -MemberType ScriptMethod -Name ScrollToHome -Value { }
        $Status = [pscustomobject]@{ Text = '' }
        foreach ($name in @('CurrentOperation','ElapsedTask','ActivityProgressText')) { Set-Variable -Name $name -Value ([pscustomobject]@{ Text = ''; ToolTip = '' }) }
        $ActivityProgress = [pscustomobject]@{ IsIndeterminate = $true; Value = 25; Visibility = 'Visible' }
        foreach ($name in @('Tasks','Options','Preview','Apply','OpenResults','OpenResultFolder')) { Set-Variable -Name $name -Value ([pscustomobject]@{ IsEnabled = $false }) }
        Set-Content (Join-Path $runDirectory 'summary.txt') 'Fixture summary'
    }

    It 'clears stale readiness for <Task> even if a legacy report claims readiness' -ForEach @(@{ Task = 'SystemRepair' }, @{ Task = 'HealthRepair' }) {
        @{ Task = $Task; ExitCode = 0; HealthReady = $true; RestartRequired = $false; RepairRecommended = $false } | ConvertTo-Json | Set-Content (Join-Path $runDirectory 'finished.json')
        & $completionHandler
        $script:healthReady | Should -BeFalse
    }

    It 'rejects HealthCheck readiness when completion has exit <Code>' -ForEach @(@{ Code = 1 }, @{ Code = 2 }) {
        @{ Task = 'HealthCheck'; ExitCode = $Code; HealthReady = $true; RestartRequired = $false; RepairRecommended = $false } | ConvertTo-Json | Set-Content (Join-Path $runDirectory 'finished.json')
        & $completionHandler
        $script:healthReady | Should -BeFalse
    }

    It 'accepts a completed healthy normal HealthCheck' {
        $script:healthReady = $false
        @{ Task = 'HealthCheck'; ExitCode = 0; HealthReady = $true; RestartRequired = $false; RepairRecommended = $false } | ConvertTo-Json | Set-Content (Join-Path $runDirectory 'finished.json')
        & $completionHandler
        $script:healthReady | Should -BeTrue
    }

    It 'clears stale readiness when a repair worker exits without saving finished.json' {
        @{ Task = 'SystemRepair' } | ConvertTo-Json | Set-Content (Join-Path $runDirectory 'request.json')
        & $completionHandler
        $script:healthReady | Should -BeFalse
    }
}

Describe 'Cleanup action availability' {
    BeforeAll {
        $showPage = $dashboardAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq 'Show-Page' }, $true)
        . ([scriptblock]::Create($showPage.Extent.Text))
        $tick = $dashboardAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $ast.Expression.Extent.Text -eq '$timer' -and $ast.Member.Value -eq 'Add_Tick' }, $true)
        $completionHandler = $tick.Arguments[0].ScriptBlock.GetScriptBlock()
    }

    BeforeEach {
        $script:runDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:runDirectory)
        $script:active = $null
        $script:healthReady = $false
        $script:taskStatus = 'Ready'
        $script:taskStartedAt = $null
        $script:liveActivityState = $null
        $ActivityProgress = [pscustomobject]@{ IsIndeterminate = $true; Value = 25; Visibility = 'Visible' }
        foreach ($name in @('ApplicationActions','SelectionCount','ValueInput','InputLabel','OptionOne','OptionTwo','NoticeBorder','Preview','Apply','Heading','Description','Access','Notice','Tasks','Options','Status','OpenResults','OpenResultFolder','CurrentOperation','ElapsedTask','ActivityProgressText')) {
            Set-Variable -Name $name -Value ([pscustomobject]@{ Visibility = ''; Text = ''; ToolTip = ''; Content = ''; IsChecked = $false; IsEnabled = $true })
        }
        $Status.Text = 'Ready'
        $Console = [pscustomobject]@{ Text = '' }
        $Console | Add-Member -MemberType ScriptMethod -Name ScrollToHome -Value { }
        Set-Content (Join-Path $runDirectory 'summary.txt') 'Fixture completion'
    }

    It 'disables locked cleanup with explicit status while keeping preview available' {
        Show-Page -Page Cleanup
        $Apply.IsEnabled | Should -BeFalse
        $Apply.Content | Should -Match 'locked'
        $Access.Text | Should -Match 'CLEANUP LOCKED'
        $Status.Text | Should -Match 'CLEANUP LOCKED'
        $Preview.IsEnabled | Should -BeTrue
        $Preview.Visibility | Should -Be 'Visible'
    }

    It 'refreshes locked cleanup after a qualifying normal HealthCheck completes' {
        Show-Page -Page Cleanup
        $Apply.IsEnabled | Should -BeFalse
        $script:active = [pscustomobject]@{ HasExited = $true }
        $script:active | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        @{ Task = 'HealthCheck'; ExitCode = 0; HealthReady = $true; RestartRequired = $false; RepairRecommended = $false } | ConvertTo-Json | Set-Content (Join-Path $runDirectory 'finished.json')
        & $completionHandler
        $script:active | Should -BeNullOrEmpty
        $Apply.IsEnabled | Should -BeTrue
        $Apply.Content | Should -Not -Match 'locked'
        $Access.Text | Should -Not -Match 'CLEANUP LOCKED'
    }

    It 'clears the cleanup-only idle label when navigating to Windows health' {
        Show-Page -Page Cleanup
        Show-Page -Page Health
        $Apply.IsEnabled | Should -BeTrue
        $Status.Text | Should -Be 'Ready'
    }

    It 'relocks cleanup while preserving the <Warning> warning after task completion' -ForEach @(
        @{ Warning = 'RESTART — Required before cleanup or backup'; Restart = $true; Repair = $false; Code = 0 }
        @{ Warning = 'REPAIR — Windows repair recommended'; Restart = $false; Repair = $true; Code = 0 }
        @{ Warning = 'ACTION NEEDED — Open the saved result'; Restart = $false; Repair = $false; Code = 1 }
    ) {
        Mock Show-DashboardWarning { }
        $script:healthReady = $true
        Show-Page -Page Cleanup
        $script:active = [pscustomobject]@{ HasExited = $true }
        $script:active | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        @{ Task = 'HealthCheck'; ExitCode = $Code; HealthReady = $true; RestartRequired = $Restart; RepairRecommended = $Repair } | ConvertTo-Json | Set-Content (Join-Path $runDirectory 'finished.json')
        & $completionHandler
        $script:active | Should -BeNullOrEmpty
        $Apply.IsEnabled | Should -BeFalse
        $Status.Text | Should -Match "CLEANUP LOCKED.*$Warning"
        $Preview.IsEnabled | Should -BeTrue
        Show-Page -Page Health
        $Status.Text | Should -BeLike "$Warning*"
    }

    It 'relocks cleanup after <Task> exits with code <Code>' -ForEach @(
        @{ Task = 'SystemRepair'; Code = 0 }
        @{ Task = 'HealthRepair'; Code = 0 }
        @{ Task = 'HealthCheck'; Code = 1 }
        @{ Task = 'HealthCheck'; Code = 2 }
    ) {
        $script:healthReady = $true
        Show-Page -Page Cleanup
        $Apply.IsEnabled | Should -BeTrue
        $script:active = [pscustomobject]@{ HasExited = $true }
        $script:active | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        @{ Task = $Task; ExitCode = $Code; HealthReady = $true; RestartRequired = $false; RepairRecommended = $false } | ConvertTo-Json | Set-Content (Join-Path $runDirectory 'finished.json')
        & $completionHandler
        $script:active | Should -BeNullOrEmpty
        $Apply.IsEnabled | Should -BeFalse
        $Apply.Content | Should -Match 'locked'
        $Status.Text | Should -Match 'CLEANUP LOCKED'
        $Preview.IsEnabled | Should -BeTrue
    }
}

Describe 'WinGet native command contracts' {
    BeforeEach {
        $script:runDirectory = $TestDrive
        $script:report = [pscustomobject]@{ Results = [System.Collections.Generic.List[object]]::new(); Software = @(); RestartRequired = $false }
        $script:commandCalls = [System.Collections.Generic.List[object]]::new()
        $script:restartAfterMutation = $false
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like 'HK*' }
        Mock Get-Item { [pscustomobject]@{ FullName = (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe') } }
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation' } } }
        Mock Invoke-LoggedProgram {
            param($Name, $Arguments)
            $script:commandCalls.Add([pscustomobject]@{ Name = $Name; Arguments = $Arguments })
            Set-Content -LiteralPath (Join-Path $script:runDirectory ($Name + '.txt')) -Value 'Fixture WinGet output'
            return 0
        }
        Mock Get-PendingRestartState {
            $script:commandCalls.Add([pscustomobject]@{ Name = 'RestartCheck'; Arguments = @() })
            [pscustomobject]@{ Pending = $script:restartAfterMutation; Unknown = @() }
        }
    }

    It 'previews upgrades without mutation flags' {
        Invoke-ModeFixture -Mode Updates
        $commandCalls.Count | Should -Be 1
        ($commandCalls[0].Arguments -join '|') | Should -Be 'upgrade|--disable-interactivity'
    }

    It 'uses exact selected-package arguments and checks restart after <Action>' -ForEach @(
        @{ Action = 'install'; UninstallFlag = $false; CommandName = 'InstallUpgrade-Example.App' }
        @{ Action = 'uninstall'; UninstallFlag = $true; CommandName = 'Uninstall-Example.App' }
    ) {
        Invoke-ModeFixture -Mode Updates -ApplicationId 'Example.App' -Uninstall:$UninstallFlag
        $commandCalls[1].Name | Should -Be $CommandName
        ($commandCalls[1].Arguments -join '|') | Should -Be "$Action|--id|Example.App|--exact|--disable-interactivity"
        $commandCalls[2].Name | Should -Be 'RestartCheck'
    }

    It 'checks restart after upgrade-all and records its pending restart' {
        $script:restartAfterMutation = $true
        Invoke-ModeFixture -Mode Updates -UpgradeAll
        ($commandCalls[1].Arguments -join '|') | Should -Be 'upgrade|--all|--disable-interactivity'
        $commandCalls[2].Name | Should -Be 'RestartCheck'
        $report.RestartRequired | Should -BeTrue
    }

    It 'stops further selected-package changes when the first action leaves a pending restart' {
        $script:restartAfterMutation = $true
        { Invoke-ModeFixture -Mode Updates -ApplicationId @('Example.App','Other.App') } | Should -Throw '*pending or unknown restart*'
        $commandCalls.Count | Should -Be 3
        $commandCalls[2].Name | Should -Be 'RestartCheck'
    }

    It 'reports restart readiness truthfully after a selected package mutation' {
        $script:restartAfterMutation = $true
        { Invoke-ModeFixture -Mode Updates -ApplicationId 'Example.App' } | Should -Throw '*pending or unknown restart*'
        $report.RestartRequired | Should -BeTrue
        @($report.Results | Where-Object { $_.Step -eq 'RestartAfterUpdate' -and $_.Status -eq 'Review' }).Count | Should -Be 1
    }

    It 'rejects an empty uninstall before native commands or inventory can start' {
        $node = $maintenanceAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.IfStatementAst] -and $ast.Clauses[0].Item1.Extent.Text -eq '$Uninstall -and $ApplicationId.Count -eq 0' }, $true)
        $Uninstall = $true
        $ApplicationId = @()
        { . ([scriptblock]::Create($node.Extent.Text)) } | Should -Throw '*Uninstall requires at least one exact application ID*'
        $commandCalls.Count | Should -Be 0
    }
}

Describe 'Guided run health status' {
    BeforeAll {
        $guidedPath = Join-Path $repositoryRoot 'Invoke-PreBackupRun.ps1'
        $guidedAst = [System.Management.Automation.Language.Parser]::ParseFile($guidedPath, [ref]$null, [ref]$null)
        $guidedTry = $guidedAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.TryStatementAst] }, $true)
        # Execute the health-result guards between the actual health request and update preview.
        $healthStatements = @($guidedTry.Body.Statements)
        $startIndex = 0
        $endIndex = 0
        for ($index = 0; $index -lt $healthStatements.Count; $index++) {
            if ($healthStatements[$index] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $healthStatements[$index].Left.Extent.Text -eq '$health') { $startIndex = $index + 1 }
            if ($healthStatements[$index].Extent.Text -like '*03-WinGetPreview*') { $endIndex = $index - 1; break }
        }
        $guidedHealthGate = [scriptblock]::Create(($healthStatements[$startIndex..$endIndex].Extent.Text -join [Environment]::NewLine))
    }

    It 'asks for health review without claiming repair when the repair flag is false' {
        $health = [pscustomobject]@{ HealthReady = $false; RepairRecommended = $false; RestartRequired = $false }
        { . $guidedHealthGate } | Should -Throw 'HEALTH REVIEW REQUIRED*'
    }

    It 'preserves the repair recommendation when the repair flag is true' {
        $health = [pscustomobject]@{ HealthReady = $false; RepairRecommended = $true; RestartRequired = $false }
        { . $guidedHealthGate } | Should -Throw 'WINDOWS REPAIR RECOMMENDED*'
    }
}

Describe 'Final serialized health eligibility' {
    BeforeAll {
        $mainTry = $maintenanceAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } | Select-Object -First 1
        $finalizeReport = [scriptblock]::Create(($mainTry.Finally.Statements.Extent.Text -join [Environment]::NewLine))
    }

    It 'invalidates readiness before saving a report with <Condition>' -ForEach @(
        @{ Condition = 'late inventory failure'; InventoryFails = $true; ResultStatus = 'Observed'; Restart = $false; Repair = $false }
        @{ Condition = 'review result'; InventoryFails = $false; ResultStatus = 'Review'; Restart = $false; Repair = $false }
        @{ Condition = 'failed result'; InventoryFails = $false; ResultStatus = 'Failed'; Restart = $false; Repair = $false }
        @{ Condition = 'required restart'; InventoryFails = $false; ResultStatus = 'Observed'; Restart = $true; Repair = $false }
        @{ Condition = 'repair recommendation'; InventoryFails = $false; ResultStatus = 'Observed'; Restart = $false; Repair = $true }
    ) {
        $script:runDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:runDirectory)
        $script:report = [pscustomobject]@{
            HealthReady = $true; RestartRequired = $Restart; RepairRecommended = $Repair
            Results = [System.Collections.Generic.List[object]]::new()
            VolumesBefore = @(); VolumesAfter = @(); SpaceChange = @()
        }
        $report.Results.Add([pscustomobject]@{ Step = 'Fixture'; Status = $ResultStatus; Detail = $Condition })
        $script:inventoryFails = $InventoryFails
        Mock Get-Volume { if ($script:inventoryFails) { throw 'Fixture final inventory unavailable' } }
        $locked = $false
        $mutex = [pscustomobject]@{}
        $mutex | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        . $finalizeReport
        $saved = Get-Content (Join-Path $runDirectory 'report.json') -Raw | ConvertFrom-Json
        $saved.HealthReady | Should -BeFalse
        if ($InventoryFails) { @($saved.Results | Where-Object { $_.Step -eq 'FinalSpace' -and $_.Status -eq 'Review' }).Count | Should -Be 1 }
    }
}
