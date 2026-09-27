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
    $inventory = 'filesystem (recursive, including hidden files)'
    if ($target.PSIsContainer)
    {
        # Inside a git work tree, skip ignored scratch trees (nested checkouts, installed
        # dependencies) but keep untracked project files, like the repository analyzer does.
        $gitPaths = $null
        if (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)
        {
            $gitPaths = @(& git -C $target.FullName ls-files --cached --others --exclude-standard `
                    -- '*.ps1' '*.psm1' '*.psd1' 2>$null)
            if ($LASTEXITCODE -ne 0) { $gitPaths = $null }
        }

        if ($null -ne $gitPaths)
        {
            $inventory = 'git (tracked and untracked; ignored files excluded)'
            $files = @($gitPaths | ForEach-Object { Join-Path -Path $target.FullName -ChildPath $_ } |
                    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                    Get-Item -Force | Sort-Object -Property FullName)
        } else
        {
            $files = @(Get-ChildItem -LiteralPath $target.FullName -File -Recurse -Force |
                    Where-Object { $_.Extension -in $extensions } | Sort-Object -Property FullName)
        }
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
    Write-Output "Inventory: $inventory"
    $allTargetVersions = @($settings.Rules.PSUseCompatibleSyntax.TargetVersions)
    $settingsByRuntime = @{}
    $findingCount = 0
    foreach ($file in $files)
    {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref]$null, [ref]$parseErrors)

        # Check syntax compatibility only against runtimes the file declares with #Requires;
        # files without a declaration keep every bundled target.
        $fileSettings = $settingsPath
        $requiredRuntime = $null
        if ($ast.ScriptRequirements) { $requiredRuntime = $ast.ScriptRequirements.RequiredPSVersion }
        if ($requiredRuntime -and $allTargetVersions.Count -gt 0)
        {
            $runtimeKey = '{0}.{1}' -f $requiredRuntime.Major, $requiredRuntime.Minor
            if (-not $settingsByRuntime.ContainsKey($runtimeKey))
            {
                $scopedTargets = @($allTargetVersions | Where-Object { [version]$_ -ge [version]$runtimeKey })
                if ($scopedTargets.Count -eq 0) { $scopedTargets = @($allTargetVersions[-1]) }
                $scopedSettings = Import-PowerShellDataFile -LiteralPath $settingsPath
                $scopedSettings.Rules.PSUseCompatibleSyntax.TargetVersions = $scopedTargets
                $settingsByRuntime[$runtimeKey] = $scopedSettings
            }
            $fileSettings = $settingsByRuntime[$runtimeKey]
            Write-Output "Analyzed: $($file.FullName) (#Requires $runtimeKey)"
        } else
        {
            Write-Output "Analyzed: $($file.FullName)"
        }
        foreach ($parseError in $parseErrors)
        {
            $findingCount += 1
            $location = '{0}:{1}:{2}' -f $file.FullName, $parseError.Extent.StartLineNumber,
            $parseError.Extent.StartColumnNumber
            Write-Output ('{0} [ParseError] {1}: {2}' -f $location, $parseError.ErrorId, $parseError.Message)
        }

        # PSScriptAnalyzer 1.25.0 intermittently crashes inside its compatibility rules
        # (for example "'Get-Command' is not recognized"); retry before reporting INCOMPLETE.
        $diagnostics = $null
        for ($attempt = 1; $null -eq $diagnostics; $attempt++)
        {
            try
            {
                $diagnostics = @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $fileSettings -IncludeSuppressed)
            } catch
            {
                if ($attempt -ge 3) { throw "Analyzer engine error on $($file.FullName): $($_.Exception.Message)" }
                Write-Output "Retrying $($file.FullName) after analyzer engine error (attempt $attempt)."
            }
        }
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
    [Console]::Error.WriteLine($_.InvocationInfo.PositionMessage)
    exit 2
}
