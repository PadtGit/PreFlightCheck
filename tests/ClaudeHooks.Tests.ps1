Describe 'Claude Code edit-check hook' {
    BeforeAll {
        $repositoryRoot = Split-Path $PSScriptRoot -Parent
        $script:hookPath = Join-Path $repositoryRoot '.claude/hooks/Test-EditedScript.ps1'

        function Invoke-EditHook {
            <#
            .SYNOPSIS
                Runs the hook with a PostToolUse payload for FilePath and returns its exit code and stderr.
            #>
            param ([string]$FilePath)
            $payload = @{ tool_name = 'Edit'; tool_input = @{ file_path = $FilePath } } | ConvertTo-Json -Compress
            $errorFile = Join-Path $TestDrive 'hook-stderr.txt'
            $env:CLAUDE_PROJECT_DIR = $TestDrive
            try {
                $payload | & pwsh -NoLogo -NoProfile -File $script:hookPath 2> $errorFile | Out-Null
                [pscustomobject]@{ ExitCode = $LASTEXITCODE; Errors = (Get-Content -LiteralPath $errorFile -Raw) }
            } finally {
                Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
            }
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
