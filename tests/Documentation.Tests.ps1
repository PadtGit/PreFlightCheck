#Requires -Version 7.0

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
                Returns parsed inline and reference link destinations, excluding code and footnotes.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '',
                Justification = 'Tests run only in PowerShell 7, where ConvertFrom-Markdown loads the bundled Markdig types before use; the 5.1 profile is not a test host.')]
            param ([string]$Text)
            # PowerShell's built-in parser distinguishes code from prose and handles <paths with spaces>.
            $markdown = ConvertFrom-Markdown -InputObject $Text -ErrorAction Stop
            foreach ($node in [Markdig.Syntax.MarkdownObjectExtensions]::Descendants($markdown.Tokens)) {
                $isLink = $node -is [Markdig.Syntax.Inlines.LinkInline]
                $isDefinition = $node -is [Markdig.Syntax.LinkReferenceDefinition] -and $node.Label -notlike '^*'
                if (($isLink -or $isDefinition) -and $node.Url) {
                    $node.Url
                }
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
                Returns unique GitHub-style anchor slugs derived from rendered heading text.
            #>
            param ([string]$Path)
            $html = (ConvertFrom-Markdown -LiteralPath $Path -ErrorAction Stop).Html
            $usedSlugs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $pattern = '(?s)<h(?<level>[1-6])(?:\s[^>]*)?>(?<heading>.*?)</h\k<level>>'
            foreach ($match in [regex]::Matches($html, $pattern)) {
                $visibleText = [regex]::Replace($match.Groups['heading'].Value, '<[^>]*>', '')
                $heading = [Net.WebUtility]::HtmlDecode($visibleText).Trim().ToLowerInvariant()
                $slug = ([regex]::Replace($heading, '[^\w\- ]', '')).Replace(' ', '-')
                $uniqueSlug = $slug
                $suffix = 0
                # Reserve every emitted slug, including literal headings such as "foo-1".
                while (-not $usedSlugs.Add($uniqueSlug)) {
                    $suffix++
                    $uniqueSlug = '{0}-{1}' -f $slug, $suffix
                }
                $uniqueSlug
            }
        }

        # Filter here, not with a git pathspec: pwsh on Linux and macOS expands '*.md' before git sees it.
        $script:documents = @(Get-GitFile -Argument '--cached' | Where-Object { $_ -match '\.(md|mdx)$' })
        # Tracked and new unignored files and their folders, compared with exact case as GitHub does.
        $script:linkTargets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $null = $script:linkTargets.Add('')
        foreach ($file in Get-GitFile -Argument '--cached', '--others', '--exclude-standard') {
            for ($path = $file; $path; $path = $path -replace '/?[^/]*$', '') {
                $null = $script:linkTargets.Add($path)
            }
        }
    }

    It 'finds the tracked documentation files, including those in subfolders' {
        $script:documents.Count | Should -BeGreaterThan 0
        @($script:documents | Where-Object { $_ -like '*/*' }).Count | Should -BeGreaterThan 0
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
                $pathPart = $pathPart.Split('?', 2)[0]
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
        $html = (ConvertFrom-Markdown -InputObject $script:changelog -ErrorAction Stop).Html
        $headings = @([regex]::Matches($html, '(?s)<h2(?:\s[^>]*)?>(?<heading>.*?)</h2>'))
        $headings.Count | Should -BeGreaterThan 1 -Because 'CHANGELOG.md starts with Unreleased and a release'
        $headings[0].Groups['heading'].Value.Trim() | Should -BeExactly 'Unreleased'
        # Select the first release before validating it; never skip a malformed newer entry.
        $newestRelease = [regex]::Match($headings[1].Groups['heading'].Value.Trim(),
            '^(?<version>\d+\.\d+\.\d+) - \d{4}-\d{2}-\d{2}$')

        $newestRelease.Success | Should -BeTrue -Because 'the first release heading is "## X.Y.Z - YYYY-MM-DD"'
        $newestRelease.Groups['version'].Value | Should -Be $script:version
    }
}
