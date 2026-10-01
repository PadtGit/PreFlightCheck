Describe 'Maintenance hook invocation checks' {
    BeforeAll {
        $hookPath = Join-Path (Split-Path $PSScriptRoot -Parent) '.claude/hooks/Block-LiveMaintenance.ps1'
        function Invoke-HookDecision {
            param([string]$Command, [string]$Tool = 'PowerShell')
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = (Get-Command pwsh).Source
            $start.ArgumentList.Add('-NoProfile')
            $start.ArgumentList.Add('-File')
            $start.ArgumentList.Add($hookPath)
            $start.UseShellExecute = $false
            $start.RedirectStandardInput = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            try {
                $process.StandardInput.WriteLine((@{ tool_name = $Tool; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress))
                $process.StandardInput.Close()
                $errorText = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                [pscustomobject]@{ ExitCode = $process.ExitCode; Error = $errorText }
            } finally { $process.Dispose() }
        }
    }

    It 'allows supported static previews and read-only references: <Command>' -ForEach @(
        @{ Command = '.\PreBackupMaintenance.ps1 -Mode Clean -WhatIf' },
        @{ Command = '& ".\PreBackupMaintenance.ps1" -WhatIf:$true' },
        @{ Command = 'pwsh -NoProfile -File ./Update-Applications.ps1 -WhatIf' },
        @{ Command = 'powershell.exe -NoProfile -Command ''.\Weekly-DellReview.ps1 -WhatIf''' },
        @{ Command = '.\PreBackupMaintenance.ps1 -WhatIf; .\Weekly-DellReview.ps1 -WhatIf' },
        @{ Command = 'Get-Content .\PreBackupMaintenance.ps1' },
        @{ Command = 'Write-Output "PreBackupMaintenance.ps1 -WhatIf"' },
        @{ Command = '# .\PreBackupMaintenance.ps1 -Mode Clean' },
        @{ Command = 'Invoke-Pester -Path ./tests' }
        @{ Command = '.\PreBackupMaintenance.ps1 -MinimumAgeDays 14 -WhatIf' },
        @{ Command = 'pwsh -NoProfile -File ./PreBackupMaintenance.ps1 -MinimumAgeDays 14 -WhatIf' },
        @{ Command = 'git diff -- PreBackupMaintenance.ps1' },
        @{ Command = 'rg WhatIf PreBackupMaintenance.ps1' }
    ) {
        (Invoke-HookDecision -Command $Command).ExitCode | Should -Be 0
    }

    It 'blocks missing, disabled, unrelated, or ambiguous previews: <Command>' -ForEach @(
        @{ Command = '.\PreBackupMaintenance.ps1 -Mode Clean' },
        @{ Command = '.\PreBackupMaintenance.ps1 -WhatIf:$false' },
        @{ Command = '.\PreBackupMaintenance.ps1 -Mode Clean # -WhatIf' },
        @{ Command = '.\PreBackupMaintenance.ps1 -ReportDirectory "C:\-WhatIf"' },
        @{ Command = '.\PreBackupMaintenance.ps1 -WhatIf; .\Weekly-DellReview.ps1' },
        @{ Command = '.\PreBackupMaintenance.ps1 -WhatIf | .\Weekly-DellReview.ps1' },
        @{ Command = 'pwsh -File .\PreBackupMaintenance.ps1 -WhatIf:$false' },
        @{ Command = 'pwsh -Command ''.\PreBackupMaintenance.ps1 # -WhatIf''' },
        @{ Command = 'pwsh -Command ''.\PreBackupMaintenance.ps1 -WhatIf; .\Weekly-DellReview.ps1''' },
        @{ Command = '.\PreBackupMaintenance.ps1 -WhatIf:$enabled' },
        @{ Command = '.\PreBackupMaintenance.ps1 @parameters -WhatIf' },
        @{ Command = '.\PreBackupMaintenance.ps1 "-WhatIf"' },
        @{ Command = '.\Start-Maintenance.ps1 -WhatIf' },
        @{ Command = '.\Start-Maintenance.cmd -WhatIf' },
        @{ Command = '.\Invoke-GuiTask.ps1 -WhatIf' },
        @{ Command = '.\Invoke-PreBackupRun.ps1 -WhatIf' },
        @{ Command = '$script = ''.\PreBackupMaintenance.ps1''; & $script -WhatIf' },
        @{ Command = 'cmd.exe /c "powershell -File PreBackupMaintenance.ps1 -WhatIf"' }
        @{ Command = 'pwsh -EncodedCommand ZQB4AGkAdAA= -File ./PreBackupMaintenance.ps1 -WhatIf' },
        @{ Command = 'git -c alias.run=''!pwsh -File PreBackupMaintenance.ps1 -WhatIf:$false'' run' },
        @{ Command = 'rg --pre ''pwsh -File PreBackupMaintenance.ps1 -WhatIf:$false'' pattern file' },
        @{ Command = '' }
        @{ Command = 'Write-Output ''.\PreBackupMaintenance.ps1 -Mode Clean'' | Invoke-Expression' },
        @{ Command = '$command = ''.\PreBackupMaintenance.ps1 -Mode Clean''; iex $command' }
    ) {
        $result = Invoke-HookDecision -Command $Command
        $result.ExitCode | Should -Be 2
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'blocks dynamic truth in a Bash host invocation' {
        (Invoke-HookDecision -Tool Bash -Command 'pwsh -File ./PreBackupMaintenance.ps1 -WhatIf:$true').ExitCode | Should -Be 2
    }

    It 'allows a bare preview switch in a Bash host invocation' {
        (Invoke-HookDecision -Tool Bash -Command 'pwsh -File ./PreBackupMaintenance.ps1 -WhatIf').ExitCode | Should -Be 0
    }

    It 'blocks method-based dynamic maintenance execution: <Command>' -ForEach @(
        @{ Command = '[scriptblock]::Create(''.\PreBackupMaintenance.ps1 -Mode Clean'').Invoke()' },
        @{ Command = '$command = ''.\PreBackupMaintenance.ps1 -Mode Clean''; [scriptblock]::Create($command).Invoke()' },
        @{ Command = '[powershell]::Create().AddScript(''.\PreBackupMaintenance.ps1 -Mode Clean'').Invoke()' }
        @{ Command = '[Diagnostics.Process]::Start(''pwsh'', ''-File .\PreBackupMaintenance.ps1 -Mode Clean'')' },
        @{ Command = 'Get-Content ./Invoke-PreBackupRun.ps1 | pwsh -File -' },
        @{ Command = 'Get-Content ./Invoke-PreBackupRun.ps1 | pwsh -Command -' }
    ) {
        (Invoke-HookDecision -Command $Command).ExitCode | Should -Be 2
    }
}
