[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester resolves variables assigned in BeforeAll inside later It blocks; static analysis does not follow that framework scope.')]
param()

BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot

    function Import-ScriptFunction {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Name
        )

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "Unable to parse ${Path}: $($errors[0].Message)" }

        $definition = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
        if (-not $definition) { throw "Function $Name was not found in $Path." }

        Set-Item -Path "Function:\global:$Name" -Value $definition.Body.GetScriptBlock() -Force
    }

    $workerPath = Join-Path $repositoryRoot 'Invoke-GuiTask.ps1'
    $dashboardPath = Join-Path $repositoryRoot 'Start-Maintenance.ps1'
    $dashboardCorePath = Join-Path $repositoryRoot 'Dashboard.Core.psm1'
    $guidedRunPath = Join-Path $repositoryRoot 'Invoke-PreBackupRun.ps1'
    Import-Module -Name $dashboardCorePath -Force -ErrorAction Stop
    Import-ScriptFunction -Path $workerPath -Name 'Receive-ProcessOutput'
    Import-ScriptFunction -Path $guidedRunPath -Name 'Write-RunLog'
}

AfterAll {
    Remove-Module -Name Dashboard.Core -Force -ErrorAction SilentlyContinue
    foreach ($name in @('Receive-ProcessOutput','Write-RunLog')) {
        Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'Dashboard core module' {
    It 'exports the pure dashboard and worker presentation helpers' {
        foreach ($name in @('Get-DashboardStateStyle','Get-GuiResultPresentation','Format-GuiTaskSummary','Get-LiveActivityState','Get-LiveActivityText')) {
            (Get-Command -Name $name -Module Dashboard.Core -ErrorAction Stop).Name | Should -Be $name
        }
    }
}

Describe 'Dashboard result presentation' {
    It 'uses restart and repair states ahead of generic exit-code states' {
        $restart = Get-GuiResultPresentation -ExitCode 2 -RestartRequired $true -RepairRecommended $true -ReviewFindingCount 3
        $repair = Get-GuiResultPresentation -ExitCode 2 -RepairRecommended $true -ReviewFindingCount 3

        $restart.State | Should -Be 'Restart'
        $restart.StatusLabel | Should -Be 'RESTART — Required before cleanup or backup'
        $repair.State | Should -Be 'Repair'
        $repair.StatusLabel | Should -Be 'REPAIR — Windows repair recommended'
    }

    It 'maps exit codes 0, 1, and 2 to explicit success, action-needed, and review labels' {
        $success = Get-GuiResultPresentation -ExitCode 0
        $action = Get-GuiResultPresentation -ExitCode 1
        $review = Get-GuiResultPresentation -ExitCode 2 -ReviewFindingCount 2

        $success.State | Should -Be 'Success'
        $success.StatusLabel | Should -Be 'SUCCESS — Task completed'
        $action.State | Should -Be 'ActionNeeded'
        $action.StatusLabel | Should -Be 'ACTION NEEDED — Task stopped (exit code 1)'
        $review.State | Should -Be 'Review'
        $review.StatusLabel | Should -Be 'REVIEW — 2 findings need attention'
    }

    It 'keeps the final summary concise and points to detailed output and finding reports' {
        $presentation = Get-GuiResultPresentation -ExitCode 2 -ReviewFindingCount 1
        $finding = [pscustomobject]@{ Step = '01-SystemReview'; Check = 'Storage'; Detail = 'Disk needs attention'; Report = 'C:\fixture\report.json' }

        $summary = Format-GuiTaskSummary -Presentation $presentation -Task 'PreBackupRun' -Finished ([datetime]'2026-09-23T10:11:12') -ReviewFindings @($finding) -RunDirectory 'C:\fixture\run' -ConsolePath 'C:\fixture\run\console.txt'

        $summary | Should -Match '^REVIEW — 1 finding needs attention'
        $summary | Should -Match '01-SystemReview / Storage: Disk needs attention'
        $summary | Should -Match 'Report: C:\\fixture\\report.json'
        $summary | Should -Match 'Detailed output: C:\\fixture\\run\\console.txt'
        $summary | Should -Match 'Results: C:\\fixture\\run'
        ($summary -split '\r?\n').Count | Should -BeLessOrEqual 10
    }
}

Describe 'Dashboard state and live activity' {
    It 'gives every operator state a readable label and supplementary color' {
        $expected = @{
            Idle = 'IDLE — Ready'
            Running = 'RUNNING — Maintenance in progress'
            Success = 'SUCCESS — Task completed'
            Review = 'REVIEW — Open the saved report'
            ActionNeeded = 'ACTION NEEDED — Open the saved result'
            Restart = 'RESTART — Required before cleanup or backup'
            Repair = 'REPAIR — Windows repair recommended'
        }

        foreach ($state in $expected.Keys) {
            $style = Get-DashboardStateStyle -State $state
            $style.Label | Should -Be $expected[$state]
            $style.Foreground | Should -Match '^#[0-9A-F]{6}$'
            $style.Border | Should -Match '^#[0-9A-F]{6}$'
        }
    }

    It 'shows the current guided step and only the latest activity lines' {
        $consolePath = Join-Path $TestDrive 'console.txt'
        $activityPath = Join-Path $TestDrive 'current-step.txt'
        1..15 | ForEach-Object { "activity line $_" } | Set-Content -LiteralPath $consolePath -Encoding UTF8
        'START 02-WindowsHealth' | Set-Content -LiteralPath $activityPath -Encoding UTF8

        $activity = Get-LiveActivityText -Task 'PreBackupRun' -ConsolePath $consolePath -ActivityPath $activityPath -MaximumLines 6

        $activity | Should -Match '^RUNNING — PreBackupRun'
        $activity | Should -Match 'Current step: START 02-WindowsHealth'
        $activity | Should -Match 'activity line 10'
        $activity | Should -Match 'activity line 15'
        $activity | Should -Not -Match 'activity line 9(?:\r?\n|$)'
        $activity | Should -Match ([regex]::Escape($consolePath))
    }

    It 'reads real <Tool> progress from the active operation' -ForEach @(
        @{ Tool = 'DISM';   Marker = '[RUNNING] DISM-Health: Restoring the component store'; ExpectedOperation = 'DISM-Health: Restoring the component store'; Line = '[=================42.5%=================]'; Expected = 42.5 }
        @{ Tool = 'SFC';    Marker = '[RUNNING] SFC: Verifying protected files';             ExpectedOperation = 'SFC: Verifying protected files';             Line = 'Verification 18% complete.'; Expected = 18.0 }
        @{ Tool = 'CHKDSK'; Marker = '[RUNNING] CHKDSK-C: Scanning the file system';          ExpectedOperation = 'CHKDSK-C: Scanning the file system';          Line = 'Stage 4: 73 percent complete.'; Expected = 73.0 }
        @{ Tool = 'WinGet'; Marker = '[RUNNING] WinGet: Downloading selected package';        ExpectedOperation = 'WinGet: Downloading selected package';        Line = "`e[32mDownloading package 67,4`e[0m%"; Expected = 67.4 }
    ) {
        $consolePath = Join-Path $TestDrive "$Tool-progress.txt"
        @($Marker, $Line) | Set-Content -LiteralPath $consolePath -Encoding UTF8

        $state = Get-LiveActivityState -Task 'HealthCheck' -ConsolePath $consolePath -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:01:35')

        $state.CurrentOperation | Should -Be $ExpectedOperation
        $state.Percentage | Should -Be $Expected
        $state.IsIndeterminate | Should -BeFalse
        $state.ElapsedText | Should -Be '00:01:35'
        $state.ConsoleText | Should -Not -Match ([regex]::Escape([string][char]27))
    }

    It 'uses indeterminate activity when the current operation emits no percentage' {
        $consolePath = Join-Path $TestDrive 'no-percent.txt'
        @('[RUNNING] WinGet: Reading installed applications','Reading WinGet package inventory…') | Set-Content -LiteralPath $consolePath -Encoding UTF8

        $state = Get-LiveActivityState -Task 'InstalledApps' -ConsolePath $consolePath -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:04')

        $state.CurrentOperation | Should -Be 'WinGet: Reading installed applications'
        $state.Percentage | Should -BeNullOrEmpty
        $state.IsIndeterminate | Should -BeTrue
    }

    It 'keeps the current operation when its marker is older than the displayed output tail' {
        $consolePath = Join-Path $TestDrive 'deep-marker.txt'
        @('[RUNNING] DISM-Health: Analyzing the component store') + @(1..24 | ForEach-Object { "native output line $_" }) |
            Set-Content -LiteralPath $consolePath -Encoding UTF8

        $first = Get-LiveActivityState -Task 'HealthCheck' -ConsolePath $consolePath -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:10') -MaximumLines 6 -ScanLines 40
        25..450 | ForEach-Object { "native output line $_" } | Add-Content -LiteralPath $consolePath -Encoding UTF8
        Add-Content -LiteralPath $consolePath -Value 'Analysis 51.25% complete.' -Encoding UTF8
        $state = Get-LiveActivityState -Task 'HealthCheck' -ConsolePath $consolePath -PreviousState $first -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:20') -MaximumLines 6 -ScanLines 40

        $state.CurrentOperation | Should -Be 'DISM-Health: Analyzing the component store'
        $state.Percentage | Should -Be 51.25
        $state.ConsoleText | Should -Match 'native output line 446'
        $state.ConsoleText | Should -Match 'Analysis 51.25% complete\.'
        $state.ConsoleText | Should -Not -Match 'native output line 445(?:\r?\n|$)'
    }

    It 'resets stale percentage when a new operation starts' {
        $consolePath = Join-Path $TestDrive 'transition.txt'
        @('[RUNNING] SFC: Verifying protected files','Verification 88% complete.') | Set-Content -LiteralPath $consolePath -Encoding UTF8
        $first = Get-LiveActivityState -Task 'SystemRepair' -ConsolePath $consolePath -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:20')
        Add-Content -LiteralPath $consolePath -Value '[RUNNING] DISM-Health: Restoring the component store' -Encoding UTF8

        $second = Get-LiveActivityState -Task 'SystemRepair' -ConsolePath $consolePath -PreviousState $first -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:21')

        $first.Percentage | Should -Be 88
        $second.CurrentOperation | Should -Be 'DISM-Health: Restoring the component store'
        $second.Percentage | Should -BeNullOrEmpty
        $second.IsIndeterminate | Should -BeTrue
    }

    It 'carries an incomplete operation record across polling reads' {
        $consolePath = Join-Path $TestDrive 'split-record.txt'
        Set-Content -LiteralPath $consolePath -Value '[RUNNING] DISM-Heal' -Encoding UTF8 -NoNewline

        $first = Get-LiveActivityState -Task 'HealthRepair' -ConsolePath $consolePath -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:01')
        [IO.File]::AppendAllText($consolePath, "th: Restoring the component store`r`nVerification 12", [Text.UTF8Encoding]::new($false))
        $second = Get-LiveActivityState -Task 'HealthRepair' -ConsolePath $consolePath -PreviousState $first -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:02')
        [IO.File]::AppendAllText($consolePath, ",5% complete.`r`n", [Text.UTF8Encoding]::new($false))
        $third = Get-LiveActivityState -Task 'HealthRepair' -ConsolePath $consolePath -PreviousState $second -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:03')

        $first.OperationActive | Should -BeFalse
        $second.CurrentOperation | Should -Be 'DISM-Health: Restoring the component store'
        $second.Percentage | Should -BeNullOrEmpty
        $third.CurrentOperation | Should -Be 'DISM-Health: Restoring the component store'
        $third.Percentage | Should -Be 12.5
    }

    It 'resets stale percentage when a guided START step changes' {
        $consolePath = Join-Path $TestDrive 'guided-console.txt'
        $activityPath = Join-Path $TestDrive 'current-step.txt'
        @('[RUNNING] SFC: Verifying protected files','Verification 64% complete.') | Set-Content -LiteralPath $consolePath -Encoding UTF8
        'START 02-WindowsHealth' | Set-Content -LiteralPath $activityPath -Encoding UTF8
        $first = Get-LiveActivityState -Task 'PreBackupRun' -ConsolePath $consolePath -ActivityPath $activityPath -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:20')
        Add-Content -LiteralPath $consolePath -Value 'Verification 100% complete.' -Encoding UTF8
        'START 03-WinGetPreview' | Set-Content -LiteralPath $activityPath -Encoding UTF8

        $second = Get-LiveActivityState -Task 'PreBackupRun' -ConsolePath $consolePath -ActivityPath $activityPath -PreviousState $first -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:00:21')

        $second.CurrentOperation | Should -Be 'START 03-WinGetPreview'
        $second.Percentage | Should -BeNullOrEmpty
        $second.IsIndeterminate | Should -BeTrue
    }

    It 'treats result records as operation delimiters without changing final task status' {
        $consolePath = Join-Path $TestDrive 'completed-operation.txt'
        @('[RUNNING] DISM-Health: Restoring the component store','[=================100.0%=================]','[Completed] DISM-Health: The restore operation completed.') |
            Set-Content -LiteralPath $consolePath -Encoding UTF8

        $state = Get-LiveActivityState -Task 'HealthRepair' -ConsolePath $consolePath -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:04:30')

        $state.CurrentOperation | Should -Be 'Waiting for the next operation…'
        $state.Percentage | Should -BeNullOrEmpty
        $state.OperationActive | Should -BeFalse
        (Get-DashboardStateStyle -State Running).Label | Should -Be 'RUNNING — Maintenance in progress'
    }

    It 'does not infer task success from one operation reaching 100 percent' {
        $consolePath = Join-Path $TestDrive 'one-hundred.txt'
        @('[RUNNING] CHKDSK-C: Scanning the file system','Stage 5: 100% complete.') | Set-Content -LiteralPath $consolePath -Encoding UTF8

        $state = Get-LiveActivityState -Task 'SystemRepair' -ConsolePath $consolePath -StartedAt ([datetime]'2026-09-25T10:00:00') -Now ([datetime]'2026-09-25T10:03:00')

        $state.Percentage | Should -Be 100
        $state.OperationActive | Should -BeTrue
        $state.TaskStatus | Should -Be 'Running'
    }

    It 'writes the first activity line before the child exits and retains captured details' {
        $consolePath = Join-Path $TestDrive 'streamed-console.txt'
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoLogo','-NoProfile','-Command',"[Console]::Out.WriteLine('scan started'); Start-Sleep -Milliseconds 6000; [Console]::Error.WriteLine('review detail')")) { [void]$start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        [void]$process.Start()
        $observedPath = Join-Path $TestDrive 'first-line-observed.txt'
        $quotedConsolePath = $consolePath.Replace("'", "''")
        $quotedObservedPath = $observedPath.Replace("'", "''")
        $observerCommand = "`$deadline = [datetime]::UtcNow.AddSeconds(3.5); do { if ((Test-Path -LiteralPath '$quotedConsolePath') -and ((Get-Content -LiteralPath '$quotedConsolePath' -Raw) -match 'scan started') -and (Get-Process -Id $($process.Id) -ErrorAction SilentlyContinue)) { Set-Content -LiteralPath '$quotedObservedPath' -Value 'observed' -Encoding UTF8; exit 0 }; Start-Sleep -Milliseconds 40 } while ([datetime]::UtcNow -lt `$deadline); exit 1"
        $encodedObserver = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($observerCommand))
        $observerStart = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $observerStart.UseShellExecute = $false
        $observerStart.CreateNoWindow = $true
        foreach ($argument in @('-NoLogo','-NoProfile','-EncodedCommand',$encodedObserver)) { [void]$observerStart.ArgumentList.Add($argument) }
        $observer = [Diagnostics.Process]::Start($observerStart)

        try {
            $captured = Receive-ProcessOutput -Process $process -ConsolePath $consolePath
            $observer.WaitForExit()
        } finally {
            $observer.Dispose()
            $process.Dispose()
        }

        Test-Path -LiteralPath $observedPath | Should -BeTrue
        Get-Content -LiteralPath $consolePath -Raw | Should -Match 'scan started'
        Get-Content -LiteralPath $consolePath -Raw | Should -Match 'review detail'
        $captured.Output | Should -Match 'scan started'
        $captured.Errors | Should -Match 'review detail'
    }

    It 'publishes guided step messages as live information while appending the guided log' {
        $script:combinedLog = Join-Path $TestDrive 'guided-run.log'
        $script:activityPath = Join-Path $TestDrive 'current-step.txt'

        $liveMessage = Write-RunLog -Message 'START 02-WindowsHealth' 6>&1 | Out-String

        $liveMessage | Should -Match 'START 02-WindowsHealth'
        Get-Content -LiteralPath $script:combinedLog -Raw | Should -Match 'START 02-WindowsHealth'
        Get-Content -LiteralPath $script:activityPath -Raw | Should -Match '^START 02-WindowsHealth'
    }

    It 'renders safe <Fixture> activity and result fixtures without running maintenance' -ForEach @(
        @{ Fixture = 'running'; State = 'Running'; ExpectedOperation = 'DISM-Health: Restoring the component store'; ExpectedProgress = '42.5%'; ExpectedActions = 'disabled' }
        @{ Fixture = 'finished'; State = 'Review'; ExpectedOperation = 'Finished — see saved result'; ExpectedProgress = 'Result saved'; ExpectedActions = 'enabled' }
    ) {
        $imagePath = Join-Path $TestDrive "$Fixture-dashboard.png"
        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -STA -File $dashboardPath -UiTestOutput $imagePath -UiState $State 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        (Get-Item -LiteralPath $imagePath).Length | Should -BeGreaterThan 1000
        $output | Should -Match "Current operation: $([regex]::Escape($ExpectedOperation))"
        $output | Should -Match "Progress: $([regex]::Escape($ExpectedProgress))"
        $output | Should -Match "Result actions: $ExpectedActions"
    }
}
