# Contributing to PreFlightCheck

PreFlightCheck is a Windows 11 pre-backup maintenance tool. Keep changes focused and preserve its operator confirmation, preview, reporting, and cleanup safety gates.

## Test locally

Use PowerShell 7 on Windows. Install the versions used by CI, then run the full suite from the repository root:

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
$config = New-PesterConfiguration
$config.Run.Path = './tests'
$config.Run.Exit = $true
$config.TestRegistry.Enabled = $false
Invoke-Pester -Configuration $config
./tools/Invoke-FullScriptAnalysis.ps1
```

The dashboard runs under PowerShell 7; maintenance scripts and shared maintenance code must also parse under Windows PowerShell 5.1. Test system-changing paths with mocks or `-WhatIf`; do not run actual repairs, updates, or cleanup as a test.

## Working with AI agents

Read [AGENTS.md](AGENTS.md) for the runtime and safety rules. Codex uses the repository skills in [.agents/skills](.agents/skills/); Claude Code uses [.claude/skills](.claude/skills/). Edit the Claude Code copy first, then sync it with `Copy-Item .claude/skills/* .agents/skills/ -Recurse -Force`. [tests/AgentSkills.Tests.ps1](tests/AgentSkills.Tests.ps1) checks that the copies match. Claude Code also uses the [.claude/hooks/Block-LiveMaintenance.ps1](.claude/hooks/Block-LiveMaintenance.ps1) hook to block live maintenance commands without `-WhatIf`.

The hook checks each invocation separately. Static previews of `PreBackupMaintenance.ps1`, `Update-Applications.ps1`, and `Weekly-DellReview.ps1` require their own enabled `-WhatIf`. Use a bare switch for native `-File` previews from Bash. Dashboard, GUI worker, and guided-run entry points have no preview switch and are blocked. Dynamic calls, argument splats, encoded commands, stdin execution, and unsupported shell wrappers are also blocked. Commands combining maintenance references with method calls fail closed; use direct commands, quoted literal PowerShell `-Command` bodies, or Pester mocks. This is an invocation guard, not a sandbox for arbitrary helper scripts or shell configuration.

## Pull requests

Describe the behavior changed, the tests run, and any result or exit-code impact. Keep `report.json`, `steps.csv`, `session.log`, guided-run order, and the cleanup health gate compatible. Generated reports and local machine details should not be committed.
