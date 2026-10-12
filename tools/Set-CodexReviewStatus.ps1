<#
.SYNOPSIS
Sets the "Codex review" commit status on a pull request's head commit.

.DESCRIPTION
Reads the pull request and the Codex connector's review summary comment with the GitHub CLI, then posts a
commit status. The status is success only when the summary shows a completed Code Review of the current head
commit; anything else (draft, no review yet, review in progress, review of an older commit) is pending, which
blocks a merge when the status is required. Codex findings are review threads; branch protection's required
conversation resolution blocks them separately. Runs in GitHub Actions with GH_TOKEN set.

.PARAMETER Repository
The repository as owner/name.

.PARAMETER PullRequest
The pull request number.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$PullRequest
)

$ErrorActionPreference = 'Stop'

function Get-CodexReviewState
{
    <#
    .SYNOPSIS
    Decides the commit status from the head commit, the draft flag, and the Codex summary comment body.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$HeadSha,

        [bool]$IsDraft,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$SummaryBody
    )

    $headShort = $HeadSha.Substring(0, 7)
    if ($IsDraft)
    {
        return [pscustomobject]@{ State = 'pending'; Description = 'Draft: mark it ready for review so Codex reviews it.' }
    }
    if ([string]::IsNullOrWhiteSpace($SummaryBody))
    {
        return [pscustomobject]@{ State = 'pending'; Description = "Waiting for Codex to review $headShort." }
    }

    # Summary table row: | <icon> **Code Review** | <icon> **Completed** <time> | `abc1234` | <trigger> |
    $row = [regex]::Match($SummaryBody,
        '(?m)^\|[^|\r\n]*\*\*Code Review\*\*[^|\r\n]*\|(?<status>[^|\r\n]*)\|\s*`(?<commit>[0-9a-f]{7,40})`\s*\|')
    if (-not $row.Success)
    {
        return [pscustomobject]@{ State = 'pending'; Description = "Waiting for Codex to review $headShort." }
    }
    $reviewedCommit = $row.Groups['commit'].Value
    if (-not $HeadSha.StartsWith($reviewedCommit, [StringComparison]::Ordinal))
    {
        $reviewedShort = $reviewedCommit.Substring(0, 7)
        return [pscustomobject]@{
            State       = 'pending'
            Description = "Codex reviewed $reviewedShort, not $headShort. Comment '@codex review'."
        }
    }
    if ($row.Groups['status'].Value -notmatch '\*\*Completed\*\*')
    {
        return [pscustomobject]@{ State = 'pending'; Description = "Codex review of $headShort is not complete." }
    }
    [pscustomobject]@{ State = 'success'; Description = "Codex reviewed $headShort." }
}

$pullRequestJson = & gh api "repos/$Repository/pulls/$PullRequest"
if ($LASTEXITCODE -ne 0) { throw "Cannot read pull request $PullRequest." }
$pullRequestData = $pullRequestJson | ConvertFrom-Json

# One compact JSON object per line keeps multi-line comment bodies intact across pages.
$commentLines = @(& gh api --paginate "repos/$Repository/issues/$PullRequest/comments" --jq `
        '.[] | select(.user.login == "chatgpt-codex-connector[bot]") | {body, updated_at} | tojson')
if ($LASTEXITCODE -ne 0) { throw "Cannot read comments on pull request $PullRequest." }
$summary = $commentLines |
    Where-Object { $_ } |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.body -match '<!-- codex-pull-request-review-summary -->' } |
    Sort-Object -Property { [datetime]$_.updated_at } |
    Select-Object -Last 1

$summaryBody = $null
if ($summary) { $summaryBody = $summary.body }
$result = Get-CodexReviewState -HeadSha $pullRequestData.head.sha -IsDraft ([bool]$pullRequestData.draft) -SummaryBody $summaryBody

$null = & gh api --method POST "repos/$Repository/statuses/$($pullRequestData.head.sha)" `
    -f "state=$($result.State)" -f 'context=Codex review' -f "description=$($result.Description)" `
    -f "target_url=$($pullRequestData.html_url)"
if ($LASTEXITCODE -ne 0) { throw "Cannot set the Codex review status on $($pullRequestData.head.sha)." }
Write-Information -MessageData "Codex review: $($result.State) - $($result.Description)" -InformationAction Continue
