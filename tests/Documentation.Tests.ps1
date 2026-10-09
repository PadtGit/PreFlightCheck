Describe 'Documentation links' {
    BeforeAll {
        $script:repositoryRoot = Split-Path -Path $PSScriptRoot -Parent

        function Get-TrackedDocument {
            <#
            .SYNOPSIS
                Returns the repository-relative paths of tracked Markdown and MDX files that exist.
            #>
            $paths = @(& git -C $script:repositoryRoot ls-files -- '*.md' '*.mdx')
            if ($LASTEXITCODE -ne 0) {
                throw 'git could not list the tracked documentation files.'
            }
            # ls-files still lists files deleted in the working tree; check only files that exist.
            $paths | Where-Object {
                Test-Path -LiteralPath (Join-Path -Path $script:repositoryRoot -ChildPath $_) -PathType Leaf
            }
        }

        function Get-ProseText {
            <#
            .SYNOPSIS
                Returns Markdown text without fenced code blocks and inline code, where links are literal.
            #>
            param ([string]$Text)
            $withoutFences = [regex]::Replace($Text, '(?ms)^[ \t]*```.*?^[ \t]*```', '')
            [regex]::Replace($withoutFences, '`[^`\r\n]*`', '')
        }

        function Get-HeadingSlug {
            <#
            .SYNOPSIS
                Returns the GitHub-style anchor slug of every heading in a Markdown file.
            #>
            param ([string]$Path)
            $text = [IO.File]::ReadAllText($Path)
            $withoutFences = [regex]::Replace($text, '(?ms)^[ \t]*```.*?^[ \t]*```', '')
            foreach ($match in [regex]::Matches($withoutFences, '(?m)^#{1,6} +(.+?) *#* *\r?$')) {
                $heading = $match.Groups[1].Value.Replace('`', '').Trim().ToLowerInvariant()
                ([regex]::Replace($heading, '[^\w\- ]', '')).Replace(' ', '-')
            }
        }
    }

    It 'finds the tracked documentation files' {
        @(Get-TrackedDocument).Count | Should -BeGreaterThan 0
    }

    It 'resolves every relative link and section anchor in tracked Markdown' {
        $problems = foreach ($document in Get-TrackedDocument) {
            $documentPath = Join-Path -Path $script:repositoryRoot -ChildPath $document
            $documentFolder = Split-Path -Path $documentPath -Parent
            $prose = Get-ProseText -Text ([IO.File]::ReadAllText($documentPath))
            foreach ($link in [regex]::Matches($prose, '\]\((?<target>[^)\s]+)(?:\s+"[^"]*")?\)')) {
                $target = $link.Groups['target'].Value
                # Absolute URLs and other schemes are outside the repository.
                if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
                    continue
                }
                $pathPart, $anchor = $target.Split('#', 2)
                $resolved = $documentPath
                if ($pathPart) {
                    $resolved = Join-Path -Path $documentFolder -ChildPath ([uri]::UnescapeDataString($pathPart))
                }
                if (-not (Test-Path -LiteralPath $resolved)) {
                    '{0}: missing target {1}' -f $document, $target
                    continue
                }
                $isMissingSection = $anchor -and $resolved -match '\.(md|mdx)$' -and
                    $anchor.ToLowerInvariant() -notin @(Get-HeadingSlug -Path $resolved)
                if ($isMissingSection) {
                    '{0}: missing section {1}' -f $document, $target
                }
            }
        }

        $problems | Should -BeNullOrEmpty
    }

    It 'imports only existing files from CLAUDE.md' {
        $claudePath = Join-Path -Path $script:repositoryRoot -ChildPath 'CLAUDE.md'
        $prose = Get-ProseText -Text ([IO.File]::ReadAllText($claudePath))
        $imports = @([regex]::Matches($prose, '(?<![\w`])@(?<path>[\w./-]+)') | ForEach-Object {
                $_.Groups['path'].Value.TrimEnd('.')
            })

        $imports | Should -Contain 'AGENTS.md'
        foreach ($import in $imports) {
            Join-Path -Path $script:repositoryRoot -ChildPath $import | Should -Exist
        }
    }
}

Describe 'Release version references' {
    BeforeAll {
        $repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
        $script:version = ([IO.File]::ReadAllText((Join-Path -Path $repositoryRoot -ChildPath 'VERSION'))).Trim()
        $script:readme = [IO.File]::ReadAllText((Join-Path -Path $repositoryRoot -ChildPath 'README.md'))
        $script:changelog = [IO.File]::ReadAllText((Join-Path -Path $repositoryRoot -ChildPath 'CHANGELOG.md'))
    }

    It 'stores VERSION as major.minor.patch' {
        $script:version | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'names VERSION in the README version line and its release link' {
        $pattern = '(?m)^Version: \[(?<text>[^\]]+)\]\([^)]*/releases/tag/v(?<tag>[^)/]+)\)'
        $versionLine = [regex]::Match($script:readme, $pattern)

        $versionLine.Success | Should -BeTrue -Because 'README.md has a "Version: [X.Y.Z](.../vX.Y.Z)" line'
        $versionLine.Groups['text'].Value | Should -Be $script:version
        $versionLine.Groups['tag'].Value | Should -Be $script:version
    }

    It 'starts the CHANGELOG release history with VERSION' {
        $newestRelease = [regex]::Match($script:changelog, '(?m)^## (?<version>\d+\.\d+\.\d+) - \d{4}-\d{2}-\d{2}\s*$')

        $newestRelease.Success | Should -BeTrue -Because 'CHANGELOG.md has a "## X.Y.Z - YYYY-MM-DD" heading'
        $newestRelease.Groups['version'].Value | Should -Be $script:version
    }
}
