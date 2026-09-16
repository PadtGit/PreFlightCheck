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

    It 'validates containment and skips reparse points before deleting files' {
        $coreText | Should -Match 'Test-ContainedRegularPath'
        $coreText | Should -Match 'ReparsePoint'
        $coreText | Should -Match 'Remove-Item -LiteralPath'
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
