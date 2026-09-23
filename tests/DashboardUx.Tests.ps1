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
    $guidedRunPath = Join-Path $repositoryRoot 'Invoke-PreBackupRun.ps1'
    Import-ScriptFunction -Path $workerPath -Name 'Get-GuiResultPresentation'
    Import-ScriptFunction -Path $workerPath -Name 'Format-GuiTaskSummary'
    Import-ScriptFunction -Path $workerPath -Name 'Receive-ProcessOutput'
    Import-ScriptFunction -Path $dashboardPath -Name 'Get-DashboardStateStyle'
    Import-ScriptFunction -Path $dashboardPath -Name 'Get-LiveActivityText'
    Import-ScriptFunction -Path $guidedRunPath -Name 'Write-RunLog'
}

AfterAll {
    foreach ($name in @('Get-GuiResultPresentation','Format-GuiTaskSummary','Receive-ProcessOutput','Get-DashboardStateStyle','Get-LiveActivityText','Write-RunLog')) {
        Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue
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
}
