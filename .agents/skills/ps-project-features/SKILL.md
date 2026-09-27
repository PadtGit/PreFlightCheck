---
name: ps-project-features
description: Use when Bob asks to add or extend a PowerShell function, maintenance check, script capability, or dashboard task in PreFlightCheck, PadtGit/Script.PowerShell5.1, or another PowerShell project, including requests such as add a feature to X or wire this check into the dashboard.
---

# PowerShell Project Features

Add features that follow Bob's existing runtime, safety, integration, and reporting conventions. Read the actual source, project instructions, and a comparable existing task before designing or editing; do not infer implementation from the README alone.

## Establish scope

Infer from the checkout and request which script/module owns the feature, whether it targets PS5.1 or PS7, and whether it needs a dashboard entry or is CLI-only. Ask briefly only for material details still missing. Clarify the feature's intended behavior when it is unspecified.

PreFlightCheck's expected split is a PS7 dashboard with PS5.1 cleanup/health/diagnostics scripts, elevated where required. Verify this in the current files. Shared modules must work in every supported caller. Keep PS7-only syntax out of files parsed by PS5.1, even inside version-guarded branches.

## Integration map

| Addition | Expected location; verify current patterns |
|---|---|
| Shared maintenance check/function | Export from Maintenance.Core.psm1 |
| Maintenance orchestration | Consume the function in PreBackupMaintenance.ps1 |
| Dashboard task execution | Wire into Invoke-GuiTask.ps1 |
| Dashboard entry | Add to Start-Maintenance.ps1's appropriate sidebar section |

Use this map for PreFlightCheck; inspect equivalent integration points in other repositories rather than creating these filenames there.

## Implementation checklist

- Use approved verbs, PascalCase function names, camelCase locals, comment-based help, `[CmdletBinding()]`, and parameter validation consistent with the module.
- Actions that change system state need a safe `-WhatIf`/preview path. Destructive operations require `SupportsShouldProcess` and `$PSCmdlet.ShouldProcess()` guards around actual side effects, including delegated operations.
- Use explicit, appropriate `-ErrorAction` for fallible commands, actionable error reporting, and no empty catches. Preserve native-command exit-code handling across supported runtimes.
- Return structured data. Keep `Write-Host` for final user-facing status; use `Write-Verbose`/`Write-Information` for diagnostics.
- Add report/log entries following existing `report.json`, `steps.csv`, and `session.log` schemas. Preserve established exit codes `0/1/2`; inspect their meanings instead of assigning new ones.
- Check elevation where required. Preserve no forced/silent updates and no automatic reboot. Pending health/repair must block cleanup.

The guarded sequence is review -> health -> update preview -> cleanup preview -> cleanup -> final review. If the feature changes it, establish the insertion point and whether failure is blocking or optional. Confirm those choices with Bob if neither his request nor existing conventions settles them; continue independent work while awaiting the answer.

## Finish

Validate supported runtime compatibility and relevant CLI/dashboard flows using existing checks, safe previews, or mocks. Do not execute system-changing maintenance merely to test integration. State unavailable runtimes or untested paths.

When the feature is finalized, update `CHANGELOG.md` and bump `VERSION` according to the repository convention. Ask before choosing a version segment when that convention and Bob's request leave it unclear. Do not invent release files for a repository that uses another mechanism.

Apply authorized related changes together. Report what changed, where it is exposed, and validation results concisely. For visual changes, consult [ps-project-ux](../ps-project-ux/SKILL.md); for a broader review, consult [ps-project-polish](../ps-project-polish/SKILL.md).
