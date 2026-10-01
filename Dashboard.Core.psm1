#Requires -Version 7.0

Set-StrictMode -Version Latest

function Get-DashboardStateStyle {
    <#
    .SYNOPSIS
        Returns the dashboard label and colors for an operator-facing state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Idle','Running','Success','Review','ActionNeeded','Restart','Repair','CleanupLocked')]
        [string]$State
    )

    switch ($State) {
        'Idle' { return [pscustomobject]@{ Label = 'IDLE — Ready'; Foreground = '#ADC0D2'; Background = '#172534'; Border = '#4A6178' } }
        'Running' { return [pscustomobject]@{ Label = 'RUNNING — Maintenance in progress'; Foreground = '#8BD5FF'; Background = '#102B3A'; Border = '#2D93C4' } }
        'Success' { return [pscustomobject]@{ Label = 'SUCCESS — Task completed'; Foreground = '#7BE0B5'; Background = '#12352F'; Border = '#2A9D78' } }
        'Review' { return [pscustomobject]@{ Label = 'REVIEW — Open the saved report'; Foreground = '#F3C87F'; Background = '#3A2D16'; Border = '#C99339' } }
        'CleanupLocked' { return [pscustomobject]@{ Label = 'CLEANUP LOCKED — run Windows health checks first'; Foreground = '#F3C87F'; Background = '#3A2D16'; Border = '#C99339' } }
        'ActionNeeded' { return [pscustomobject]@{ Label = 'ACTION NEEDED — Open the saved result'; Foreground = '#F2A093'; Background = '#3B201E'; Border = '#C85A4A' } }
        'Restart' { return [pscustomobject]@{ Label = 'RESTART — Required before cleanup or backup'; Foreground = '#FFD08A'; Background = '#3B2917'; Border = '#D98A32' } }
        'Repair' { return [pscustomobject]@{ Label = 'REPAIR — Windows repair recommended'; Foreground = '#FFAD8A'; Background = '#3B241C'; Border = '#D66D45' } }
    }
}

function Get-GuiResultPresentation {
    <#
    .SYNOPSIS
        Maps a worker result to the dashboard state, label, and next action.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [bool]$RestartRequired = $false,
        [bool]$RepairRecommended = $false,
        [ValidateRange(0, [int]::MaxValue)][int]$ReviewFindingCount = 0
    )

    if ($RestartRequired) {
        return [pscustomobject]@{
            State = 'Restart'
            StatusLabel = 'RESTART — Required before cleanup or backup'
            NextAction = 'Restart Windows, then begin a new guided run.'
        }
    }
    if ($RepairRecommended) {
        return [pscustomobject]@{
            State = 'Repair'
            StatusLabel = 'REPAIR — Windows repair recommended'
            NextAction = 'Open the health report and run Repair Windows before cleanup.'
        }
    }
    if ($ExitCode -eq 0) {
        return [pscustomobject]@{
            State = 'Success'
            StatusLabel = 'SUCCESS — Task completed'
            NextAction = 'Review the saved result before continuing.'
        }
    }
    if ($ExitCode -eq 2) {
        $findingLabel = if ($ReviewFindingCount -eq 1) { '1 finding needs attention' } elseif ($ReviewFindingCount -gt 1) { "$ReviewFindingCount findings need attention" } else { 'Open the saved report' }
        return [pscustomobject]@{
            State = 'Review'
            StatusLabel = "REVIEW — $findingLabel"
            NextAction = 'Review the listed findings and saved reports before continuing.'
        }
    }

    return [pscustomobject]@{
        State = 'ActionNeeded'
        StatusLabel = "ACTION NEEDED — Task stopped (exit code $ExitCode)"
        NextAction = 'Open the saved result and detailed console output before retrying.'
    }
}

