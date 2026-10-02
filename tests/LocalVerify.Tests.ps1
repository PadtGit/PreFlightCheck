Describe 'Local verification script' {
    BeforeAll {
        $script:verifyScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/Invoke-LocalVerify.ps1'

        function Invoke-Git {
            <#
            .SYNOPSIS
                Runs git quietly in the fixture repository.
            #>
            param ([string[]]$Arguments)
            $null = & git -C $script:project -c user.name=Pester -c user.email=pester@example.invalid `
                -c commit.gpgsign=false -c core.autocrlf=false @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
        }
    }

    BeforeEach {
        # A small repository with its own copy of the script, so the Pester step runs one trivial test.
        $script:project = Join-Path $TestDrive ('verify-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -Path (Join-Path $script:project 'tools') -ItemType Directory -Force
        $null = New-Item -Path (Join-Path $script:project 'tests') -ItemType Directory -Force
        Copy-Item -LiteralPath $script:verifyScript -Destination (Join-Path $script:project 'tools/Invoke-LocalVerify.ps1')
        Set-Content -LiteralPath (Join-Path $script:project 'tests/Fixture.Tests.ps1') -Value "Describe 'Fixture' { It 'passes' { 1 | Should -Be 1 } }"
        Set-Content -LiteralPath (Join-Path $script:project 'Kept.ps1') -Value "#Requires -Version 5.1`r`n`$null = 1"
        Set-Content -LiteralPath (Join-Path $script:project 'Removed.ps1') -Value "#Requires -Version 5.1`r`n`$null = 2"
        Invoke-Git -Arguments @('init', '-q', '-b', 'main')
        Invoke-Git -Arguments @('add', '-A')
        Invoke-Git -Arguments @('commit', '-q', '-m', 'fixture')
    }

    It 'skips a tracked PS5.1 file deleted in the working tree and still prints the summary' {
        Remove-Item -LiteralPath (Join-Path $script:project 'Removed.ps1')
        $output = & pwsh -NoLogo -NoProfile -File (Join-Path $script:project 'tools/Invoke-LocalVerify.ps1') -SkipAnalysis 2>&1 |
            Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'PASS  PS5\.1 parse\s+1 file\(s\)'
        $output | Should -Match 'PASS  Pester'
        $output | Should -Match 'SKIP  Full analyzer'
    }

    It 'reports a PS7-only construct in a PS5.1 file as a parse failure' {
        Set-Content -LiteralPath (Join-Path $script:project 'Kept.ps1') -Value "#Requires -Version 5.1`r`n`$null = `$null ?? 1"
        $output = & pwsh -NoLogo -NoProfile -File (Join-Path $script:project 'tools/Invoke-LocalVerify.ps1') -SkipAnalysis 2>&1 |
            Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Kept\.ps1:2:'
        $output | Should -Match 'FAIL  PS5\.1 parse'
        $output | Should -Match 'PASS  Pester'
    }
}
