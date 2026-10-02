# Contributing to PreFlightCheck

PreFlightCheck is a Windows 11 pre-backup maintenance tool. Keep changes focused and preserve its operator confirmation, preview, reporting, and cleanup safety gates.

## Test locally

Use PowerShell 7 on Windows. Install the versions used by CI, then run the full suite from the repository root:

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1
```

[tools/Invoke-LocalVerify.ps1](tools/Invoke-LocalVerify.ps1) runs the same steps as CI: a Windows PowerShell 5.1 parse of every file marked `#Requires -Version 5.1`, the Pester suite, and the full analyzer (`tools/Invoke-FullScriptAnalysis.ps1`, retried up to three times). It prints one PASS/FAIL line per step and exits 0 only when all of them passed. `-SkipAnalysis` leaves out the slow analyzer step for quick iterations.

The dashboard runs under PowerShell 7; maintenance scripts and shared maintenance code must also parse under Windows PowerShell 5.1. Test system-changing paths with mocks or `-WhatIf`; do not run actual repairs, updates, or cleanup as a test.

## Working with AI agents

Read [AGENTS.md](AGENTS.md) for the runtime and safety rules. Codex uses the repository skills in [.agents/skills](.agents/skills/); Claude Code uses [.claude/skills](.claude/skills/). Edit the Claude Code copy first, then sync it with `Copy-Item .claude/skills/* .agents/skills/ -Recurse -Force`. [tests/AgentSkills.Tests.ps1](tests/AgentSkills.Tests.ps1) checks that the copies match. Claude Code runs the hooks in [.claude/hooks](.claude/hooks/):

- [Block-LiveMaintenance.ps1](.claude/hooks/Block-LiveMaintenance.ps1) blocks live maintenance commands without `-WhatIf` (details below).
- [Test-EditedScript.ps1](.claude/hooks/Test-EditedScript.ps1) parses and analyzes each edited PowerShell file.
- [Sync-AgentSkill.ps1](.claude/hooks/Sync-AgentSkill.ps1) copies skill edits from `.claude/skills` to `.agents/skills` and refuses direct edits to the Codex copy. Deleting or renaming a skill file is not mirrored.
- [Invoke-StopVerification.ps1](.claude/hooks/Invoke-StopVerification.ps1) runs `tools/Invoke-LocalVerify.ps1 -SkipAnalysis` before Claude finishes a turn in which PowerShell files or skills differ from `main`, and sends failures back to Claude. It remembers a passing state until those files change, and after three blocked stops in a row it lets Claude stop with a warning. Its state files live in `%TEMP%\PreFlightCheck-ClaudeHooks` (override with `PFC_HOOK_STATE_DIR`).

The live-maintenance hook checks each invocation separately. Static previews of `PreBackupMaintenance.ps1`, `Update-Applications.ps1`, and `Weekly-DellReview.ps1` require their own enabled `-WhatIf`. Use a bare switch for native `-File` previews from Bash. Dashboard, GUI worker, and guided-run entry points have no preview switch and are blocked. Dynamic calls, argument splats, encoded commands, stdin execution, and unsupported shell wrappers are also blocked. Commands combining maintenance references with method calls fail closed; use direct commands, quoted literal PowerShell `-Command` bodies, or Pester mocks. This is an invocation guard, not a sandbox for arbitrary helper scripts or shell configuration.

## Pull requests

Describe the behavior changed, the tests run, and any result or exit-code impact. Keep `report.json`, `steps.csv`, `session.log`, guided-run order, and the cleanup health gate compatible. Generated reports and local machine details should not be committed.
