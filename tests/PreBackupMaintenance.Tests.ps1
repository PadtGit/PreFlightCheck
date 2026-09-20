BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $maintenanceScript = Join-Path $repositoryRoot 'PreBackupMaintenance.ps1'
    $coreModule = Join-Path $repositoryRoot 'Maintenance.Core.psm1'
    $maintenanceText = Get-Content -LiteralPath $maintenanceScript -Raw
    $coreText = Get-Content -LiteralPath $coreModule -Raw
}

Describe 'PreBackupMaintenance safety contract' {
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
        $maintenanceText | Should -Match 'chkdsk /scan /perf'
        $maintenanceText | Should -Match 'sfc /scannow'
        $maintenanceText | Should -Match 'dism /online /cleanup-image /restorehealth'
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
    It 'does not pass the unsupported upgrade switch to winget install' {
        $maintenanceText | Should -Match "\$wingetAction = if \(\$Uninstall\).*'install','--id',\$id,'--exact','--disable-interactivity'"
        $maintenanceText | Should -Not -Match "'install','--id',\$id,'--exact','--upgrade'"
    }

    It 'rechecks pending restart state after upgrade-all' {
        $upgradeAllIndex = $maintenanceText.IndexOf("Invoke-LoggedProgram -Name UpgradeAll")
        $restartCheckIndex = $maintenanceText.IndexOf("Get-PendingRestartState", $upgradeAllIndex)
        $upgradeAllIndex | Should -BeGreaterThan -1
        $restartCheckIndex | Should -BeGreaterThan $upgradeAllIndex
    }

    It 'rejects uninstall mode without selected application IDs' {
        $maintenanceText | Should -Match "\$Uninstall.*\$ApplicationId\.Count\s*-eq\s*0"
    }

    It 'preserves installed application output for the dashboard result' {
        $maintenanceText | Should -Match "InstalledApps.*\$installedOutput"
        $maintenanceText | Should -Match "InstalledApps\.txt"
    }
}