function Get-GuiResultEvidence {
    <#
    .SYNOPSIS
        Separates a task's stopping reason from report review findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][int]$ExitCode,
        [psobject]$Report,
        [string]$ReportPath,
        [psobject]$GuidedResult,
        [string]$ConsolePath
    )

    $reason = ''
    $rawReason = ''
    $findings = @()
    if ($Task -eq 'PreBackupRun' -and $GuidedResult) {
        if ($ExitCode -ne 0) {
            $rawReason = [string]$GuidedResult.Message
            $reason = $rawReason
            $reportMarker = $reason.LastIndexOf(' Report: ', [StringComparison]::OrdinalIgnoreCase)
            $reviewMarker = $reason.LastIndexOf(' Review ', [StringComparison]::OrdinalIgnoreCase)
            if ($reportMarker -gt $reviewMarker -and $reviewMarker -ge 0 -and $reason.Substring($reviewMarker + 8) -match '^[A-Za-z]:\\') {
                $reason = $reason.Substring(0, $reviewMarker).TrimEnd()
            }
        }
        $findings = @($GuidedResult.ReviewFindings | Where-Object { $null -ne $_ })
    } elseif ($Report) {
        $failed = @($Report.Results | Where-Object { $_.Status -eq 'Failed' })
        $review = @($Report.Results | Where-Object { $_.Status -eq 'Review' })
        if ($failed.Count -gt 0) { $reason = (@($failed | ForEach-Object { "$($_.Step): $($_.Detail)" }) -join '; ') }
        elseif ($ExitCode -eq 2 -and $review.Count -gt 0) { $reason = "$($review[0].Step): $($review[0].Detail)" }
        $findings = @($review | ForEach-Object {
            [pscustomobject]@{ Step = $Task; Check = [string]$_.Step; Detail = [string]$_.Detail; Report = $ReportPath; Status = [string]$_.Status }
        })
    }
    $toolOutput = ''
    if ($ExitCode -ne 0 -and $ConsolePath -and (Test-Path -LiteralPath $ConsolePath)) {
        $lines = @(Get-Content -LiteralPath $ConsolePath -Tail 200 -ErrorAction Stop)
        if ([string]::IsNullOrWhiteSpace($reason)) {
            foreach ($line in $lines) {
                if ($line -match '\.ps1\s*:\s*(?<Message>.+)$') { $reason = $Matches.Message.Trim() }
                elseif ($line -match '^\s*\[Failed\]\s*(?<Message>.+)$') { $reason = $Matches.Message.Trim() }
            }
        }
        $failureIndex = -1
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            if ($lines[$index] -match '^\s*\[Failed\]') { $failureIndex = $index; break }
        }
        if ($failureIndex -ge 0) {
            $context = [System.Collections.Generic.List[string]]::new()
            for ($index = $failureIndex - 1; $index -ge 0 -and $context.Count -lt 4; $index--) {
                $line = ([string]$lines[$index]).Trim()
                if ($line -match '^\s*\[(RUNNING|Observed|Completed|Review|Failed)\]' -or $line -match '^\[\d{4}-\d{2}-\d{2} ') { break }
                if ($line) { $context.Insert(0, $line) }
            }
            $toolOutput = $context -join [Environment]::NewLine
        }
    }
    if ($ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($reason)) {
        $reason = 'No specific reason was recorded in the saved report. Check the detailed output.'
    }
    $applicationOutput = ''
    if ($Report -and $Task -in @('UpdatePreview','InstalledApps')) {
        $outputStep = if ($Task -eq 'InstalledApps') { 'InstalledAppsOutput' } else { 'AvailableAppUpdatesOutput' }
        $applicationOutput = (@($Report.Results | Where-Object { $_.Step -eq $outputStep } | ForEach-Object { [string]$_.Detail }) -join [Environment]::NewLine)
    }
    [pscustomobject]@{ Reason = $reason; RawReason = $rawReason; Findings = $findings; ToolOutput = $toolOutput; ReportPath = $ReportPath; ApplicationOutput = $applicationOutput }
}

