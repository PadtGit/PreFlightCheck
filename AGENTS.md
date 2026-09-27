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
$config = New-PesterConfiguration; $config.Run.Path = './tests'; $config.Run.Exit = $true
$config.TestRegistry.Enabled = $false; Invoke-Pester -Configuration $config
./tools/Invoke-FullScriptAnalysis.ps1
```

CI ([`.github/workflows/verify.yml`](.github/workflows/verify.yml)) also parses every PS5.1 file with Windows PowerShell.
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
| `pfc-release` | Cutting a release (user-invoked: `/pfc-release`) |

Install locations:

- **Codex:** `.agents/skills/<skill>/SKILL.md` in this repository (repo-scoped, loaded automatically).
- **Claude Code:** `.claude/skills/<skill>/SKILL.md` in this repository (loaded automatically).

Edit `.claude/skills` first, then copy the change to `.agents/skills`:
`Copy-Item .claude/skills/* .agents/skills/ -Recurse -Force`. `tests/AgentSkills.Tests.ps1`
fails CI when the two copies differ.

Claude Code also loads `.claude/settings.json`, whose `.claude/hooks/Block-LiveMaintenance.ps1` hook refuses
shell commands that would run a maintenance entry point without `-WhatIf`.
