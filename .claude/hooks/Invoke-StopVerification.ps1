<#
.SYNOPSIS
    Claude Code Stop hook that runs the PS5.1 parse and Pester before Claude finishes with changed scripts.
.DESCRIPTION
    Reads the hook payload from stdin. When PowerShell files, .claude/settings.json, or either skill copy
    differ from the base branch (origin/main, else main) in commits or in the working tree, runs
    tools/Invoke-LocalVerify.ps1 -SkipAnalysis. A failure exits 2 with the failing tests so Claude keeps
    working. A passing state is remembered by content, so later stops skip the run until those files
    change again. After three blocked stops in a row the hook lets Claude stop and tells Bob instead,
    so a failure Claude cannot fix does not loop forever. Set PFC_HOOK_STATE_DIR to move the state files.
#>
[CmdletBinding()]
param ()

$maximumBlockedStops = 3
$pathSpec = @('*.ps1', '*.psm1', '*.psd1', '.claude/settings.json', '.claude/skills', '.agents/skills')
$repositoryRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$projectRoot = $env:CLAUDE_PROJECT_DIR
if ([string]::IsNullOrWhiteSpace($projectRoot))
{
    $projectRoot = $repositoryRoot
}
$projectRoot = [IO.Path]::GetFullPath($projectRoot)

function Invoke-Git
{
    <#
    .SYNOPSIS
        Runs git in the project and returns whether it succeeded with its output lines.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ([string[]]$Arguments)
    $gitOutput = @(& git -C $projectRoot @Arguments 2>$null)
    [pscustomobject]@{ Succeeded = ($LASTEXITCODE -eq 0); Lines = [string[]]$gitOutput }
}

