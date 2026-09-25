BeforeAll {
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    $maintenanceAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'PreBackupMaintenance.ps1'), [ref]$null, [ref]$null)
    $helperSource = foreach ($name in @('Add-Result', 'Invoke-LoggedProgram')) {
        $node = $maintenanceAst.Find({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $name }, $true)
        $node.Extent.Text
    }
    $helperText = $helperSource -join [Environment]::NewLine
    . ([scriptblock]::Create($helperText))
}

Describe 'Live output from native checks' {
    BeforeEach {
        $script:runDirectory = $TestDrive
        $script:report = [pscustomobject]@{ Results = [Collections.Generic.List[object]]::new() }
    }

    It 'forwards <Encoding> carriage-return progress before the native check finishes under Windows PowerShell 5.1' -ForEach @(
        @{ Encoding = 'utf-8' }
        @{ Encoding = 'Unicode' }
    ) {
        $fixture = Join-Path $TestDrive 'native-fixture.ps1'
        $finishedPath = Join-Path $TestDrive 'native-finished.txt'
        @'
param([string]$FinishedPath, [string]$Encoding)
[Console]::OutputEncoding = [Text.Encoding]::GetEncoding($Encoding)
[Console]::Out.Write("Verification 25%`r")
[Console]::Out.Flush()
Start-Sleep -Milliseconds 500
[Console]::Out.Write("Verification 75%`r")
[Console]::Out.Flush()
Start-Sleep -Seconds 3
[IO.File]::WriteAllText($FinishedPath, 'finished')
[Console]::Out.WriteLine('Verification 100% complete.')
exit 0
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
        $runner = Join-Path $TestDrive 'worker-fixture.ps1'
        @'
param([string]$RunDirectory, [string]$Fixture, [string]$FinishedPath, [string]$Encoding)
$ErrorActionPreference = 'Stop'
$report = [pscustomobject]@{ Results = [Collections.Generic.List[object]]::new() }
'@ + [Environment]::NewLine + $helperText + [Environment]::NewLine + @'
$native = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$records = @(Invoke-LoggedProgram -Name Fixture -FilePath $native -Arguments @('-NoLogo','-NoProfile','-File',$Fixture,'-FinishedPath',$FinishedPath,'-Encoding',$Encoding) 6>&1 | ForEach-Object {
    if ($_ -is [Management.Automation.InformationRecord] -and $_.MessageData -match 'Verification 25%') {
        if (-not (Test-Path -LiteralPath $FinishedPath)) { [IO.File]::WriteAllText((Join-Path $RunDirectory 'observed-live.txt'), 'live') }
    }
    $_
})
$records | ForEach-Object { [string]$_ }
if ($records[-1] -isnot [int] -or $records[-1] -ne 0) { throw 'Native output polluted the numeric return value.' }
'@ | Set-Content -LiteralPath $runner -Encoding UTF8
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $output = & $windowsPowerShell -NoLogo -NoProfile -File $runner -RunDirectory $TestDrive -Fixture $fixture -FinishedPath $finishedPath -Encoding $Encoding
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $TestDrive 'observed-live.txt') | Should -BeTrue
        ($output -join "`n") | Should -Match '\[RUNNING\] Fixture:'
        $log = Get-Content -LiteralPath (Join-Path $TestDrive 'Fixture.txt') -Raw
        $log | Should -Match 'Verification 25%'
        $log | Should -Match 'Verification 75%'
        $log | Should -Match 'Verification 100% complete\.'
        $log.Contains([string][char]0) | Should -BeFalse
    }

    It 'keeps the accepted native exit code as the only success-stream value' {
        $native = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $records = @(Invoke-LoggedProgram -Name Accepted -FilePath $native -Arguments @('/c', 'echo check output & exit /b 2') -AcceptedCodes @(0,2) 6>&1)
        $code = @($records | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })
        $activity = @($records | Where-Object { $_ -is [Management.Automation.InformationRecord] })
        $code.Count | Should -Be 1
        $code[0] | Should -Be 2
        ($activity -join "`n") | Should -Match 'check output'
        Get-Content -LiteralPath (Join-Path $TestDrive 'Accepted.txt') -Raw | Should -Match 'check output'
    }

    It 'retains diagnostics and throws for an unaccepted native exit code' {
        $native = Join-Path $env:SystemRoot 'System32\cmd.exe'
        { Invoke-LoggedProgram -Name Failed -FilePath $native -Arguments @('/c', 'echo failure detail & exit /b 7') } | Should -Throw '*Failed returned 7*'
        Get-Content -LiteralPath (Join-Path $TestDrive 'Failed.txt') -Raw | Should -Match 'failure detail'
    }

    It 'delivers native progress through the guided runner and GUI receiver before completion' {
        $guidedPath = Join-Path $repositoryRoot 'Invoke-PreBackupRun.ps1'
        $guidedAst = [Management.Automation.Language.Parser]::ParseFile($guidedPath, [ref]$null, [ref]$null)
        $guidedFunctions = foreach ($name in @('Write-RunLog', 'Invoke-RunStep')) {
            $node = $guidedAst.Find({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $name }, $true)
            $node.Extent.Text
        }
        $guiAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'Invoke-GuiTask.ps1'), [ref]$null, [ref]$null)
        $receiver = $guiAst.Find({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq 'Receive-ProcessOutput' }, $true)
        . ([scriptblock]::Create($receiver.Extent.Text))
        $fixtureRoot = Join-Path $TestDrive 'guided-fixture'
        [void][IO.Directory]::CreateDirectory($fixtureRoot)
        $consolePath = Join-Path $fixtureRoot 'console.txt'
        # This harmless native stand-in confirms that the dashboard-facing file
        # receives a progress update while the native check is still running.
        @'
