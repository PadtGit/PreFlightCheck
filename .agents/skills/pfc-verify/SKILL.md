---
name: pfc-verify
description: Use before finishing a PreFlightCheck change, before opening or updating a PR, or when Bob asks to verify, run the tests, or run CI locally. Runs the same checks as the verify workflow (Windows PowerShell 5.1 parse, pinned Pester, full PSScriptAnalyzer) and reports one pass/fail line per step.
---

# PreFlightCheck local verification

`tools/Invoke-LocalVerify.ps1` runs the steps of `.github/workflows/verify.yml` in CI order and
ends with a summary. Run it from the repository root in PowerShell 7:

```powershell
pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1
```

| Step | What it checks | Typical time |
|---|---|---|
| PS5.1 parse | Every tracked or new file marked `#Requires -Version 5.1`, parsed by Windows PowerShell | seconds |
| Pester | `./tests` with Pester 6.2.0 and the CI configuration | about 1.5 minutes |
| Full analyzer | `tools/Invoke-FullScriptAnalysis.ps1` with PSScriptAnalyzer 1.25.0, up to 3 attempts | several minutes |

Every step runs even after an earlier one fails. Exit code `0` means no step failed; `1` means at least one did.

## When to run what

- **Before a PR or after a release bump:** the full run above.
- **While iterating:** add `-SkipAnalysis` to skip the analyzer. The edit hook already analyzes each
  edited file, apart from the compatibility-profile rules that only the full run enforces.
- **One failing test:** `Invoke-Pester -Path ./tests/<File>.Tests.ps1 -Output Detailed -FullNameFilter '*name*'`.

The Claude Code Stop hook (`.claude/hooks/Invoke-StopVerification.ps1`) runs the `-SkipAnalysis` form
automatically when PowerShell files or skills changed. It does not replace the full run before a PR.

## Reading failures

- **PS5.1 parse:** lines are `path:line: message`. The usual cause is PS7-only syntax (`??`, `?:`, `??=`,
  `?.`) in a 5.1 file. Rewrite it with `if`/`else`; a version guard does not help because the parse fails first.
- **Pester:** failed tests start with `[-]`. Fixture output such as `[Review] CHKDSK-C: ...` is expected
  and does not mean a failure. Tests mock all maintenance actions; never "fix" a test by running real cleanup.
- **Full analyzer:** see `ValidationReport/release-blocking.csv` and `ValidationReport/analyzer-errors.txt`.
  Engine errors are intermittent, and the script already retries them. Only a finding listed in
  `release-blocking.csv` is real.

`ValidationReport/` is generated and gitignored. Never commit it.

## Reporting

Quote the summary block (the `PASS`/`FAIL`/`SKIP` lines) to Bob, plus the failing test names or
analyzer findings. Do not report "verified" or open a PR when any step shows `FAIL`, or after a
`-SkipAnalysis` run.
