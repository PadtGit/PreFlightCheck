BeforeAll {
    $script:hookDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) '.claude/hooks'

    function Invoke-ClaudeHook {
        <#
        .SYNOPSIS
            Runs a hook script with a JSON payload on stdin and returns its exit code, stdout, and stderr.
        #>
        param ([string]$HookName, [hashtable]$Payload, [string]$ProjectDirectory)
        $outputFile = Join-Path $TestDrive 'hook-stdout.txt'
        $errorFile = Join-Path $TestDrive 'hook-stderr.txt'
        $env:CLAUDE_PROJECT_DIR = $ProjectDirectory
        try {
            $Payload | ConvertTo-Json -Compress |
                & pwsh -NoLogo -NoProfile -File (Join-Path $script:hookDirectory $HookName) 2> $errorFile > $outputFile
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output = [string](Get-Content -LiteralPath $outputFile -Raw)
                Errors = [string](Get-Content -LiteralPath $errorFile -Raw)
            }
        } finally {
            Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Claude Code edit-check hook' {
    BeforeAll {
        function Invoke-EditHook {
            <#
            .SYNOPSIS
                Runs the hook with a PostToolUse payload for FilePath and returns its exit code and stderr.
            #>
            param ([string]$FilePath)
            $payload = @{ hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = @{ file_path = $FilePath } }
            Invoke-ClaudeHook -HookName 'Test-EditedScript.ps1' -Payload $payload -ProjectDirectory $TestDrive
        }
    }

    It 'passes a clean PS5.1 script' {
        $path = Join-Path $TestDrive 'Clean.ps1'
        Set-Content -LiteralPath $path -Value "#Requires -Version 5.1`r`n[CmdletBinding()]`r`nparam ()`r`n`$null = 1"
        (Invoke-EditHook -FilePath $path).ExitCode | Should -Be 0
    }

    It 'blocks PS7-only syntax in a PS5.1 script' {
        $path = Join-Path $TestDrive 'Ps7Only.ps1'
        Set-Content -LiteralPath $path -Value "#Requires -Version 5.1`r`n[CmdletBinding()]`r`nparam ()`r`n`$null = `$null ?? 1"
        $result = Invoke-EditHook -FilePath $path
        $result.ExitCode | Should -Be 2
        $result.Errors | Should -Match 'PS5\.1 parse error'
    }

    It 'reports release-blocking analyzer findings' {
        $path = Join-Path $TestDrive 'Alias.ps1'
        Set-Content -LiteralPath $path -Value "[CmdletBinding()]`r`nparam ()`r`ngci | Out-Null"
        $result = Invoke-EditHook -FilePath $path
        $result.ExitCode | Should -Be 2
        $result.Errors | Should -Match 'PSAvoidUsingCmdletAliases'
    }

    It 'ignores non-PowerShell files and files outside the project' {
        $textPath = Join-Path $TestDrive 'notes.txt'
        Set-Content -LiteralPath $textPath -Value 'gci'
        (Invoke-EditHook -FilePath $textPath).ExitCode | Should -Be 0
        $outsidePath = Join-Path ([IO.Path]::GetTempPath()) ('pfc-hook-{0}.ps1' -f [guid]::NewGuid())
        try {
            Set-Content -LiteralPath $outsidePath -Value 'gci'
            (Invoke-EditHook -FilePath $outsidePath).ExitCode | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $outsidePath -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Claude Code skill-copy hook' {
    BeforeEach {
        $script:project = Join-Path $TestDrive ('skills-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -Path (Join-Path $script:project '.claude/skills/demo') -ItemType Directory -Force
        $null = New-Item -Path (Join-Path $script:project '.agents/skills') -ItemType Directory -Force

        function Invoke-SkillHook {
            <#
            .SYNOPSIS
                Runs the hook for one hook event and file path in the per-test project.
            #>
            param ([string]$HookEvent, [string]$FilePath)
            $payload = @{ hook_event_name = $HookEvent; tool_name = 'Write'; tool_input = @{ file_path = $FilePath } }
            Invoke-ClaudeHook -HookName 'Sync-AgentSkill.ps1' -Payload $payload -ProjectDirectory $script:project
        }
    }

    It 'copies an edited Claude Code skill file to the same path in .agents/skills' {
        $source = Join-Path $script:project '.claude/skills/demo/SKILL.md'
        Set-Content -LiteralPath $source -Value "---`nname: demo`n---`nUpdated body"
        (Invoke-SkillHook -HookEvent PostToolUse -FilePath $source).ExitCode | Should -Be 0
        $copy = Join-Path $script:project '.agents/skills/demo/SKILL.md'
        $copy | Should -Exist
        Get-Content -LiteralPath $copy -Raw | Should -BeExactly (Get-Content -LiteralPath $source -Raw)
    }

    It 'creates missing folders for a new nested skill file' {
        $source = Join-Path $script:project '.claude/skills/demo/scripts/Check.ps1'
        $null = New-Item -Path (Split-Path $source -Parent) -ItemType Directory -Force
        Set-Content -LiteralPath $source -Value '$null = 1'
        (Invoke-SkillHook -HookEvent PostToolUse -FilePath $source).ExitCode | Should -Be 0
        Join-Path $script:project '.agents/skills/demo/scripts/Check.ps1' | Should -Exist
    }

    It 'blocks a direct edit to the Codex copy and names the file to edit instead' {
        $target = Join-Path $script:project '.agents/skills/demo/SKILL.md'
        $result = Invoke-SkillHook -HookEvent PreToolUse -FilePath $target
        $result.ExitCode | Should -Be 2
        $result.Errors | Should -Match ([regex]::Escape('.claude/skills/demo/SKILL.md'))
    }

    It 'allows edits to the Claude Code copy and to unrelated files' {
        (Invoke-SkillHook -HookEvent PreToolUse -FilePath (Join-Path $script:project '.claude/skills/demo/SKILL.md')).ExitCode |
            Should -Be 0
        (Invoke-SkillHook -HookEvent PreToolUse -FilePath (Join-Path $script:project 'README.md')).ExitCode | Should -Be 0
    }

    It 'does not copy files outside .claude/skills, including paths that climb out with ..' {
        $outside = Join-Path $script:project 'notes.md'
        Set-Content -LiteralPath $outside -Value 'notes'
        (Invoke-SkillHook -HookEvent PostToolUse -FilePath $outside).ExitCode | Should -Be 0
        $climbing = Join-Path $script:project '.claude/skills/../../notes.md'
        (Invoke-SkillHook -HookEvent PostToolUse -FilePath $climbing).ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:project '.agents/skills') -Recurse -File).Count | Should -Be 0
    }
}

Describe 'Claude Code Stop verification hook' {
    BeforeAll {
        function Invoke-Git {
            <#
            .SYNOPSIS
                Runs git quietly in the per-test fixture repository.
            #>
            param ([string[]]$Arguments)
            $null = & git -C $script:project -c user.name=Pester -c user.email=pester@example.invalid `
                -c commit.gpgsign=false -c core.autocrlf=false @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
        }

        function Invoke-StopHook {
            <#
            .SYNOPSIS
                Runs the Stop hook for the fixture repository with the given stop_hook_active flag.
            #>
            param ([bool]$Active = $false)
            $payload = @{ hook_event_name = 'Stop'; session_id = 'pester-session'; stop_hook_active = $Active }
            Invoke-ClaudeHook -HookName 'Invoke-StopVerification.ps1' -Payload $payload -ProjectDirectory $script:project
        }

        function Get-VerifyRunCount {
            <#
            .SYNOPSIS
                Returns how many times the stub verification script has run.
            #>
            $log = Join-Path $script:project 'verify-runs.txt'
            if (-not (Test-Path -LiteralPath $log)) { return 0 }
            @(Get-Content -LiteralPath $log).Count
        }

        # The stub stands in for tools/Invoke-LocalVerify.ps1 so the hook never runs the real suite here.
        $script:stubVerify = @'
param ([switch]$SkipAnalysis)
$root = Split-Path -Path $PSScriptRoot -Parent
Add-Content -LiteralPath (Join-Path $root 'verify-runs.txt') -Value "SkipAnalysis=$SkipAnalysis"
'[Review] fixture noise that is not a failure'
'[-] Demo.fails on purpose 5ms (3ms|2ms)'
' Expected 1, but got 2.'
'PreFlightCheck local verification'
'  FAIL  Pester         exit 1'
exit [int](Get-Content -LiteralPath (Join-Path $root 'verify-exit.txt') -Raw)
'@
    }

    BeforeEach {
        $script:project = Join-Path $TestDrive ('stop-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -Path (Join-Path $script:project 'tools') -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $script:project 'tools/Invoke-LocalVerify.ps1') -Value $script:stubVerify
        Set-Content -LiteralPath (Join-Path $script:project 'Script.ps1') -Value '$null = 1'
        Set-Content -LiteralPath (Join-Path $script:project 'README.md') -Value 'readme'
        Set-Content -LiteralPath (Join-Path $script:project 'verify-exit.txt') -Value '0'
        Set-Content -LiteralPath (Join-Path $script:project '.gitignore') -Value "verify-*.txt"
        Invoke-Git -Arguments @('init', '-q', '-b', 'main')
        Invoke-Git -Arguments @('add', '-A')
        Invoke-Git -Arguments @('commit', '-q', '-m', 'fixture')
        $env:PFC_HOOK_STATE_DIR = Join-Path $script:project '.hook-state'
    }

    AfterEach {
        Remove-Item Env:PFC_HOOK_STATE_DIR -ErrorAction SilentlyContinue
    }

    It 'does nothing when no PowerShell file differs from the base branch' {
        (Invoke-StopHook).ExitCode | Should -Be 0
        Get-VerifyRunCount | Should -Be 0
    }

    It 'ignores changes limited to non-PowerShell files' {
        Set-Content -LiteralPath (Join-Path $script:project 'README.md') -Value 'changed readme'
        (Invoke-StopHook).ExitCode | Should -Be 0
        Get-VerifyRunCount | Should -Be 0
    }

    It 'verifies a changed script once and skips the run until the script changes again' {
        Set-Content -LiteralPath (Join-Path $script:project 'Script.ps1') -Value '$null = 2'
        (Invoke-StopHook).ExitCode | Should -Be 0
        Get-VerifyRunCount | Should -Be 1
        Get-Content -LiteralPath (Join-Path $script:project 'verify-runs.txt') | Should -Be 'SkipAnalysis=True'

        (Invoke-StopHook).ExitCode | Should -Be 0
        Get-VerifyRunCount | Should -Be 1

        Set-Content -LiteralPath (Join-Path $script:project 'Script.ps1') -Value '$null = 3'
        (Invoke-StopHook).ExitCode | Should -Be 0
        Get-VerifyRunCount | Should -Be 2
    }

    It 'verifies new untracked modules and committed changes on a feature branch' {
        Set-Content -LiteralPath (Join-Path $script:project 'New.psm1') -Value '$null = 1'
        (Invoke-StopHook).ExitCode | Should -Be 0
        Get-VerifyRunCount | Should -Be 1

        Remove-Item -LiteralPath (Join-Path $script:project 'New.psm1')
        Invoke-Git -Arguments @('switch', '-q', '-c', 'feature')
        Set-Content -LiteralPath (Join-Path $script:project 'Script.ps1') -Value '$null = 4'
        Invoke-Git -Arguments @('commit', '-q', '-am', 'feature change')
        (Invoke-StopHook).ExitCode | Should -Be 0
        Get-VerifyRunCount | Should -Be 2
    }

    It 'blocks the stop with the failed tests and the step summary, without fixture noise' {
        Set-Content -LiteralPath (Join-Path $script:project 'verify-exit.txt') -Value '1'
        Set-Content -LiteralPath (Join-Path $script:project 'Script.ps1') -Value '$null = 2'
        $result = Invoke-StopHook
        $result.ExitCode | Should -Be 2
        $result.Errors | Should -Match ([regex]::Escape('[-] Demo.fails on purpose'))
        $result.Errors | Should -Match 'Expected 1, but got 2'
        $result.Errors | Should -Match 'FAIL  Pester'
        $result.Errors | Should -Not -Match 'fixture noise'
    }

    It 'lets Claude stop after three blocked stops in a row and tells the user' {
        Set-Content -LiteralPath (Join-Path $script:project 'verify-exit.txt') -Value '1'
        Set-Content -LiteralPath (Join-Path $script:project 'Script.ps1') -Value '$null = 2'
        (Invoke-StopHook -Active $false).ExitCode | Should -Be 2
        (Invoke-StopHook -Active $true).ExitCode | Should -Be 2
        (Invoke-StopHook -Active $true).ExitCode | Should -Be 2

        $released = Invoke-StopHook -Active $true
        $released.ExitCode | Should -Be 0
        ($released.Output | ConvertFrom-Json).systemMessage | Should -Match 'still fails after 3 attempts'

        (Invoke-StopHook -Active $false).ExitCode | Should -Be 2
    }
}