[Console]::Out.Write("Verification 25%`r")
[Console]::Out.Flush()
[Console]::Out.Write("Verification 50%`r")
[Console]::Out.Flush()
$deadline = [datetime]::UtcNow.AddSeconds(8)
do {
    $consolePath = Join-Path $PSScriptRoot 'console.txt'
    if ((Test-Path -LiteralPath $consolePath) -and (Get-Content -LiteralPath $consolePath -Raw) -match 'Verification 25%') {
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'guided-live.txt'), 'live')
        break
    }
    Start-Sleep -Milliseconds 50
} while ([datetime]::UtcNow -lt $deadline)
[Console]::Out.WriteLine('Verification 100% complete.')
exit 0
'@ | Set-Content -LiteralPath (Join-Path $fixtureRoot 'native.ps1') -Encoding UTF8
        @'
param([string]$Mode, [string]$ReportDirectory)
$runDirectory = $ReportDirectory
$report = [pscustomobject]@{ Results = [Collections.Generic.List[object]]::new(); RestartRequired = $false; Restart = $null; RepairRecommended = $false; HealthReady = $false }
'@ + [Environment]::NewLine + $helperText + [Environment]::NewLine + @'
$native = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$code = Invoke-LoggedProgram -Name Fixture -FilePath $native -Arguments @('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'native.ps1'))
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDirectory 'report.json') -Encoding UTF8
exit $code
'@ | Set-Content -LiteralPath (Join-Path $fixtureRoot 'maintenance.ps1') -Encoding UTF8
        ($guidedFunctions -join [Environment]::NewLine) + [Environment]::NewLine + @'
$ErrorActionPreference = 'Stop'
$ReportDirectory = $PSScriptRoot
$combinedLog = Join-Path $PSScriptRoot 'guided-run.log'
$activityPath = Join-Path $PSScriptRoot 'current-step.txt'
$maintenanceScript = Join-Path $PSScriptRoot 'maintenance.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$steps = [Collections.Generic.List[object]]::new()
$reviewFindings = [Collections.Generic.List[object]]::new()
function Get-ReportReviewFinding { return @() }
[void](Invoke-RunStep -Name '01-Fixture' -Arguments @('-Mode','Audit'))
'@ | Set-Content -LiteralPath (Join-Path $fixtureRoot 'guided.ps1') -Encoding UTF8
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoLogo','-NoProfile','-File',(Join-Path $fixtureRoot 'guided.ps1'))) { [void]$start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $captured = Receive-ProcessOutput -Process $process -ConsolePath $consolePath
            $process.ExitCode | Should -Be 0
            $captured.Errors | Should -BeNullOrEmpty
        } finally { $process.Dispose() }
        Test-Path -LiteralPath (Join-Path $fixtureRoot 'guided-live.txt') | Should -BeTrue
        $captured.Output | Should -Match '\[RUNNING\] Fixture:'
        $captured.Output | Should -Match 'Verification 100% complete\.'
        Get-Content -LiteralPath (Join-Path $fixtureRoot '01-Fixture-console.txt') -Raw | Should -Match 'Verification 25%'
        Get-Content -LiteralPath (Join-Path $fixtureRoot '01-Fixture/Fixture.txt') -Raw | Should -Match 'Verification 25%'
    }
}
