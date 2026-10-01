<#
.SYNOPSIS
    Claude Code PostToolUse hook that checks an edited PowerShell file right away.
.DESCRIPTION
    Reads the hook payload from stdin. For an edited .ps1/.psm1/.psd1 file inside the project:
    files marked #Requires -Version 5.1 are parsed with Windows PowerShell (as CI does), and
    every file is checked with PSScriptAnalyzer using the repository settings. Problems are
    written to stderr with exit code 2 so Claude Code shows them to Claude to fix. Only
    release-blocking findings are reported, matching tools/Invoke-FullScriptAnalysis.ps1, and
    the two slow compatibility-profile rules are left to that full CI analysis.
#>
[CmdletBinding()]
param ()

# Keep in sync with $advisoryRules in tools/Invoke-FullScriptAnalysis.ps1.
$advisoryRules = @(
    'PSAlignAssignmentStatement'
    'PSAvoidLongLines'
    'PSAvoidUsingDoubleQuotesForConstantString'
    'PSPlaceCloseBrace'
    'PSPlaceOpenBrace'
    'PSProvideCommentHelp'
    'PSUseBOMForUnicodeEncodedFile'
    'PSUseCompatibleCommands'
    'PSUseConstrainedLanguageMode'
    'PSUseConsistentIndentation'
    'PSUseConsistentWhitespace'
)
$repositoryRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$settingsPath = Join-Path -Path $repositoryRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
$projectRoot = $env:CLAUDE_PROJECT_DIR
if ([string]::IsNullOrWhiteSpace($projectRoot))
{
    $projectRoot = $repositoryRoot
}

try
{
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
}
catch
{
    [Console]::Error.WriteLine("Test-EditedScript: unreadable hook payload: $($_.Exception.Message)")
    exit 1
}

$filePath = [string]$payload.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($filePath) -or $filePath -notmatch '\.ps(?:m|d)?1$' -or
    -not (Test-Path -LiteralPath $filePath -PathType Leaf))
{
    exit 0
}
$filePath = (Resolve-Path -LiteralPath $filePath).Path
$projectPrefix = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $filePath.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase))
{
    exit 0
}

$problems = [System.Collections.Generic.List[string]]::new()
$displayPath = [IO.Path]::GetRelativePath($projectRoot, $filePath).Replace('\', '/')

if (Select-String -LiteralPath $filePath -Pattern '^#Requires -Version 5\.1' -Quiet)
{
    $parseCheck = {
        param ([string]$Path)
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
        foreach ($parseError in $parseErrors)
        {
            '{0}: {1}' -f $parseError.Extent.StartLineNumber, $parseError.Message
        }
    }
    $parseOutput = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -Command $parseCheck -args $filePath 2>&1)
    if ($LASTEXITCODE -ne 0 -and $parseOutput.Count -eq 0)
    {
        $problems.Add("Windows PowerShell 5.1 parse check could not run (exit $LASTEXITCODE).")
    }
    foreach ($line in $parseOutput)
    {
        $problems.Add("PS5.1 parse error at line $line")
    }
}

try
{
    Import-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
    $settings = Import-PowerShellDataFile -LiteralPath $settingsPath
    # Loading these rules' compatibility profiles takes ~15s per cold process and intermittently
    # throws engine errors; the full analyzer in CI still enforces them.
    foreach ($slowRule in 'PSUseCompatibleCommands', 'PSUseCompatibleTypes')
    {
        $settings.Rules.Remove($slowRule)
    }
    $maximumAnalyzerAttempts = 2
    foreach ($attempt in 1..$maximumAnalyzerAttempts)
    {
        try
        {
            $findings = @(
                Invoke-ScriptAnalyzer -Path $filePath -Settings $settings -ErrorAction Stop |
                    Where-Object { $_.Severity -eq 'Error' -or $_.RuleName -notin $advisoryRules }
            )
            break
        }
        catch
        {
            if ($attempt -eq $maximumAnalyzerAttempts)
            {
                throw
            }
        }
    }
    foreach ($finding in $findings)
    {
        $problems.Add(('{0} line {1}: {2}' -f $finding.RuleName, $finding.Line, $finding.Message))
    }
}
catch
{
    [Console]::Error.WriteLine("Test-EditedScript: PSScriptAnalyzer check skipped: $($_.Exception.Message)")
    if ($problems.Count -eq 0)
    {
        exit 1
    }
}

if ($problems.Count -gt 0)
{
    [Console]::Error.WriteLine("Test-EditedScript found problems in ${displayPath}:")
    foreach ($problem in $problems)
    {
        [Console]::Error.WriteLine("  $problem")
    }
    exit 2
}

exit 0
