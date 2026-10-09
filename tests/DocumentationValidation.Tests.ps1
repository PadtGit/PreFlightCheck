BeforeDiscovery {
    # Each case writes docs/check.md (Text), a first CHANGELOG release (Release), or the CLAUDE.md imports
    # (Imports) into an isolated Git fixture, and states how many Documentation.Tests.ps1 tests must fail.
    $script:fixtureCases = @(
        @{ Name = 'accepts anchors derived from visible heading text'; Text = '## [Setup](../README.md)' + "`n[section](#setup)"; Failures = 0 }
        @{ Name = 'accepts spaces in inline angle-bracket destinations'; Text = '[guide](<User Guide.md>)'; Failures = 0 }
        @{ Name = 'rejects missing inline angle-bracket destinations'; Text = '[guide](<Missing Guide.md>)'; Failures = 1 }
        @{ Name = 'accepts spaces in reference angle-bracket destinations'; Text = "[guide][docs]`n`n[docs]: <User Guide.md>"; Failures = 0 }
        @{ Name = 'reserves literal slugs before numbering duplicates'; Text = "## foo`n## foo-1`n## foo`n[section](#foo-2)"; Failures = 0 }
        @{ Name = 'ignores links in indented code'; Text = "    [example](missing.md)`n`n[real](../README.md)"; Failures = 0 }
        @{ Name = 'still checks indented continuation links in a list'; Text = "- Item`n`n    [example](missing.md)"; Failures = 1 }
        @{ Name = 'strips queries while retaining fragments'; Text = '[plain](../README.md?plain=1#intro)'; Failures = 0 }
        @{ Name = 'still rejects missing fragments after queries'; Text = '[plain](../README.md?plain=1#missing)'; Failures = 1 }
        @{ Name = 'ignores a fenced example before the actual first release'; Release = '```markdown' + "`n## v0.4.4 - 2026-10-09`n" + '```'; Failures = 0 }
        @{ Name = 'does not skip a malformed first release heading'; Release = '## v0.4.4 - 2026-10-09'; Failures = 1 }
        @{ Name = 'does not skip a first release heading with an invalid date format'; Release = '## 0.4.4 - tomorrow'; Failures = 1 }
        @{ Name = 'rejects a mismatched first release version'; Release = '## 0.4.4 - 2026-10-09'; Failures = 1 }
        @{ Name = 'accepts a matching first release'; Failures = 0 }
        @{ Name = 'rejects missing reference-style targets'; Text = "[guide][docs]`n`n[docs]: missing.md"; Failures = 1 }
        @{ Name = 'ignores footnote text as a target'; Text = "Text[^1]`n`n[^1]: missing.md"; Failures = 0 }
        @{ Name = 'accepts simple repeated heading suffixes'; Text = "## Setup`n## Setup`n[section](#setup-1)"; Failures = 0 }
        @{ Name = 'ignores tilde and backtick fenced links'; Text = "~~~`n[example](missing.md)`n~~~`n`n" + '````' + "`n[example](missing.md)`n" + '````'; Failures = 0 }
        @{ Name = 'resolves slash-prefixed links from the repository root'; Text = '[guide](/README.md)'; Failures = 0 }
        @{ Name = 'rejects wrong-case paths on Windows'; Text = '[guide](/readme.md)'; Failures = 1 }
        @{ Name = 'requires the nested Claude import'; Imports = '@AGENTS.md'; Failures = 1 }
    )
}

