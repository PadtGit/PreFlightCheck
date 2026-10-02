#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the CI verification steps locally: Windows PowerShell 5.1 parse, Pester, and the full analyzer.
.DESCRIPTION
    Mirrors .github/workflows/verify.yml with the pinned Pester 6.2.0 and PSScriptAnalyzer 1.25.0.
    Pester and the analyzer run in their own PowerShell processes so a test run cannot change the
    calling session. Every step runs even after an earlier one fails, and the script ends with one
    PASS/FAIL/SKIP line per step. Exits 0 when no step failed, otherwise 1.
    Unlike CI, the parse step also covers untracked files that are not ignored, so new scripts are
    checked before their first commit.
.PARAMETER SkipAnalysis
    Leaves out the full PSScriptAnalyzer run, which is the slowest step. The Claude Code Stop hook
    uses this; run without it before opening a pull request.
.EXAMPLE
    pwsh -NoLogo -NoProfile -File ./tools/Invoke-LocalVerify.ps1
#>
[CmdletBinding()]
param (
    [switch]$SkipAnalysis
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$pwshPath = (Get-Process -Id $PID).Path
$windowsPowerShell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
$results = [System.Collections.Generic.List[object]]::new()

function Add-StepResult
{
    <#
    .SYNOPSIS
        Records the outcome of one verification step for the closing summary.
    #>
    [CmdletBinding()]
    param (
        [string]$Name,
        [ValidateSet('PASS', 'FAIL', 'SKIP')]
        [string]$Status,
        [string]$Detail
    )
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

# Step 1: parse every file marked for Windows PowerShell 5.1 with Windows PowerShell, as CI does.
Write-Output '== PS5.1 parse =='
$inventory = @(& git -C $repositoryRoot ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1')
if ($LASTEXITCODE -ne 0)
{
    Add-StepResult -Name 'PS5.1 parse' -Status FAIL -Detail 'git could not list the repository files'
}
else
{
    # --cached still lists files deleted or renamed in the working tree but not yet staged; skip them.
    $ps51Files = @($inventory | Where-Object {
            $path = Join-Path -Path $repositoryRoot -ChildPath $_
            (Test-Path -LiteralPath $path -PathType Leaf) -and
            (Select-String -LiteralPath $path -Pattern '^#Requires -Version 5\.1' -Quiet)
        })
    if ($ps51Files.Count -eq 0)
    {
        Add-StepResult -Name 'PS5.1 parse' -Status FAIL -Detail 'no files marked #Requires -Version 5.1'
    }
    else
    {
        $parseCheck = {
            param ([string]$Root, [string]$PathList)
            foreach ($path in $PathList.Split('|'))
            {
                $parseErrors = $null
                $null = [System.Management.Automation.Language.Parser]::ParseFile(
                    (Join-Path -Path $Root -ChildPath $path), [ref]$null, [ref]$parseErrors)
                foreach ($parseError in $parseErrors)
                {
                    '{0}:{1}: {2}' -f $path, $parseError.Extent.StartLineNumber, $parseError.Message
                }
            }
        }
        # Windows paths cannot contain '|', so one joined argument carries the whole list.
        $parseOutput = @(& $windowsPowerShell -NoLogo -NoProfile -NonInteractive -Command $parseCheck `
                -args $repositoryRoot, ($ps51Files -join '|') 2>&1)
        $parseExitCode = $LASTEXITCODE
        $parseOutput | ForEach-Object { "  $_" }
        if ($parseExitCode -ne 0 -or $parseOutput.Count -gt 0)
        {
            Add-StepResult -Name 'PS5.1 parse' -Status FAIL -Detail ('{0} problem(s) in {1} file(s), exit {2}' -f
                $parseOutput.Count, $ps51Files.Count, $parseExitCode)
        }
        else
        {
            Add-StepResult -Name 'PS5.1 parse' -Status PASS -Detail "$($ps51Files.Count) file(s)"
        }
    }
}

# Step 2: the Pester suite with the CI configuration. Run.Exit makes the child's exit code the failure count.
Write-Output '== Pester =='
$quotedRoot = "'" + $repositoryRoot.Replace("'", "''") + "'"
$renderMode = if ([Console]::IsOutputRedirected) { 'Plaintext' } else { 'Auto' }
$pesterCommand = @"
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $quotedRoot
Import-Module -Name Pester -RequiredVersion 6.2.0
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = './tests'
`$configuration.Run.Exit = `$true
`$configuration.Output.RenderMode = '$renderMode'
`$configuration.TestRegistry.Enabled = `$false
Invoke-Pester -Configuration `$configuration
"@
& $pwshPath -NoLogo -NoProfile -NonInteractive -Command $pesterCommand
$pesterExitCode = $LASTEXITCODE
if ($pesterExitCode -eq 0)
{
    Add-StepResult -Name 'Pester' -Status PASS -Detail 'Pester 6.2.0'
}
else
{
    Add-StepResult -Name 'Pester' -Status FAIL -Detail "exit $pesterExitCode (failed test count, or a setup error)"
}

# Step 3: the full analyzer, retried like CI because the engine intermittently throws.
if ($SkipAnalysis)
{
    Add-StepResult -Name 'Full analyzer' -Status SKIP -Detail '-SkipAnalysis'
}
else
{
    Write-Output '== Full PSScriptAnalyzer =='
    $analysisScript = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-FullScriptAnalysis.ps1'
    $maximumAnalyzerAttempts = 3
    foreach ($attempt in 1..$maximumAnalyzerAttempts)
    {
        & $pwshPath -NoLogo -NoProfile -NonInteractive -File $analysisScript
        $analysisExitCode = $LASTEXITCODE
        if ($analysisExitCode -eq 0)
        {
            break
        }
        Write-Output "PSScriptAnalyzer attempt $attempt failed with exit code $analysisExitCode."
    }
    if ($analysisExitCode -eq 0)
    {
        Add-StepResult -Name 'Full analyzer' -Status PASS -Detail "attempt $attempt of $maximumAnalyzerAttempts"
    }
    else
    {
        Add-StepResult -Name 'Full analyzer' -Status FAIL -Detail 'see ValidationReport/release-blocking.csv and analyzer-errors.txt'
    }
}

Write-Output ''
Write-Output 'PreFlightCheck local verification'
foreach ($result in $results)
{
    Write-Output ('  {0}  {1,-14} {2}' -f $result.Status, $result.Name, $result.Detail)
}
if (@($results | Where-Object Status -EQ 'FAIL').Count -gt 0)
{
    exit 1
}
exit 0
