<#
.SYNOPSIS
    Performs the strict static PowerShell review check using bundled settings.
.DESCRIPTION
    Requires PSScriptAnalyzer 1.25.0. Includes suppressed findings and never executes
    reviewed scripts. Returns 0 for clean, 1 for findings, or 2 for incomplete checks.
.PARAMETER Path
    Literal path to a PowerShell file or a directory to inspect recursively.
.EXAMPLE
    & ./Invoke-PowerShellReviewCheck.ps1 -Path 'C:\Projects\Windows Tools'
#>
[CmdletBinding()]
param (
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
$requiredVersion = '1.25.0'
$settingsPath = Join-Path -Path $PSScriptRoot -ChildPath '../assets/PSScriptAnalyzerSettingsFull.psd1'

try
{
    if ([string]::IsNullOrWhiteSpace($Path))
    {
        throw 'Provide -Path with a file or directory to analyze.'
    }

    Import-Module -Name PSScriptAnalyzer -RequiredVersion $requiredVersion -Force -ErrorAction Stop
    $settings = Import-PowerShellDataFile -LiteralPath $settingsPath
    $availableRules = @(Get-ScriptAnalyzerRule | Select-Object -ExpandProperty RuleName)
    $unknownRules = @($settings.Rules.Keys | Where-Object { $_ -notin $availableRules })
    if ($unknownRules.Count -gt 0)
    {
        throw "Unsupported configured rules: $($unknownRules -join ', ')"
    }

    $target = Get-Item -LiteralPath $Path -Force
    if ($target.PSProvider.Name -ne 'FileSystem')
    {
        throw 'The target must be a filesystem path.'
    }

    $extensions = @('.ps1', '.psm1', '.psd1')
    if ($target.PSIsContainer)
    {
        $files = @(Get-ChildItem -LiteralPath $target.FullName -File -Recurse -Force |
                Where-Object { $_.Extension -in $extensions } | Sort-Object -Property FullName)
    } else
    {
        $files = @($target | Where-Object { $_.Extension -in $extensions })
    }

    if ($files.Count -eq 0)
    {
        throw 'No eligible .ps1, .psm1, or .psd1 files were found.'
    }

    Write-Output "Analyzer: PSScriptAnalyzer $requiredVersion"
    Write-Output "Settings: $((Get-Item -LiteralPath $settingsPath).FullName)"
    $findingCount = 0
    foreach ($file in $files)
    {
        Write-Output "Analyzed: $($file.FullName)"
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref]$null, [ref]$parseErrors)
        foreach ($parseError in $parseErrors)
        {
            $findingCount += 1
            $location = '{0}:{1}:{2}' -f $file.FullName, $parseError.Extent.StartLineNumber,
            $parseError.Extent.StartColumnNumber
            Write-Output ('{0} [ParseError] {1}: {2}' -f $location, $parseError.ErrorId, $parseError.Message)
        }

        $diagnostics = @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsPath -IncludeSuppressed)
        foreach ($diagnostic in $diagnostics)
        {
            $findingCount += 1
            $location = '{0}:{1}:{2}' -f $file.FullName, $diagnostic.Line, $diagnostic.Column
            Write-Output ('{0} [{1}] {2}: {3}' -f $location, $diagnostic.Severity,
                $diagnostic.RuleName, $diagnostic.Message)
        }
    }

    if ($findingCount -gt 0)
    {
        Write-Output "FAIL: $findingCount finding(s), including suppressed diagnostics."
        exit 1
    }

    Write-Output "PASS: $($files.Count) file(s), zero findings at all severities, including suppressed diagnostics."
    exit 0
} catch
{
    [Console]::Error.WriteLine("INCOMPLETE: $($_.Exception.Message)")
    exit 2
}
