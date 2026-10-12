[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester resolves variables assigned in BeforeAll inside later It blocks; static analysis does not follow that framework scope.')]
param()

Describe 'Codex review gate' {
    BeforeAll {
        $repositoryRoot = Split-Path $PSScriptRoot -Parent
        $gateScript = Join-Path $repositoryRoot 'tools/Set-CodexReviewStatus.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($gateScript, [ref]$null, [ref]$null)
        $functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CodexReviewState' }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text))
        $workflowText = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/codex-review.yml') -Raw

        $headSha = 'b2eccb3a1c0de5f00d1e2b3c4d5e6f708192a3b4'
        $memo = [char]::ConvertFromUtf32(0x1F4DD)
        $check = [char]::ConvertFromUtf32(0x2705)

        function Get-SummaryBody {
            <#
            .SYNOPSIS
                Builds a Codex summary comment in the connector's format.
            #>
            param ([string]$Status, [string]$Commit)
            @(
                '<!-- codex-pull-request-review-summary -->'
                ''
                '## Codex Review Summary'
                ''
                '| Review | Status | Commit | Review trigger |'
                '| --- | --- | --- | --- |'
                "| $memo **Code Review** | $Status <relative-time datetime=`"2026-10-12T05:10:40Z`">2026-10-12T05:10:40Z</relative-time> | ``$Commit`` | PR opened |"
            ) -join "`n"
        }
    }

    It 'passes a completed Code Review of the head commit' {
        $result = Get-CodexReviewState -HeadSha $headSha -IsDraft $false -SummaryBody (Get-SummaryBody -Status "$check **Completed**" -Commit 'b2eccb3')

        $result.State | Should -Be 'success'
        $result.Description | Should -Be 'Codex reviewed b2eccb3.'
    }

    It 'stays pending when Codex reviewed an older commit' {
        $result = Get-CodexReviewState -HeadSha $headSha -IsDraft $false -SummaryBody (Get-SummaryBody -Status "$check **Completed**" -Commit 'dd409cc')

        $result.State | Should -Be 'pending'
        $result.Description | Should -Match "Codex reviewed dd409cc, not b2eccb3\. Comment '@codex review'\."
    }

    It 'stays pending while the review of the head commit is not complete' {
        $result = Get-CodexReviewState -HeadSha $headSha -IsDraft $false -SummaryBody (Get-SummaryBody -Status '**In progress**' -Commit 'b2eccb3')

        $result.State | Should -Be 'pending'
    }

    It 'stays pending without a summary, with an unreadable summary, or for a draft' {
        (Get-CodexReviewState -HeadSha $headSha -IsDraft $false -SummaryBody $null).State | Should -Be 'pending'
        (Get-CodexReviewState -HeadSha $headSha -IsDraft $false -SummaryBody 'Codex Review Summary').State | Should -Be 'pending'
        (Get-CodexReviewState -HeadSha $headSha -IsDraft $true -SummaryBody (Get-SummaryBody -Status "$check **Completed**" -Commit 'b2eccb3')).State |
            Should -Be 'pending'
    }

    It 'does not count a Security Review row as the Code Review' {
        $body = (Get-SummaryBody -Status "$check **Completed**" -Commit 'dd409cc') +
            "`n| $memo **Security Review** | $check **Completed** | ``b2eccb3`` | Comment |"

        (Get-CodexReviewState -HeadSha $headSha -IsDraft $false -SummaryBody $body).State | Should -Be 'pending'
    }

    It 'runs only base-branch code with a pinned checkout' {
        $workflowText | Should -Match '(?m)^  pull_request_target:'
        $workflowText | Should -Not -Match '(?m)^  pull_request:'
        $workflowText | Should -Not -Match 'github\.event\.pull_request\.head'
        $workflowText | Should -Match 'actions/checkout@[0-9a-f]{40} '
        $workflowText | Should -Match 'persist-credentials: false'
        $workflowText | Should -Match "github\.event\.comment\.user\.login == 'chatgpt-codex-connector\[bot\]'"
    }
}
