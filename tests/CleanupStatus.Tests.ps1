[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester fixture variables are consumed by extracted dashboard functions.')]
param()

Describe 'Cleanup status text and colors' {
    BeforeAll {
        $repositoryRoot = Split-Path $PSScriptRoot -Parent
        Import-Module (Join-Path $repositoryRoot 'Dashboard.Core.psm1') -Force
        Add-Type -AssemblyName PresentationCore
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'Start-Maintenance.ps1'), [ref]$null, [ref]$null)
        foreach ($name in @('Set-DashboardStatus', 'Update-CleanupAvailability')) {
            $functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
    }

    BeforeEach {
        $script:active = $null
        $script:lastPage = 'Cleanup'
        $script:healthReady = $false
        $script:cleanupPreviewKey = $null
        $Status = [pscustomobject]@{ Text = ''; Foreground = $null }
        $StatusBorder = [pscustomobject]@{ Background = $null; BorderBrush = $null }
        $Apply = [pscustomobject]@{ IsEnabled = $true; Content = '' }
        $Access = [pscustomobject]@{ Text = '' }
        $ValueInput = [pscustomobject]@{ Text = '14' }
        $OptionOne = [pscustomobject]@{ IsChecked = $false }
        $OptionTwo = [pscustomobject]@{ IsChecked = $false }
        Set-DashboardStatus -State Success
    }

    It 'replaces a previous success badge with the locked warning style' {
        Update-CleanupAvailability
        $Status.Text | Should -Match '^CLEANUP LOCKED'
        $Status.Foreground.ToString() | Should -Be '#FFF3C87F'
        $StatusBorder.Background.ToString() | Should -Be '#FF3A2D16'
        $StatusBorder.BorderBrush.ToString() | Should -Be '#FFC99339'
        $Apply.IsEnabled | Should -BeFalse
    }

    It 'restores the completed task text and colors when leaving Cleanup' {
        Update-CleanupAvailability
        $script:lastPage = 'Audit'
        Update-CleanupAvailability
        $Status.Text | Should -Be 'SUCCESS — Task completed'
        $Status.Foreground.ToString() | Should -Be '#FF7BE0B5'
        $StatusBorder.Background.ToString() | Should -Be '#FF12352F'
        $StatusBorder.BorderBrush.ToString() | Should -Be '#FF2A9D78'
    }

    It 'preserves the actual <State> warning and its colors while cleanup is locked' -ForEach @(
        @{ State = 'Restart' }, @{ State = 'Repair' }, @{ State = 'Review' }, @{ State = 'ActionNeeded' }
    ) {
        Set-DashboardStatus -State $State
        $taskLabel = $Status.Text
        $foreground = $Status.Foreground.ToString()
        $background = $StatusBorder.Background.ToString()
        Update-CleanupAvailability
        Update-CleanupAvailability
        $Status.Text | Should -Be ('CLEANUP LOCKED - ' + $taskLabel)
        $Status.Foreground.ToString() | Should -Be $foreground
        $StatusBorder.Background.ToString() | Should -Be $background
        $script:lastPage = 'Audit'
        Update-CleanupAvailability
        $Status.Text | Should -Be $taskLabel
    }

    It 'keeps the running task presentation while cleanup is unavailable' {
        Set-DashboardStatus -State Running
        $script:active = [pscustomobject]@{ HasExited = $false }
        Update-CleanupAvailability
        $Status.Text | Should -Match '^RUNNING'
        $Status.Foreground.ToString() | Should -Be '#FF8BD5FF'
        $Apply.IsEnabled | Should -BeFalse
    }
}
