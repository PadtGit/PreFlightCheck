<#
.SYNOPSIS
    Claude Code PreToolUse hook that blocks live PreFlightCheck maintenance runs.
.DESCRIPTION
    Reads the hook payload from stdin. When a shell command would invoke a maintenance
    entry point without a statically enabled -WhatIf on that invocation, exits 2.
    Only entry points with preview support are permitted. Dynamic invocations and
    unsupported shell wrappers fail closed; file reads and tests remain available.
#>
[CmdletBinding()]
param ()

$entryPoints = '^(Start-Maintenance\.(ps1|cmd)|PreBackupMaintenance\.ps1|Invoke-PreBackupRun\.ps1|' +
    'Invoke-GuiTask\.ps1|Update-Applications\.ps1|Weekly-DellReview\.ps1)$'
$previewEntryPoints = @('PreBackupMaintenance.ps1', 'Update-Applications.ps1', 'Weekly-DellReview.ps1')
$entryPointReference = '(Start-Maintenance\.(ps1|cmd)|PreBackupMaintenance\.ps1|Invoke-PreBackupRun\.ps1|' +
    'Invoke-GuiTask\.ps1|Update-Applications\.ps1|Weekly-DellReview\.ps1)'
$referenceCommands = @('Get-Content', 'Get-Item', 'Test-Path', 'Select-String', 'Write-Output',
    'cat', 'head', 'tail', 'grep', 'ls', 'dir', 'type')

function Test-PreviewArgument {
    <# .SYNOPSIS
    Requires one literal enabled WhatIf switch and rejects dynamic arguments.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([object[]]$Elements, [bool]$NativeArguments, [string]$Tool)
    $switches = 0
    foreach ($element in $Elements) {
        if ($element -is [Management.Automation.Language.CommandParameterAst]) {
            if ($element.ParameterName -eq 'WhatIf') {
                $switches++
                if ($null -ne $element.Argument) {
                    if ($Tool -eq 'Bash' -or $element.Argument.Extent.Text -ine '$true') { return $false }
                }
            } elseif ($element.ParameterName -eq '%' -or
                ($null -ne $element.Argument -and $element.Argument -isnot [Management.Automation.Language.ConstantExpressionAst])) {
                return $false
            }
        } elseif ($element -is [Management.Automation.Language.StringConstantExpressionAst]) {
            # Quoted switches are positional data in PowerShell script calls, but
            # native -File hosts receive them as command-line switches.
            if ($NativeArguments -and $element.Value -eq '-WhatIf') { $switches++ }
            elseif ($NativeArguments -and $element.Value -like '-WhatIf:*') { return $false }
        } elseif ($element -isnot [Management.Automation.Language.ConstantExpressionAst]) { return $false }
    }
    return $switches -eq 1
}

