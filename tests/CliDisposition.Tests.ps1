[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester resolves fixture variables assigned in BeforeAll in later test blocks.')]
param()

Describe 'Direct maintenance final disposition' {
    BeforeAll {
        $repositoryRoot = Split-Path $PSScriptRoot -Parent
        $source = Join-Path $repositoryRoot 'PreBackupMaintenance.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
        $mainTry = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] } | Select-Object -First 1
        # Execute only the actual exit/disposition footer in a child process. All
        # inventory, health checks, cleanup, reporting, and mutex code are omitted.
        $footer = ($ast.EndBlock.Statements | Where-Object { $_.Extent.StartOffset -ge $mainTry.Extent.EndOffset }).Extent.Text -join [Environment]::NewLine
        $fixtureScript = Join-Path $TestDrive 'disposition.ps1'
        $fixture = @'
param([string]$Condition)
$statuses = switch ($Condition) {
    'observed' { @('Observed') }
    'review' { @('Review') }
    'failed' { @('Failed') }
    'failed-and-review' { @('Failed', 'Review') }
    default { @() }
}
$report = if ($Condition -eq 'missing') { $null } else {
    [pscustomobject]@{ Results = @($statuses | ForEach-Object { [pscustomobject]@{ Status = $_ } }) }
}
function Write-Information {
    param([object]$MessageData, [string]$InformationAction)
    @{ Message = $MessageData.Message; Color = [string]$MessageData.ForegroundColor } | ConvertTo-Json -Compress | Write-Output
}
'@
        [IO.File]::WriteAllText($fixtureScript, $fixture + [Environment]::NewLine + $footer)
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    It 'prints <Label> in <Color> and preserves exit <ExitCode> for <Condition>' -ForEach @(
        @{ Condition = 'observed'; Label = 'OK'; Color = 'Green'; ExitCode = 0 },
        @{ Condition = 'review'; Label = 'REVIEW'; Color = 'Yellow'; ExitCode = 2 },
        @{ Condition = 'failed'; Label = 'ACTION NEEDED'; Color = 'Red'; ExitCode = 1 },
        @{ Condition = 'failed-and-review'; Label = 'ACTION NEEDED'; Color = 'Red'; ExitCode = 1 },
        @{ Condition = 'missing'; Label = 'ACTION NEEDED'; Color = 'Red'; ExitCode = 1 }
    ) {
        $output = & $windowsPowerShell -NoProfile -File $fixtureScript -Condition $Condition 2>&1
        $LASTEXITCODE | Should -Be $ExitCode
        $status = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        $status.Message | Should -Match ('^' + [regex]::Escape($Label) + ' - ')
        $status.Color | Should -Be $Color
    }
}