function Get-TextHash
{
    <#
    .SYNOPSIS
        Returns the lowercase SHA-256 hex digest of a string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param ([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try
    {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    }
    finally
    {
        $sha.Dispose()
    }
}

try
{
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
}
catch
{
    [Console]::Error.WriteLine("Invoke-StopVerification: unreadable hook payload: $($_.Exception.Message)")
    exit 1
}

if (-not (Invoke-Git -Arguments @('rev-parse', '--verify', 'HEAD')).Succeeded)
{
    exit 0
}
$base = 'HEAD'
foreach ($candidate in 'origin/main', 'main')
{
    $mergeBase = Invoke-Git -Arguments @('merge-base', 'HEAD', $candidate)
    if ($mergeBase.Succeeded -and $mergeBase.Lines.Count -gt 0)
    {
        $base = $mergeBase.Lines[0]
        break
    }
}

# Diffing the base commit against the working tree covers committed, staged, and unstaged changes.
$diffResult = Invoke-Git -Arguments (@('diff', '--no-ext-diff', '--no-textconv', '--no-color', $base, '--') + $pathSpec)
$untrackedResult = Invoke-Git -Arguments (@('ls-files', '--others', '--exclude-standard', '--') + $pathSpec)
if (-not $diffResult.Succeeded -or -not $untrackedResult.Succeeded)
{
    [Console]::Error.WriteLine('Invoke-StopVerification: git could not compare the project with its base branch.')
    exit 1
}
$diff = $diffResult.Lines
$untracked = $untrackedResult.Lines
if ($diff.Count -eq 0 -and $untracked.Count -eq 0)
{
    exit 0
}

$fingerprintParts = [System.Collections.Generic.List[string]]::new()
$fingerprintParts.Add(($diff -join "`n"))
foreach ($path in ($untracked | Sort-Object))
{
    $fullPath = Join-Path -Path $projectRoot -ChildPath $path
    if (Test-Path -LiteralPath $fullPath -PathType Leaf)
    {
        $fingerprintParts.Add($path + '|' + (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash)
    }
}
$fingerprint = Get-TextHash -Text ($fingerprintParts -join "`n")

$stateDirectory = $env:PFC_HOOK_STATE_DIR
if ([string]::IsNullOrWhiteSpace($stateDirectory))
{
    $stateDirectory = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'PreFlightCheck-ClaudeHooks'
}
$null = New-Item -Path $stateDirectory -ItemType Directory -Force
$projectKey = (Get-TextHash -Text $projectRoot.ToLowerInvariant()).Substring(0, 16)
$sessionKey = ([string]$payload.session_id) -replace '[^A-Za-z0-9-]', ''
if ([string]::IsNullOrEmpty($sessionKey))
{
    $sessionKey = 'unknown'
}
$verifiedPath = Join-Path -Path $stateDirectory -ChildPath "$projectKey.verified"
$blockedPath = Join-Path -Path $stateDirectory -ChildPath "$projectKey-$sessionKey.blocked"

if ((Test-Path -LiteralPath $verifiedPath) -and
    (Get-Content -LiteralPath $verifiedPath -Raw).Trim() -eq $fingerprint)
{
    Remove-Item -LiteralPath $blockedPath -ErrorAction SilentlyContinue
    exit 0
}

# stop_hook_active is false when Claude stops on its own; only stops that follow a block count toward the limit.
$blockedStops = 0
if ($payload.stop_hook_active -eq $true -and (Test-Path -LiteralPath $blockedPath))
{
    $blockedStops = [int](Get-Content -LiteralPath $blockedPath -Raw)
}

$verifyScript = Join-Path -Path $projectRoot -ChildPath 'tools/Invoke-LocalVerify.ps1'
if (-not (Test-Path -LiteralPath $verifyScript -PathType Leaf))
{
    [Console]::Error.WriteLine("Invoke-StopVerification: $verifyScript not found.")
    exit 1
}
$pwshPath = (Get-Process -Id $PID).Path
$output = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -File $verifyScript -SkipAnalysis 2>&1 |
        ForEach-Object { [string]$_ })
$verifyExitCode = $LASTEXITCODE

if ($verifyExitCode -eq 0)
{
    Set-Content -LiteralPath $verifiedPath -Value $fingerprint -NoNewline
    Remove-Item -LiteralPath $blockedPath -ErrorAction SilentlyContinue
    exit 0
}

if ($blockedStops -ge $maximumBlockedStops)
{
    Remove-Item -LiteralPath $blockedPath -ErrorAction SilentlyContinue
    $message = "PreFlightCheck verification still fails after $maximumBlockedStops attempts. Run " +
        'pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1 -SkipAnalysis to see the failures.'
    @{ systemMessage = $message } | ConvertTo-Json -Compress
    exit 0
}
Set-Content -LiteralPath $blockedPath -Value ($blockedStops + 1) -NoNewline

# The suite prints a lot of fixture output; report each failed test with its message and the step summary.
$report = [System.Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $output.Count -and $report.Count -lt 60; $index++)
{
    if ($output[$index] -match '^\s*\[-\]')
    {
        $last = [Math]::Min($index + 4, $output.Count - 1)
        foreach ($line in $output[$index..$last])
        {
            $report.Add($line)
        }
    }
}
$summaryStart = [Array]::LastIndexOf([string[]]$output, 'PreFlightCheck local verification')
if ($summaryStart -ge 0)
{
    foreach ($line in $output[$summaryStart..($output.Count - 1)])
    {
        $report.Add($line)
    }
}
else
{
    foreach ($line in ($output | Select-Object -Last 30))
    {
        $report.Add($line)
    }
}

[Console]::Error.WriteLine(
    "Verification failed (exit $verifyExitCode, blocked stop $($blockedStops + 1) of $maximumBlockedStops). " +
    'Fix the problems below before finishing, or tell Bob why they cannot be fixed.')
foreach ($line in $report)
{
    [Console]::Error.WriteLine($line)
}
[Console]::Error.WriteLine('Rerun: pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1 -SkipAnalysis')
exit 2