function Test-MaintenanceCommand {
    <# .SYNOPSIS
    Checks every static invocation, including literal PowerShell -Command bodies.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Command, [string]$Tool, [int]$Depth = 0)
    if ($Depth -gt 8 -or [string]::IsNullOrWhiteSpace($Command)) { return $false }
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { return $false }
    # Method wrappers have no CommandAst to inspect. Fail closed when source carries
    # a maintenance reference and any method invocation, including variable-mediated
    # construction and process launches. Use direct commands for inspectable previews.
    if ($Command -match $entryPointReference) {
        $dynamicMethods = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst]
        }, $true))
        if ($dynamicMethods.Count -gt 0) { return $false }
    }
    $invocations = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    foreach ($invocation in $invocations) {
        $name = $invocation.GetCommandName()
        if (-not $name) { return $false }
        $leaf = ($name -split '[\\/]')[-1]
        $elements = @($invocation.CommandElements | Select-Object -Skip 1)
        if ($leaf -in @('Invoke-Expression', 'iex')) { return $false }
        if ($leaf -match $entryPoints) {
            if ($leaf -notin $previewEntryPoints -or
                -not (Test-PreviewArgument -Elements $elements -NativeArguments $false -Tool $Tool)) { return $false }
        } elseif ($leaf -match '^(pwsh|powershell)(\.exe)?$') {
            $hostMode = -1
            for ($index = 0; $index -lt $elements.Count; $index++) {
                if ($elements[$index].Extent.Text -in @('-File', '-Command')) { $hostMode = $index; break }
            }
            if ($hostMode -lt 0) { return $false }
            # Only supported static host options may precede the execution mode.
            # A second mode, encoded body or positional script must not be ignored.
            for ($index = 0; $index -lt $hostMode; $index++) {
                $option = $elements[$index]
                if ($option -isnot [Management.Automation.Language.CommandParameterAst] -or $null -ne $option.Argument) { return $false }
                if ($option.ParameterName -in @('NoProfile', 'NoLogo', 'NonInteractive', 'STA', 'MTA')) { continue }
                if ($option.ParameterName -notin @('ExecutionPolicy', 'InputFormat', 'OutputFormat', 'WorkingDirectory')) { return $false }
                $index++
                if ($index -ge $hostMode -or $elements[$index] -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return $false }
            }
            $arguments = @($elements | Select-Object -Skip ($hostMode + 1))
            if ($arguments.Count -eq 0) { return $false }
            if ($elements[$hostMode].Extent.Text -eq '-File') {
                if ($arguments[0] -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return $false }
                if ($arguments[0].Value -eq '-') { return $false }
                $scriptLeaf = ($arguments[0].Value -split '[\\/]')[-1]
                if ($scriptLeaf -match $entryPoints) {
                    if ($scriptLeaf -notin $previewEntryPoints -or
                        -not (Test-PreviewArgument -Elements @($arguments | Select-Object -Skip 1) -NativeArguments $true -Tool $Tool)) { return $false }
                }
            } else {
                if (@($arguments | Where-Object { $_ -isnot [Management.Automation.Language.StringConstantExpressionAst] }).Count -gt 0) { return $false }
                $body = if ($arguments.Count -eq 1) { $arguments[0].Value } else { ($arguments.Extent.Text -join ' ') }
                if ($body -eq '-') { return $false }
                # A literal body is evaluated by PowerShell, regardless of the outer shell.
                if (-not (Test-MaintenanceCommand -Command $body -Tool PowerShell -Depth ($Depth + 1))) { return $false }
            }
        } elseif ($invocation.Extent.Text -match $entryPointReference) {
            if ($leaf -in @('git', 'rg')) {
                $values = @($elements | ForEach-Object {
                    if ($_ -is [Management.Automation.Language.StringConstantExpressionAst]) { $_.Value }
                    else { $_.Extent.Text }
                })
                if ($leaf -eq 'git') {
                    if ($values.Count -eq 0 -or $values[0] -notin @('diff', 'show', 'log', 'status', 'blame', 'ls-files') -or
                        @($values | Where-Object { $_ -match '^(--ext-diff|--textconv|--exec-path|--config-env|-c)(=|$)' }).Count -gt 0) { return $false }
                } elseif (@($values | Where-Object { $_ -match '^--pre(=|$)' }).Count -gt 0) { return $false }
                if (@($elements | Where-Object {
                    $_ -isnot [Management.Automation.Language.ConstantExpressionAst] -and
                    $_ -isnot [Management.Automation.Language.CommandParameterAst]
                }).Count -gt 0) { return $false }
            } elseif ($leaf -notin $referenceCommands) { return $false }
        }
    }
    return $true
}

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
    if ($payload.tool_input.command -isnot [string]) { throw 'The payload must contain a command string.' }
    $safe = Test-MaintenanceCommand -Command $payload.tool_input.command -Tool ([string]$payload.tool_name)
} catch {
    [Console]::Error.WriteLine("Block-LiveMaintenance: unreadable hook payload: $($_.Exception.Message)")
    exit 2
}

if (-not $safe) {
    [Console]::Error.WriteLine(
        'Blocked: the command is live or cannot be verified as a static preview. Each supported ' +
        'maintenance invocation requires its own enabled -WhatIf. Use Pester mocks or ask Bob to run it himself.')
    exit 2
}

exit 0
