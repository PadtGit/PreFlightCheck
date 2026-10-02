<#
.SYNOPSIS
    Claude Code hook that keeps the Codex skill copy (.agents/skills) in step with .claude/skills.
.DESCRIPTION
    Reads the hook payload from stdin. On PreToolUse it refuses an edit to a file under .agents/skills,
    because that copy is generated, and names the .claude/skills file to edit instead. On PostToolUse it
    copies a file just written under .claude/skills to the same path under .agents/skills. Deleting or
    renaming a skill file is not mirrored; do that in both copies (tests/AgentSkills.Tests.ps1 checks).
#>
[CmdletBinding()]
param ()

$repositoryRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$projectRoot = $env:CLAUDE_PROJECT_DIR
if ([string]::IsNullOrWhiteSpace($projectRoot))
{
    $projectRoot = $repositoryRoot
}
$projectRoot = [IO.Path]::GetFullPath($projectRoot)
$separator = [IO.Path]::DirectorySeparatorChar
$claudeSkills = [IO.Path]::GetFullPath((Join-Path -Path $projectRoot -ChildPath '.claude/skills')) + $separator
$agentSkills = [IO.Path]::GetFullPath((Join-Path -Path $projectRoot -ChildPath '.agents/skills')) + $separator

try
{
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
}
catch
{
    [Console]::Error.WriteLine("Sync-AgentSkill: unreadable hook payload: $($_.Exception.Message)")
    exit 1
}

$filePath = [string]$payload.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($filePath))
{
    exit 0
}
# GetFullPath also collapses '..' segments, so a path cannot step out of a skills folder.
$filePath = [IO.Path]::GetFullPath([IO.Path]::Combine($projectRoot, $filePath))

if ($payload.hook_event_name -eq 'PreToolUse')
{
    if ($filePath.StartsWith($agentSkills, [StringComparison]::OrdinalIgnoreCase))
    {
        $relativePath = $filePath.Substring($agentSkills.Length).Replace('\', '/')
        [Console]::Error.WriteLine(
            "Blocked: .agents/skills is a generated copy. Edit .claude/skills/$relativePath instead; " +
            'the Sync-AgentSkill hook copies it to .agents/skills.')
        exit 2
    }
    exit 0
}

if ($payload.hook_event_name -eq 'PostToolUse' -and
    $filePath.StartsWith($claudeSkills, [StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath $filePath -PathType Leaf))
{
    $relativePath = $filePath.Substring($claudeSkills.Length)
    $destination = Join-Path -Path $agentSkills -ChildPath $relativePath
    try
    {
        $null = New-Item -Path (Split-Path -Path $destination -Parent) -ItemType Directory -Force
        Copy-Item -LiteralPath $filePath -Destination $destination -Force -ErrorAction Stop
    }
    catch
    {
        [Console]::Error.WriteLine(
            "Sync-AgentSkill: could not copy .claude/skills/$($relativePath.Replace('\', '/')) to .agents/skills: " +
            "$($_.Exception.Message). Run Copy-Item .claude/skills/* .agents/skills/ -Recurse -Force.")
        exit 2
    }
}

exit 0