Describe 'Documentation validation fixtures' -ForEach @(@{ FixtureCases = $script:fixtureCases }) {
    BeforeAll {
        # Run the real checks against isolated Git fixtures; never mutate repository documents.
        $documentationTests = Join-Path (Split-Path $PSScriptRoot -Parent) 'tests/Documentation.Tests.ps1'
        $fixtures = foreach ($case in $FixtureCases) {
            $project = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach ($folder in @('tests', 'docs', '.claude')) {
                $null = New-Item -Path (Join-Path $project $folder) -ItemType Directory -Force
            }
            Copy-Item -LiteralPath $documentationTests -Destination (Join-Path $project 'tests/Documentation.Tests.ps1')
            Set-Content -LiteralPath (Join-Path $project 'VERSION') -Value '0.4.3' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $project 'README.md') -Encoding utf8 -Value @'
# Intro

Version: [0.4.3](https://example.invalid/releases/tag/v0.4.3)
'@
            $changelog = "# Changelog`n`n## Unreleased`n`n"
            if ($case.Release) { $changelog += "$($case.Release)`n`n" }
            $changelog += "## 0.4.3 - 2026-10-03`n"
            Set-Content -LiteralPath (Join-Path $project 'CHANGELOG.md') -Value $changelog -Encoding utf8
            $claudeImports = if ($case.Imports) { $case.Imports } else { "@AGENTS.md`n@.claude/CLAUDE.md" }
            Set-Content -LiteralPath (Join-Path $project 'CLAUDE.md') -Value $claudeImports -Encoding utf8
            Set-Content -LiteralPath (Join-Path $project 'AGENTS.md') -Value '# Agent instructions' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $project '.claude/CLAUDE.md') -Value '# Local instructions' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $project 'docs/User Guide.md') -Value '# Guide' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $project 'docs/check.md') -Value $case.Text -Encoding utf8
            $null = & git -C $project init -q
            if ($LASTEXITCODE -ne 0) { throw 'Fixture git init failed.' }
            $null = & git -C $project -c core.autocrlf=false add --all
            if ($LASTEXITCODE -ne 0) { throw 'Fixture git add failed.' }
            [pscustomobject]@{ Name = $case.Name; Project = $project }
        }

        # One child process runs every fixture: Pester cannot nest runs, and a process per case is slow.
        $fixtureList = Join-Path $TestDrive 'fixtures.json'
        $resultPath = Join-Path $TestDrive 'results.json'
        $runner = Join-Path $TestDrive 'Invoke-DocumentationFixture.ps1'
        ConvertTo-Json -InputObject @($fixtures) | Set-Content -LiteralPath $fixtureList -Encoding utf8
        @'
param ([string]$FixtureList, [string]$ResultPath)
$ErrorActionPreference = 'Stop'
Import-Module -Name Pester -RequiredVersion 6.2.0 -Force
$results = foreach ($fixture in (Get-Content -LiteralPath $FixtureList -Raw | ConvertFrom-Json)) {
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $fixture.Project 'tests/Documentation.Tests.ps1'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'None'
    $configuration.TestRegistry.Enabled = $false
    $result = Invoke-Pester -Configuration $configuration
    [pscustomobject]@{
        Name = $fixture.Name
        Total = $result.TotalCount
        Failed = $result.FailedCount
        FailedNames = @($result.Tests | Where-Object Result -eq Failed | ForEach-Object Name)
    }
}
ConvertTo-Json -InputObject @($results) -Depth 3 | Set-Content -LiteralPath $ResultPath -Encoding utf8
'@ | Set-Content -LiteralPath $runner -Encoding utf8
        $script:runnerOutput = & pwsh -NoProfile -File $runner -FixtureList $fixtureList -ResultPath $resultPath 2>&1 |
            Out-String
        $script:runnerExitCode = $LASTEXITCODE
        $script:fixtureResults = @{}
        if (Test-Path -LiteralPath $resultPath) {
            foreach ($result in (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)) {
                $script:fixtureResults[$result.Name] = $result
            }
        }
    }

    It '<Name>' -ForEach $FixtureCases {
        $script:runnerExitCode | Should -Be 0 -Because $script:runnerOutput
        $result = $script:fixtureResults[$Name]
        $result | Should -Not -BeNullOrEmpty -Because $script:runnerOutput
        $result.Total | Should -Be 6
        $result.Failed | Should -Be $Failures -Because ($result.FailedNames -join ', ')
        if ($Failures -gt 0) {
            $expectedTest = if ($Release) { 'starts the CHANGELOG release history with VERSION' }
            elseif ($Imports) { 'imports AGENTS.md and .claude/CLAUDE.md, and only existing files, from CLAUDE.md' }
            else { 'resolves every relative link and section anchor in tracked Markdown' }
            $result.FailedNames | Should -Contain $expectedTest
        }
    }
}
