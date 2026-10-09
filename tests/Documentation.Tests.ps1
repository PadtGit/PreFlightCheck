Describe 'Documentation links' {
    BeforeAll {
        $script:repositoryRoot = Split-Path -Path $PSScriptRoot -Parent

        function Get-GitFile {
            <#
            .SYNOPSIS
                Runs git ls-files with the given arguments and returns the listed files that exist, in Git's casing.
            #>
            param ([string[]]$Argument)
            $paths = @(& git -C $script:repositoryRoot -c core.quotePath=false ls-files $Argument)
            if ($LASTEXITCODE -ne 0) {
                throw "git ls-files $($Argument -join ' ') failed with exit code $LASTEXITCODE."
            }
            # ls-files still lists files deleted in the working tree; keep only files that exist.
            $paths | Where-Object {
                Test-Path -LiteralPath (Join-Path -Path $script:repositoryRoot -ChildPath $_) -PathType Leaf
            }
        }

        function Get-UnfencedText {
            <#
            .SYNOPSIS
                Returns the text without backtick and tilde fenced code blocks, where link syntax is literal.
            #>
            param ([string]$Text)
            $fence = '(?ms)^[ \t]*(?<fence>(?<mark>[`~])\k<mark>{2,}).*?^[ \t]*\k<fence>\k<mark>*[ \t]*\r?$'
            [regex]::Replace($Text, $fence, '')
        }

        function Get-LinkTarget {
            <#
            .SYNOPSIS
                Returns inline link destinations and reference-style link definitions outside code.
            #>
            param ([string]$Text)
            $prose = [regex]::Replace((Get-UnfencedText -Text $Text), '`[^`\r\n]*`', '')
            foreach ($match in [regex]::Matches($prose, '\]\((?<target>[^)\s]+)(?:\s+"[^"]*")?\)')) {
                $match.Groups['target'].Value
            }
            # Reference definitions such as "[docs]: path.md"; "[^1]:" is a footnote, not a link.
            foreach ($match in [regex]::Matches($prose, '(?m)^ {0,3}\[(?!\^)[^\]]+\]:[ \t]*<?(?<target>[^\s>]+)')) {
                $match.Groups['target'].Value
            }
        }

        function Resolve-RepositoryPath {
            <#
            .SYNOPSIS
                Returns a link target as a repository-relative '/' path that keeps the link's casing.
            #>
            param ([string]$Document, [string]$Target)
            # GitHub resolves '/path' from the repository root and other paths from the document's folder.
            $base = if ($Target.StartsWith('/')) { '' } else { Split-Path -Path $Document -Parent }
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($part in (($base -replace '\\', '/') + '/' + $Target).Split('/')) {
                if ($part -eq '..') {
                    if ($parts.Count -eq 0) {
                        return '../'
                    }
                    $parts.RemoveAt($parts.Count - 1)
                }
                elseif ($part -and $part -ne '.') {
                    $parts.Add($part)
                }
            }
            $parts -join '/'
        }

        function Get-HeadingSlug {
            <#
            .SYNOPSIS
                Returns the GitHub-style anchor slug of every heading in a Markdown file.
            #>
            param ([string]$Path)
            $text = Get-UnfencedText -Text ([IO.File]::ReadAllText($Path))
            $count = @{}
            foreach ($match in [regex]::Matches($text, '(?m)^ {0,3}#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*\r?$')) {
                $heading = $match.Groups[1].Value.Replace('`', '').Trim().ToLowerInvariant()
                $slug = ([regex]::Replace($heading, '[^\w\- ]', '')).Replace(' ', '-')
                # GitHub numbers repeated headings: setup, setup-1, setup-2.
                if ($count.ContainsKey($slug)) {
                    $count[$slug]++
                    '{0}-{1}' -f $slug, $count[$slug]
                }
                else {
                    $count[$slug] = 0
                    $slug
                }
            }
        }

        $script:documents = @(Get-GitFile -Argument '--cached', '--', '*.md', '*.mdx')
        # Tracked and new unignored files and their folders, compared with exact case as GitHub does.
        $script:linkTargets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $null = $script:linkTargets.Add('')
        foreach ($file in Get-GitFile -Argument '--cached', '--others', '--exclude-standard') {
            for ($path = $file; $path; $path = $path -replace '/?[^/]*$', '') {
                $null = $script:linkTargets.Add($path)
            }
        }
    }

    It 'finds the tracked documentation files' {
        $script:documents.Count | Should -BeGreaterThan 0
    }

    It 'resolves every relative link and section anchor in tracked Markdown' {
        $problems = foreach ($document in $script:documents) {
            $text = [IO.File]::ReadAllText((Join-Path -Path $script:repositoryRoot -ChildPath $document))
            foreach ($target in Get-LinkTarget -Text $text) {
                # Absolute URLs and other schemes are outside the repository.
                if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
                    continue
                }
                $pathPart, $anchor = $target.Split('#', 2)
                $relative = $document
                if ($pathPart) {
                    $linkPath = [uri]::UnescapeDataString($pathPart)
                    $relative = Resolve-RepositoryPath -Document $document -Target $linkPath
                }
                if (-not $script:linkTargets.Contains($relative.TrimEnd('/'))) {
                    '{0}: missing target {1} (paths are case-sensitive)' -f $document, $target
                    continue
                }
                $isMissingSection = $anchor -and $relative -match '\.(md|mdx)$' -and
                    [uri]::UnescapeDataString($anchor).ToLowerInvariant() -notin
                    @(Get-HeadingSlug -Path (Join-Path -Path $script:repositoryRoot -ChildPath $relative))
                if ($isMissingSection) {
                    '{0}: missing section {1}' -f $document, $target
                }
            }
        }

        $problems | Should -BeNullOrEmpty
    }

    It 'imports AGENTS.md and .claude/CLAUDE.md, and only existing files, from CLAUDE.md' {
        $text = [IO.File]::ReadAllText((Join-Path -Path $script:repositoryRoot -ChildPath 'CLAUDE.md'))
        $prose = [regex]::Replace((Get-UnfencedText -Text $text), '`[^`\r\n]*`', '')
        $imports = @([regex]::Matches($prose, '(?<![\w`])@(?<path>[\w./-]+)') | ForEach-Object {
                $_.Groups['path'].Value.TrimEnd('.')
            })

        $imports | Should -Contain 'AGENTS.md'
        $imports | Should -Contain '.claude/CLAUDE.md'
        $missing = $imports | Where-Object { -not $script:linkTargets.Contains($_) }
        $missing | Should -BeNullOrEmpty -Because 'CLAUDE.md imports must name existing files with exact case'
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
