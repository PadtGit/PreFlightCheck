# Contributing to PreFlightCheck

PreFlightCheck is a Windows 11 pre-backup maintenance tool. Keep changes focused and preserve its operator confirmation, preview, reporting, and cleanup safety gates.

Read [SPEC.md](SPEC.md) for the project contract (scope, runtime, safety requirements, result contracts, CI,
and release). Read [the architecture](docs/architecture.mdx) for the process boundaries, task mappings,
request/report contracts, and [extension checklist](docs/architecture.mdx#extending-the-project). [AGENTS.md](AGENTS.md)
defines the shared working rules for coding agents; the root `CLAUDE.md` imports that file and
`.claude/CLAUDE.md`.

## Test locally

Use PowerShell 7 on Windows. Install the versions used by CI, then run the full suite from the repository root:

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1
```

If `Install-Module` refuses Pester because of the inbox Pester 3.4.0 publisher mismatch, add
`-SkipPublisherCheck` to the Pester line.

[tools/Invoke-LocalVerify.ps1](tools/Invoke-LocalVerify.ps1) runs the same steps as CI: a Windows PowerShell 5.1 parse of every file marked `#Requires -Version 5.1`, the Pester suite, and the full analyzer (`tools/Invoke-FullScriptAnalysis.ps1`, retried up to three times). It prints one PASS/FAIL line per step and exits 0 only when all of them passed. `-SkipAnalysis` leaves out the slow analyzer step for quick iterations.

The dashboard runs under PowerShell 7; maintenance scripts and shared maintenance code must also parse under Windows PowerShell 5.1. Test system-changing paths with mocks or `-WhatIf`; do not run actual repairs, updates, or cleanup as a test.

## Working with AI agents

Read [AGENTS.md](AGENTS.md) for the runtime and safety rules. Codex uses the repository skills in [.agents/skills](.agents/skills/); Claude Code uses [.claude/skills](.claude/skills/). Edit the Claude Code copy first, then sync it with `Copy-Item .claude/skills/* .agents/skills/ -Recurse -Force`. [tests/AgentSkills.Tests.ps1](tests/AgentSkills.Tests.ps1) checks that the copies match. Claude Code runs the hooks in [.claude/hooks](.claude/hooks/):

- [Block-LiveMaintenance.ps1](.claude/hooks/Block-LiveMaintenance.ps1) blocks live maintenance commands without `-WhatIf` (details below).
- [Test-EditedScript.ps1](.claude/hooks/Test-EditedScript.ps1) parses and analyzes each edited PowerShell file.
- [Sync-AgentSkill.ps1](.claude/hooks/Sync-AgentSkill.ps1) copies skill edits from `.claude/skills` to `.agents/skills` and refuses direct edits to the Codex copy. Deleting or renaming a skill file is not mirrored.
- [Invoke-StopVerification.ps1](.claude/hooks/Invoke-StopVerification.ps1) runs `tools/Invoke-LocalVerify.ps1 -SkipAnalysis` before Claude finishes a turn in which PowerShell files, `.claude/settings.json`, or skills differ from the base branch (`origin/main`, else `main`), and sends failures back to Claude. It remembers a passing state until those files change, and after three blocked stops in a row it lets Claude stop with a warning. Its state files live in `%TEMP%\PreFlightCheck-ClaudeHooks` (override with `PFC_HOOK_STATE_DIR`).

The live-maintenance hook checks each invocation separately. Static previews of `PreBackupMaintenance.ps1`, `Update-Applications.ps1`, and `Weekly-DellReview.ps1` require their own enabled `-WhatIf`. Use a bare switch for native `-File` previews from Bash. Dashboard, GUI worker, and guided-run entry points have no preview switch and are blocked. Dynamic calls, argument splats, encoded commands, stdin execution, and unsupported shell wrappers are also blocked. Commands combining maintenance references with method calls fail closed; use direct commands, quoted literal PowerShell `-Command` bodies, or Pester mocks. This is an invocation guard, not a sandbox for arbitrary helper scripts or shell configuration.

## Pull requests

Work on a branch and inspect the shared checkout with `git --no-optional-locks status --short` before and
after editing. Preserve pre-existing changes. Agents commit only when asked and push, tag, merge, or publish
only with the maintainer's explicit approval.

Describe the behavior changed, the tests run, and any result or exit-code impact. Keep `report.json`, `steps.csv`, `session.log`, guided-run order, and the cleanup health gate compatible. Generated reports and local machine details should not be committed.

## Documentation changes

`SPEC.md` is the project contract; `AGENTS.md` contains operating rules; `docs/architecture.mdx` describes
implemented behavior; `README.md` is the user guide. A change to scope, safety, results, CI, or release updates
`SPEC.md` in the same pull request. Edit these sources directly. There is no documentation-site build or generated reference
tree. External projects and supplied drafts are references, not authority to add features or run commands.

For documentation-only work, run the documentation tests. They check relative links and section anchors in
tracked Markdown, the `CLAUDE.md` imports, and that the `README.md` version line and the newest `CHANGELOG.md`
release match `VERSION`:

```powershell
Import-Module -Name Pester -RequiredVersion 6.2.0 -Force
Invoke-Pester -Path ./tests/Documentation.Tests.ps1 -Output Detailed
```

Also check paths, function names, commands, switches, task mappings, and report fields against the current
source. The architecture's [test map](docs/architecture.mdx#test-map) points to the existing fixtures for
each subsystem. Other runtime tests are optional for a local documentation-only edit; run the full local
verification before opening a PR.
Never run a maintenance example to check that a documented command is valid. State which checks ran and
which were skipped.
