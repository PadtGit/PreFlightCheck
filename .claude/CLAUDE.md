## Environment

- Local Windows 11; PowerShell 7.6 for the dashboard, Windows PowerShell 5.1 for maintenance scripts (see AGENTS.md runtime map).
- No virtual environment. Required modules: Pester 6.2.0, PSScriptAnalyzer 1.25.0.
- PS5.1 files must also parse under `powershell.exe`; CI does this in `.github/workflows/verify.yml`.

## Testing

- Full suite: run the `New-PesterConfiguration` block in AGENTS.md from the repo root in `pwsh`.
- Single file: `Invoke-Pester -Path ./tests/Correctness.Tests.ps1 -Output Detailed`.
- Single test: add `-FullNameFilter '*part of test name*'`.
- Tests mock all maintenance actions; never run real cleanup/updates to test.
