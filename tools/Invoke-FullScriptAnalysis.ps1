<#
.SYNOPSIS
Runs every built-in PSScriptAnalyzer rule and saves findings, including suppressions.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
$root = Split-Path -Path $PSScriptRoot -Parent
$settingsPath = Join-Path -Path $root -ChildPath 'PSScriptAnalyzerSettings.psd1'
$settings = Import-PowerShellDataFile -LiteralPath $settingsPath
$availableRules = @(Get-ScriptAnalyzerRule)
$missingRules = @($availableRules | Where-Object { -not $settings.Rules.ContainsKey($_.RuleName) })
if ($missingRules.Count -gt 0)
{
    throw "Unconfigured analyzer rules: $($missingRules.RuleName -join ', ')"
}
$disabledRules = @($settings.Rules.Keys | Where-Object { $settings.Rules[$_].Enable -ne $true })
if ($disabledRules.Count -gt 0 -or $settings.ExcludeRules.Count -gt 0)
{
    throw 'Full analysis requires every rule enabled and no exclusions.'
}
$reportDirectory = Join-Path -Path $root -ChildPath 'ValidationReport'
$null = New-Item -Path $reportDirectory -ItemType Directory -Force
# Git inventory avoids inspecting generated reports or locally installed dependencies.
$paths = @(& git -C $root ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1' '*.psd1')
if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0)
{
    throw 'Cannot obtain the repository PowerShell file inventory.'
}
$analysisErrors = @()
$findings = @(
    foreach ($path in $paths)
    {
        Invoke-ScriptAnalyzer -Path (Join-Path -Path $root -ChildPath $path) -Settings $settingsPath `
            -IncludeSuppressed -ErrorAction Continue -ErrorVariable +analysisErrors
    }
)
$findings | Select-Object -Property RuleName, Severity, ScriptName, Line, Column, Message, IsSuppressed |
    Export-Csv -LiteralPath (Join-Path -Path $reportDirectory -ChildPath 'psscriptanalyzer-full.csv') -NoTypeInformation
$analysisErrors | Out-String |
    Set-Content -LiteralPath (Join-Path -Path $reportDirectory -ChildPath 'analyzer-errors.txt')
$summary = [pscustomobject]@{
    AnalyzerVersion = '1.25.0'
    Rules = $availableRules.Count
    Files = $paths.Count
    Findings = $findings.Count
    EngineErrors = $analysisErrors.Count
}
$summary | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path -Path $reportDirectory -ChildPath 'analyzer-summary.json')
$summary | Format-List
$findings | Group-Object -Property RuleName | Sort-Object -Property Count -Descending |
    Format-Table -Property Count, Name -AutoSize
if ($findings.Count -gt 0 -or $analysisErrors.Count -gt 0)
{
    throw 'Full analyzer review failed. See ValidationReport for findings and engine errors.'
}