function Format-GuiTaskSummary {
    <#
    .SYNOPSIS
        Formats the concise dashboard task result saved for the operator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Presentation,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][datetime]$Finished,
        [Parameter(Mandatory)][int]$ExitCode,
        [psobject]$Evidence,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$ConsolePath
    )

    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $summaryLines.Add([string]$Presentation.StatusLabel)
    $summaryLines.Add("Task: $Task")
    $summaryLines.Add("Finished: $($Finished.ToString('yyyy-MM-dd HH:mm:ss'))")
    $meaning = if ($ExitCode -eq 0) { 'completed' } elseif ($ExitCode -eq 2) { 'review needed' } else { 'stopped or failed' }
    $summaryLines.Add("Exit code: $ExitCode ($meaning)")
    if ($ExitCode -ne 0 -and $Evidence -and $Evidence.Reason) { $summaryLines.Add("Reason: $($Evidence.Reason)") }
    if ($ExitCode -ne 0 -and $Evidence -and $Evidence.ToolOutput) { $summaryLines.Add("Tool output: $($Evidence.ToolOutput)") }
    if ($Task -eq 'PreBackupRun' -and $ExitCode -eq 1) { $summaryLines.Add('The guided sequence stopped here; later steps were not run.') }
    $summaryLines.Add("Next: $($Presentation.NextAction)")
    if ($Evidence -and $Evidence.PSObject.Properties['ApplicationOutput'] -and $Evidence.ApplicationOutput) {
        $summaryLines.Add('WinGet application list: Select Show details to view the saved output.')
    }
    if ($ExitCode -ne 0 -and $Evidence -and @($Evidence.Findings).Count -gt 0) {
        $count = @($Evidence.Findings).Count
        $label = if ($count -eq 1) { 'finding' } else { 'findings' }
        $summaryLines.Add("$count $label in the saved reports. Select Show details to inspect them.")
    }
    $summaryLines.Add("Detailed output: $ConsolePath")
    $summaryLines.Add("Results: $RunDirectory")
    return $summaryLines -join [Environment]::NewLine
}

function Format-GuiTaskDetail {
    <#
    .SYNOPSIS
        Formats saved task output and expandable evidence for review or action.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Presentation,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][datetime]$Finished,
        [Parameter(Mandatory)][int]$ExitCode,
        [psobject]$Evidence,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$ConsolePath
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Format-GuiTaskSummary -Presentation $Presentation -Task $Task -Finished $Finished -ExitCode $ExitCode -Evidence $Evidence -RunDirectory $RunDirectory -ConsolePath $ConsolePath))
    if ($Evidence -and $Evidence.PSObject.Properties['ApplicationOutput'] -and $Evidence.ApplicationOutput) {
        $lines.Add('')
        $lines.Add('WinGet application list:')
        $lines.Add([string]$Evidence.ApplicationOutput)
    }
    if ($ExitCode -eq 0) { return $lines -join [Environment]::NewLine }
    if ($Evidence -and $Evidence.ToolOutput) {
        $lines.Add('')
        $lines.Add('Recent tool output near the failure:')
        $lines.Add([string]$Evidence.ToolOutput)
    }
    if ($Evidence -and $Evidence.PSObject.Properties['RawReason'] -and $Evidence.RawReason -and $Evidence.RawReason -ne $Evidence.Reason) {
        $lines.Add('')
        $lines.Add("Recorded stop: $($Evidence.RawReason)")
    }
    if ($Evidence -and $Evidence.PSObject.Properties['ReportPath'] -and $Evidence.ReportPath) {
        $lines.Add('')
        $lines.Add("Report: $($Evidence.ReportPath)")
    }
    if ($Evidence -and @($Evidence.Findings).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Report findings (separate from the stopping reason):')
        foreach ($finding in $Evidence.Findings) {
            $lines.Add("- $($finding.Step) / $($finding.Check): $($finding.Detail)")
            if ($finding.Report -and (-not $Evidence.PSObject.Properties['ReportPath'] -or $finding.Report -ne $Evidence.ReportPath)) { $lines.Add("  Report: $($finding.Report)") }
        }
    }
    $lines.Add('')
    $lines.Add('Exit code legend: 0 = completed; 1 = stopped or failed; 2 = completed with review findings.')
    return $lines -join [Environment]::NewLine
}

