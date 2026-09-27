Describe 'Agent skill copies' {
    BeforeAll {
        $repositoryRoot = Split-Path $PSScriptRoot -Parent
        $script:claudeSkills = Join-Path $repositoryRoot '.claude/skills'
        $script:codexSkills = Join-Path $repositoryRoot '.agents/skills'

        function Get-SkillInventory {
            <#
            .SYNOPSIS
                Returns "relative/path|content" lines for every file under a skills root, with
                line endings normalized so CRLF checkouts compare equal.
            #>
            param ([string]$Root)
            Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object -Property FullName | ForEach-Object {
                $relativePath = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
                $content = [IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n")
                '{0}|{1}' -f $relativePath, $content
            }
        }
    }

    It 'keeps the Codex copy (.agents/skills) identical to the Claude Code copy (.claude/skills)' {
        $claudeInventory = @(Get-SkillInventory -Root $script:claudeSkills)
        $codexInventory = @(Get-SkillInventory -Root $script:codexSkills)

        $claudeInventory.Count | Should -BeGreaterThan 0
        Compare-Object -ReferenceObject $claudeInventory -DifferenceObject $codexInventory |
            ForEach-Object { $_.InputObject.Split('|')[0] + ' ' + $_.SideIndicator } |
            Should -BeNullOrEmpty
    }

    It 'gives every skill a SKILL.md whose name matches its folder' {
        foreach ($skill in Get-ChildItem -LiteralPath $script:claudeSkills -Directory) {
            $skillFile = Join-Path $skill.FullName 'SKILL.md'
            $skillFile | Should -Exist
            (Get-Content -LiteralPath $skillFile -TotalCount 5) -join "`n" |
                Should -Match ("(?m)^name: {0}$" -f [regex]::Escape($skill.Name))
        }
    }
}
