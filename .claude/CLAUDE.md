## Environment

- Local Windows 11; PowerShell 7.6 for the dashboard, Windows PowerShell 5.1 for maintenance scripts (see AGENTS.md runtime map).
- No virtual environment.

## Testing

- Full CI-equivalent check: `pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1` (the `pfc-verify` skill); `-SkipAnalysis` for Pester + PS5.1 parse only.
- The Stop hook runs that `-SkipAnalysis` form automatically (~1.5 min) when `.ps1`/`.psm1`/`.psd1` files, `.claude/settings.json`, or skills differ from the base branch (`origin/main`, else `main`).
- Single file: `Import-Module -Name Pester -RequiredVersion 6.2.0 -Force`, then `Invoke-Pester -Path ./tests/Correctness.Tests.ps1 -Output Detailed`. Importing first keeps Windows' inbox Pester 3.4 from loading.
- Single test: add `-FullNameFilter '*part of test name*'`.
- Tests mock all maintenance actions; never run real cleanup/updates to test.

## Gotchas

- PSScriptAnalyzer engine errors are intermittent (CI retries 3x, the edit hook 2x); rerun before treating one as a real finding.
- Personal permission overrides go in `.claude/settings.local.json` (gitignored), not `settings.json`.