function Get-LiveActivityState {
    <#
    .SYNOPSIS
        Reads current worker activity and returns dashboard-ready state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$ConsolePath,
        [string]$ActivityPath,
        [Parameter(Mandatory)][datetime]$StartedAt,
        [datetime]$Now = [datetime]::Now,
        [psobject]$PreviousState,
        [ValidateRange(1, 100)][int]$MaximumLines = 14,
        [ValidateRange(1, 2000)][int]$ScanLines = 300
    )

    $currentOperation = $Task
    $percentage = $null
    $operationActive = $false
    $activityMarker = $null
    $consoleOffset = [long]0
    $pendingText = ''
    if ($PreviousState) {
        if ($PreviousState.PSObject.Properties['CurrentOperation']) { $currentOperation = [string]$PreviousState.CurrentOperation }
        if ($PreviousState.PSObject.Properties['Percentage'] -and $null -ne $PreviousState.Percentage) { $percentage = [double]$PreviousState.Percentage }
        if ($PreviousState.PSObject.Properties['OperationActive']) { $operationActive = [bool]$PreviousState.OperationActive }
        if ($PreviousState.PSObject.Properties['ActivityMarker']) { $activityMarker = [string]$PreviousState.ActivityMarker }
        if ($PreviousState.PSObject.Properties['ConsoleOffset']) { $consoleOffset = [long]$PreviousState.ConsoleOffset }
        if ($PreviousState.PSObject.Properties['PendingText']) { $pendingText = [string]$PreviousState.PendingText }
    }

    $boundedScanLines = [Math]::Max($MaximumLines, $ScanLines)
    $parseLines = @()
    $displayLines = @()
    if (Test-Path -LiteralPath $ConsolePath) {
        $consoleFile = Get-Item -LiteralPath $ConsolePath -ErrorAction Stop
        $displayLines = @(Get-Content -LiteralPath $consoleFile.FullName -Tail $MaximumLines -ErrorAction Stop)
        $canContinue = $PreviousState -and $consoleOffset -ge 0 -and $consoleOffset -le $consoleFile.Length
        if ($canContinue) {
            if ($consoleOffset -lt $consoleFile.Length) {
                $stream = [IO.FileStream]::new($consoleFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    [void]$stream.Seek($consoleOffset, [IO.SeekOrigin]::Begin)
                    $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true, 1024, $true)
                    try { $appendedText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    $consoleOffset = $stream.Position
                } finally { $stream.Dispose() }
                if ($appendedText) {
                    $combinedText = $pendingText + $appendedText
                    $completeRecords = [regex]::Matches($combinedText, '(?s)(?<Line>.*?)(?:\r\n|\n|\r)')
                    $parseLines = @($completeRecords | ForEach-Object { $_.Groups['Line'].Value })
                    $consumedCharacters = if ($completeRecords.Count -gt 0) { $completeRecords[$completeRecords.Count - 1].Index + $completeRecords[$completeRecords.Count - 1].Length } else { 0 }
                    $pendingText = $combinedText.Substring($consumedCharacters)
                }
            }
        } else {
            $parseLines = @(Get-Content -LiteralPath $consoleFile.FullName -Tail $boundedScanLines -ErrorAction Stop)
            $consoleOffset = $consoleFile.Length
            if ($consoleFile.Length -gt 0) {
                $tailStream = [IO.FileStream]::new($consoleFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    [void]$tailStream.Seek(-1, [IO.SeekOrigin]::End)
                    $lastByte = $tailStream.ReadByte()
                } finally { $tailStream.Dispose() }
                if ($lastByte -notin @(10, 13) -and $parseLines.Count -gt 0) {
                    $pendingText = [string]$parseLines[$parseLines.Count - 1]
                    $parseLines = if ($parseLines.Count -gt 1) { @($parseLines | Select-Object -First ($parseLines.Count - 1)) } else { @() }
                }
            }
        }
    }
    $ansiPattern = "$([char]27)\[[0-?]*[ -/]*[@-~]"
    $displayLines = @($displayLines | ForEach-Object { ([string]$_).Replace([string][char]0, '') -replace $ansiPattern, '' })
    if ($displayLines.Count -eq 0) { $displayLines = @('Waiting for worker output…') }

    $operationMarkerSeen = $false
    foreach ($lineValue in $parseLines) {
        $line = ([string]$lineValue).Replace([string][char]0, '') -replace $ansiPattern, ''
        if ($line -match '^\s*\[RUNNING\]\s*(?<Key>[^:]+):\s*(?<Description>.+?)\s*$') {
            $currentOperation = "$($Matches.Key.Trim()): $($Matches.Description.Trim())"
            $percentage = $null
            $operationActive = $true
            $operationMarkerSeen = $true
            continue
        }
        if ($line -match '^\s*START\s+(?<Step>.+?)\s*$') {
            $currentOperation = "START $($Matches.Step.Trim())"
            $percentage = $null
            $operationActive = $true
            $activityMarker = $currentOperation
            $operationMarkerSeen = $true
            continue
        }
        if ($line -match '^\s*\[(?:Observed|Completed|Review|Failed)\]\s+') {
            $currentOperation = 'Waiting for the next operation…'
            $percentage = $null
            $operationActive = $false
            continue
        }
        if (-not $operationActive) { continue }

        $percentMatches = [regex]::Matches($line, '(?<![\d.,])(?<Value>\d{1,3}(?:[.,]\d+)?)\s*(?:%|percent\b)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($percentMatches.Count -eq 0) { continue }
        $candidate = $percentMatches[$percentMatches.Count - 1].Groups['Value'].Value.Replace(',', '.')
        $parsed = 0.0
        if ([double]::TryParse($candidate, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 100) {
            $percentage = $parsed
        }
    }

    if ($ActivityPath -and (Test-Path -LiteralPath $ActivityPath)) {
        $guidedActivity = (Get-Content -LiteralPath $ActivityPath -Raw -ErrorAction Stop).Trim()
        if ($guidedActivity -and $guidedActivity -ne $activityMarker) {
            $activityMarker = $guidedActivity
            if (-not $operationMarkerSeen) {
                $currentOperation = $guidedActivity
                $percentage = $null
                $operationActive = $true
            }
        }
    }

    $elapsed = $Now - $StartedAt
    if ($elapsed -lt [timespan]::Zero) { $elapsed = [timespan]::Zero }
    $elapsedText = '{0:D2}:{1:D2}:{2:D2}' -f ([long][Math]::Floor($elapsed.TotalHours)), $elapsed.Minutes, $elapsed.Seconds
    return [pscustomobject]@{
        Task = $Task
        TaskStatus = 'Running'
        CurrentOperation = $currentOperation
        Percentage = $percentage
        IsIndeterminate = ($null -eq $percentage)
        OperationActive = $operationActive
        ActivityMarker = $activityMarker
        ConsoleOffset = $consoleOffset
        PendingText = $pendingText
        ElapsedText = $elapsedText
        ConsoleText = $displayLines -join [Environment]::NewLine
    }
}

function Get-LiveActivityText {
    <#
    .SYNOPSIS
        Formats live worker activity for the dashboard output panel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$ConsolePath,
        [string]$ActivityPath,
        [ValidateRange(1, 100)][int]$MaximumLines = 14,
        [datetime]$StartedAt = [datetime]::Now,
        [datetime]$Now = [datetime]::Now,
        [psobject]$PreviousState,
        [ValidateRange(1, 2000)][int]$ScanLines = 300
    )

    $state = Get-LiveActivityState -Task $Task -ConsolePath $ConsolePath -ActivityPath $ActivityPath -StartedAt $StartedAt -Now $Now -PreviousState $PreviousState -MaximumLines $MaximumLines -ScanLines $ScanLines
    $progressText = if ($null -eq $state.Percentage) { 'Working…' } else { $state.Percentage.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + '%' }
    return @(
        "RUNNING — $Task"
        "Current step: $($state.CurrentOperation)"
        "Elapsed: $($state.ElapsedText)  Progress: $progressText"
        "Live activity (latest $MaximumLines lines)"
        "Detailed output: $ConsolePath"
        ''
        $state.ConsoleText
    ) -join [Environment]::NewLine
}

function Get-CleanupSelectionKey {
    <# .SYNOPSIS Identifies valid cleanup selections for matching a completed preview. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$MinimumAgeDays, [bool]$EmptyRecycleBin, [bool]$ClearDeliveryCache)
    $age = 0
    if (-not [int]::TryParse($MinimumAgeDays, [ref]$age) -or $age -lt 7 -or $age -gt 365) { return $null }
    return '{0}|{1}|{2}' -f $age, $EmptyRecycleBin, $ClearDeliveryCache
}

Export-ModuleMember -Function Get-CleanupSelectionKey, Get-DashboardStateStyle, Get-GuiResultPresentation, Get-GuiResultEvidence, Format-GuiTaskSummary, Format-GuiTaskDetail, Get-LiveActivityState, Get-LiveActivityText
