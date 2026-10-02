# PreFlightCheck agent instructions

Windows 11 pre-backup maintenance toolkit. Repository: `PadtGit/PreFlightCheck`
(default branch `main`). Read
[CONTRIBUTING.md](CONTRIBUTING.md) and the relevant source before changing anything.

## Runtime map

| File | Runtime |
|---|---|
| `Start-Maintenance.ps1`, `Invoke-GuiTask.ps1`, `Dashboard.Core.psm1` | PowerShell 7 (dashboard) |
| `PreBackupMaintenance.ps1`, `Invoke-PreBackupRun.ps1`, `Maintenance.Core.psm1`, `Update-Applications.ps1`, `Weekly-DellReview.ps1` | Windows PowerShell 5.1, elevated where required |

Files marked `#Requires -Version 5.1` must parse under Windows PowerShell 5.1: no
`?:`, `??`, `??=` or other PS7-only syntax, even behind a version guard.

## Safety rules

- Never run real cleanup, repair, updates, or reboots as a test. Use Pester mocks or `-WhatIf`.
- Preserve the guarded order: review -> health -> update preview -> cleanup preview -> cleanup -> final review.
  Pending health/repair or restart blocks cleanup.
- Keep `report.json`, `steps.csv`, `session.log` schemas and exit codes `0/1/2` compatible.
- Do not commit generated reports (`GuiRuns/`, `Reports/`, `ValidationReport/`, `dist/`, `*.log`).

## Verify before finishing

Run from the repo root in PowerShell 7 (CI pins Pester 6.2.0 and PSScriptAnalyzer 1.25.0):

```powershell
pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1
```

It runs the steps of CI ([`.github/workflows/verify.yml`](.github/workflows/verify.yml)) in order: Windows PowerShell 5.1
parse of every PS5.1 file, Pester, then `tools/Invoke-FullScriptAnalysis.ps1` with retries. It exits 0 only when every
step passed. Add `-SkipAnalysis` while iterating; run it without that switch before opening a PR.
Releases: bump `VERSION`, update `CHANGELOG.md`, publish a GitHub release tagged `v<VERSION>`;
[`.github/workflows/release-archive.yml`](.github/workflows/release-archive.yml) attaches the ZIP.

## Skills

Apply these according to the request. Each skill's `SKILL.md` has the details.

| Skill | Use for |
|---|---|
| `ps-project-polish` | Reviews, refactors, general improvements (entry point) |
| `ps-project-features` | New functions, checks, dashboard tasks |
| `ps-project-ux` | Console output and dashboard presentation |
| `powershell-security-review` | Security review/hardening; ends with its strict analyzer check |
| `pfc-verify` | Running the CI checks locally before finishing or opening a PR |
| `pfc-release` | Cutting a release (user-invoked: `/pfc-release`) |

Install locations:

- **Codex:** `.agents/skills/<skill>/SKILL.md` in this repository (repo-scoped, loaded automatically).
- **Claude Code:** `.claude/skills/<skill>/SKILL.md` in this repository (loaded automatically).

Edit `.claude/skills` first, then copy the change to `.agents/skills`:
`Copy-Item .claude/skills/* .agents/skills/ -Recurse -Force`. `tests/AgentSkills.Tests.ps1`
fails CI when the two copies differ. In Claude Code the `Sync-AgentSkill.ps1` hook does the copy (see below);
deletions and renames still need both copies changed by hand.

Claude Code also loads `.claude/settings.json`, which runs these hooks from `.claude/hooks/`:

- `Block-LiveMaintenance.ps1` refuses shell commands that would run a maintenance entry point without `-WhatIf`.
- `Test-EditedScript.ps1` runs after every edit to a `.ps1`/`.psm1`/`.psd1` file (PS5.1 parse + PSScriptAnalyzer,
  release-blocking findings only) and exits 2 on problems; fix them before continuing. It skips `PSUseCompatibleCommands`/`Types`,
  which only `tools/Invoke-FullScriptAnalysis.ps1` enforces. Keep its `$advisoryRules` in sync with that script.
- `Sync-AgentSkill.ps1` copies each file edited under `.claude/skills` to `.agents/skills` and refuses direct edits to `.agents/skills`.
- `Invoke-StopVerification.ps1` runs `tools/Invoke-LocalVerify.ps1 -SkipAnalysis` when Claude stops with PowerShell files or skills
  changed against `main`, and blocks the stop on failures. A passing state is cached until those files change; after three
  blocked stops in a row it lets Claude stop and warns the user.
