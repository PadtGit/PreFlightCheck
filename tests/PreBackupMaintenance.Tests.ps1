[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester resolves variables assigned in BeforeAll inside later It blocks; static analysis does not follow that framework scope.')]
param()

BeforeAll {
    $repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $maintenanceScript = Join-Path $repositoryRoot 'PreBackupMaintenance.ps1'
    $coreModule = Join-Path $repositoryRoot 'Maintenance.Core.psm1'
    $maintenanceText = Get-Content -LiteralPath $maintenanceScript -Raw
    $coreText = Get-Content -LiteralPath $coreModule -Raw
    $analysisText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tools/Invoke-FullScriptAnalysis.ps1') -Raw
}

Describe 'PreBackupMaintenance safety contract' {
    It 'rejects upgrade-all without confirmation before creating a report folder' {
        $reportRoot = Join-Path $TestDrive 'unconfirmed-upgrade-all'
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $output = & $windowsPowerShell -NoLogo -NoProfile -File $maintenanceScript -Mode Updates -UpgradeAll -ReportDirectory $reportRoot 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'Selected application changes require -MaintenanceWindowConfirmed'
        Test-Path -LiteralPath $reportRoot | Should -BeFalse
    }

    It 'invokes repair tools directly with discrete arguments' {
        $repairBlock = [regex]::Match($maintenanceText, '(?s)if \(\$Mode -eq ''SystemRepair''\).*?(?=if \(\$Mode -eq ''Health''\))').Value

        $repairBlock | Should -Match 'System32\\chkdsk\.exe.*@\(''/scan'',''/perf''\)'
        $repairBlock | Should -Match 'System32\\sfc\.exe.*@\(''/scannow''\)'
        $repairBlock | Should -Match 'System32\\DISM\.exe.*@\(''/online'',''/cleanup-image'',''/restorehealth''\)'
        $repairBlock | Should -Not -Match 'System32\\cmd\.exe'
    }

    It 'defaults to Audit and exposes WhatIf through ShouldProcess' {
        $maintenanceText | Should -Match "\$Mode = 'Audit'"
        $maintenanceText | Should -Match '\[CmdletBinding\(SupportsShouldProcess'
        $maintenanceText | Should -Match '\[bool\]\$WhatIfPreference'
    }

    It 'uses terminating errors at the orchestration boundary' {
        $maintenanceText | Should -Match '\$ErrorActionPreference = ''Stop'''
        $maintenanceText | Should -Not -Match '\$ErrorActionPreference = ''Continue'''
        $maintenanceText | Should -Match 'finally'
    }

    It 'does not delete shadow copies or reset the Windows Update cache' {
        $maintenanceText | Should -Not -Match '(?i)vssadmin\s+delete\s+shadows'
        $maintenanceText | Should -Not -Match '(?i)SoftwareDistribution\\Download'
        $maintenanceText | Should -Match 'No automatic reboot, snapshot deletion, update cache reset'
    }

    It 'captures native command exit codes and rejects unexpected results' {
        $maintenanceText | Should -Match '\$LASTEXITCODE'
        $maintenanceText | Should -Match 'AcceptedCodes'
        $maintenanceText | Should -Match 'returned \$code'
    }

    It 'requires explicit maintenance-window confirmation for state changes' {
        $maintenanceText | Should -Match '\$MaintenanceWindowConfirmed'
        $maintenanceText | Should -Match 'Actual maintenance requires confirmed AC power'
        $maintenanceText | Should -Match 'Actual cleanup and health checks require Run as administrator'
    }

    It 'uses the shared AC-line API instead of battery-status inference' {
        $coreText | Should -Match 'GetSystemPowerStatus'
        $coreText | Should -Match 'without inferring it from battery charge status'
        $coreText | Should -Match 'OnAC = \$status\.ACLineStatus -eq 1'
    }

    It 'keeps the existing health scan and adds the WinUtil-style corruption scan commands' {
        $maintenanceText | Should -Match "Mode -eq 'SystemRepair'"
        $maintenanceText | Should -Match 'SystemRepair'
    }

    It 'supports the requested Winget action modes' {
        $maintenanceText | Should -Match '\$Uninstall'
        $maintenanceText | Should -Match '\$UpgradeAll'
        $maintenanceText | Should -Match '\$ShowInstalled'
        $maintenanceText | Should -Match "'uninstall'"
        $maintenanceText | Should -Match "'upgrade','--all'"
        $maintenanceText | Should -Match "'list'"
    }

    It 'exposes the new dashboard actions without removing existing pages' {
        $dashboardText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Start-Maintenance.ps1') -Raw
        $workerText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Invoke-GuiTask.ps1') -Raw
        $dashboardText | Should -Match 'System Corruption Scan - Run'
        $dashboardText | Should -Match 'Install/Upgrade Applications'
        $dashboardText | Should -Match 'Uninstall Applications'
        $dashboardText | Should -Match 'Upgrade all Applications'
        $dashboardText | Should -Match 'Show Installed Apps'
        $dashboardText | Should -Match 'Clear Selection'
        $dashboardText | Should -Match "'Health'"
        $workerText | Should -Match 'SystemRepair'
        $workerText | Should -Match 'UpdateUninstall'
        $workerText | Should -Match 'UpdateAll'
        $workerText | Should -Match 'InstalledApps'
    }

    It 'validates containment and skips reparse points before deleting files' {
        $coreText | Should -Match 'Test-ContainedRegularPath'
        $coreText | Should -Match 'ReparsePoint'
        $coreText | Should -Match 'DeleteByHandle'
        $coreText | Should -Match 'Revalidates and removes individual aged temporary files'
    }
}

Describe 'Maintenance.Core isolated filesystem behavior' {
    BeforeAll {
        Import-Module -Name $coreModule -Force
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('PreFlightCheck-Pester-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:testRoot)
        $script:oldFile = Join-Path $script:testRoot 'old.tmp'
        $script:newFile = Join-Path $script:testRoot 'new.tmp'
        Set-Content -LiteralPath $script:oldFile -Value 'old' -Encoding UTF8
        Set-Content -LiteralPath $script:newFile -Value 'new' -Encoding UTF8
        $oldDate = (Get-Date).AddDays(-30)
        [System.IO.File]::SetCreationTime($script:oldFile, $oldDate)
        [System.IO.File]::SetLastWriteTime($script:oldFile, $oldDate)
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Module -Name Maintenance.Core -Force -ErrorAction SilentlyContinue
    }

    It 'finds only files older than the configured age' {
        $candidates = @(Get-AgedTemporaryFile -Root $script:testRoot -MinimumAgeDays 14)
        @($candidates.Path) | Should -Contain $script:oldFile
        @($candidates.Path) | Should -Not -Contain $script:newFile
    }

    It 'does not delete files under WhatIf' {
        $result = Remove-AgedTemporaryFile -Root $script:testRoot -MinimumAgeDays 14 -WhatIf
        Test-Path -LiteralPath $script:oldFile | Should -BeTrue
        $result.Deleted | Should -Be 0
        $result.Skipped | Should -BeGreaterThan 0
    }
}

Describe 'Release 0.3.0 regression contract' {
    It 'keeps the full audit while gating release-blocking analyzer findings separately' {
        $analysisText | Should -Match '\$advisoryRules'
        $analysisText | Should -Match '\$releaseBlockingFindings'
        $analysisText | Should -Match 'release-blocking\.csv'
        $analysisText | Should -Match 'IsSuppressed'
        $analysisText | Should -Match '\$maximumAnalyzerAttempts = 3'
        $analysisText | Should -Match '\$pathErrors'
    }

    It 'does not pass the unsupported upgrade switch to winget install' {
        $maintenanceText | Should -Match ([regex]::Escape("'install','--id',`$id,'--exact','--disable-interactivity'"))
        $maintenanceText | Should -Not -Match ([regex]::Escape("'install','--id',`$id,'--exact','--upgrade'"))
    }

    It 'rechecks pending restart state after upgrade-all' {
        $upgradeAllIndex = $maintenanceText.IndexOf("Invoke-LoggedProgram -Name UpgradeAll")
        $restartCheckIndex = $maintenanceText.IndexOf('$upgradeAllRestart = Get-PendingRestartState', $upgradeAllIndex)
        $upgradeAllIndex | Should -BeGreaterThan -1
        $restartCheckIndex | Should -BeGreaterThan $upgradeAllIndex
    }

    It 'rejects uninstall mode without selected application IDs' {
        $maintenanceText | Should -Match ([regex]::Escape('if ($Uninstall -and $ApplicationId.Count -eq 0)'))
    }

    It 'preserves installed application output for the dashboard result' {
        $maintenanceText | Should -Match "\$installedOutput = Get-Content"
        $maintenanceText | Should -Match "InstalledApps\.txt"
    }
}

Describe 'Guided review findings' {
    BeforeAll { Import-Module -Name $coreModule -Force }
    AfterAll { Remove-Module -Name Maintenance.Core -Force -ErrorAction SilentlyContinue }

    It 'keeps every review detail and its step and report location' {
        $report = [pscustomobject]@{ Results = @(
            [pscustomobject]@{ Step = 'Storage'; Status = 'Review'; Detail = 'Disk needs attention' },
            [pscustomobject]@{ Step = 'System'; Status = 'Observed'; Detail = 'Collected' },
            [pscustomobject]@{ Step = 'Restart'; Status = 'Review'; Detail = 'Restart pending' }
        ) }

        $findings = @(Get-ReportReviewFinding -StepName '01-SystemReview' -Report $report -ReportPath 'C:\fixture\report.json')

        $findings.Count | Should -Be 2
        $findings[0].Step | Should -Be '01-SystemReview'
        $findings[0].Check | Should -Be 'Storage'
        $findings[0].Detail | Should -Be 'Disk needs attention'
        $findings[0].Report | Should -Be 'C:\fixture\report.json'
        $findings[1].Detail | Should -Be 'Restart pending'
    }

    It 'marks a review exit with no matching findings as needing inspection' {
        $report = [pscustomobject]@{ Results = @([pscustomobject]@{ Step = 'System'; Status = 'Observed'; Detail = 'Collected' }) }

        $findings = @(Get-ReportReviewFinding -StepName '03-WinGetPreview' -Report $report -ReportPath 'C:\fixture\report.json' -ExitCode 2)

        $findings.Count | Should -Be 1
        $findings[0].Check | Should -Be 'Report'
        $findings[0].Detail | Should -Match 'Review the saved report'
    }

    It 'distinguishes completed with review from completed clean and stopped' {
        $finding = [pscustomobject]@{ Step = '01-SystemReview'; Check = 'Storage'; Detail = 'Review disk'; Report = 'C:\fixture\report.json' }

        $review = Get-GuidedRunDisposition -Completed $true -ReviewFindings @($finding)
        $clean = Get-GuidedRunDisposition -Completed $true -ReviewFindings @()
        $stopped = Get-GuidedRunDisposition -Completed $false -ReviewFindings @($finding) -Failure 'Restart required'

        $review.ExitCode | Should -Be 2
        $review.ReviewRequired | Should -BeTrue
        $review.Message | Should -Match '1 review finding'
        $clean.ExitCode | Should -Be 0
        $clean.ReviewRequired | Should -BeFalse
        $stopped.ExitCode | Should -Be 1
        $stopped.Message | Should -Be 'Restart required'
    }

    It 'names the failed check and its report for a stopped step' {
        $report = [pscustomobject]@{ Results = @([pscustomobject]@{ Step = 'DISM-Health'; Status = 'Failed'; Detail = 'Restart required' }) }

        $message = Get-ReportFailureMessage -StepName '02-WindowsHealth' -Report $report -ReportPath 'C:\fixture\report.json' -ExitCode 1

        $message | Should -Match '02-WindowsHealth'
        $message | Should -Match 'DISM-Health: Restart required'
        $message | Should -Match 'C:\\fixture\\report.json'
    }
}
