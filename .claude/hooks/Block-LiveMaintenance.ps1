<#
.SYNOPSIS
    Claude Code PreToolUse hook that blocks live PreFlightCheck maintenance runs.
.DESCRIPTION
    Reads the hook payload from stdin. When a shell command would invoke a maintenance
    entry point without -WhatIf, writes the reason to stderr and exits 2 so Claude Code
    blocks the call. Reading, diffing, or testing these files is not affected.
#>
[CmdletBinding()]
param ()

$entryPoints = '(?:Start-Maintenance\.(?:ps1|cmd)|PreBackupMaintenance\.ps1|Invoke-PreBackupRun\.ps1|' +
'Invoke-GuiTask\.ps1|Update-Applications\.ps1|Weekly-DellReview\.ps1)'
$pathPrefix = '[''"]?(?:[^\s''";|&]*[\\/])?'
$invocationPatterns = @(
    # Statement start, call operator, pipeline, or dot-source: & .\X.ps1 / . .\X.ps1 / X.ps1
    ('(?:^|[;|&(])\s*(?:\.\s+)?{0}{1}' -f $pathPrefix, $entryPoints),
    # pwsh/powershell -File X.ps1
    ('-File\s+{0}{1}' -f $pathPrefix, $entryPoints)
)

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine("Block-LiveMaintenance: unreadable hook payload: $($_.Exception.Message)")
    exit 2
}

$command = [string]$payload.tool_input.command
$invokesEntryPoint = @($invocationPatterns | Where-Object { $command -match $_ }).Count -gt 0
if ($invokesEntryPoint -and $command -notmatch '-WhatIf\b') {
    [Console]::Error.WriteLine(
        'Blocked: this would run a live PreFlightCheck maintenance script. Use -WhatIf, ' +
        'Pester mocks, or ask Bob to run it himself.')
    exit 2
}

exit 0
