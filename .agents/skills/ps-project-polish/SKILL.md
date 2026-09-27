---
name: ps-project-polish
description: Use when Bob asks to review, improve, refactor, extend, or add features to a PowerShell project, especially PreFlightCheck or another PadtGit repo. Triggers include reviewing a shared .ps1/.psm1, adding a feature, improving UI/output, making a project look better, or polishing a module.
---

# PowerShell Project Polish

Apply Bob's conventions to PadtGit/PreFlightCheck (Windows 11 pre-backup maintenance toolkit) and PadtGit/Script.PowerShell5.1. Identify whether the request needs code review, new features, UX polish, or a combination.

- Review/refactor: use the checklist below.
- Add functions/features: also read [ps-project-features](../ps-project-features/SKILL.md).
- Console/dashboard polish: also read [ps-project-ux](../ps-project-ux/SKILL.md).

Read actual source files, project instructions, callers, and relevant tests before making findings or edits. README structure alone is insufficient. Treat the project map below as a starting point; reconcile it with the checkout. If files are unavailable, distinguish provisional observations from verified findings and request the missing source.

## Runtime and project map

| Surface | Expected scope; verify in source |
|---|---|
| Start-Maintenance.ps1 dashboard | PS7 |
| Dashboard.Core.psm1 | PS7 dashboard display helpers |
| Cleanup, health, diagnostics scripts | PS5.1, elevated where required |
| Maintenance.Core.psm1 | Shared maintenance logic; PS5.1-compatible for its callers |
| PreBackupMaintenance.ps1 | Consumes exported maintenance functions |
| Invoke-GuiTask.ps1 | Dashboard task wiring |

## Code review checklist

- **Compatibility:** establish the target runtime for each file. PS5.1-loaded files must not contain ternary `?:`, null-coalescing `??`, or `??=` syntax. A runtime version guard does not hide unsupported syntax from the PS5.1 parser; isolate PS7-only syntax in files loaded only by PS7. Prefer the fully qualified `[System.Net.Mail.MailAddress]` type over `[MailAddress]` shortcuts. Check availability and scope before using `$PSNativeCommandUseErrorActionPreference`; preserve appropriate native exit-code handling.
- **Standards:** approved verbs, PascalCase function names, camelCase locals, comment-based help on public functions, `[CmdletBinding()]`, and parameter validation. Destructive functions need `SupportsShouldProcess` and actual `$PSCmdlet.ShouldProcess()` guards before side effects. Check explicit, appropriate `-ErrorAction` on fallible commands, useful error context, and no empty `catch {}` blocks.
- **Data versus display:** return structured objects for data. Use `Write-Verbose`/`Write-Information` for diagnostics. Reserve `Write-Host` for final user-facing status; keep formatting at presentation boundaries.
- **Safety:** verify `-WhatIf`/preview paths cannot mutate system state, elevation is checked where required, and pending health/repair blocks cleanup. Preserve the guarded sequence: review -> health -> update preview -> cleanup preview -> cleanup -> final review. No forced/silent updates or automatic reboot.
- **Structure and reporting:** put shared logic in `Maintenance.Core.psm1`; avoid duplicated helpers. Preserve existing `report.json`, `steps.csv`, `session.log`, and exit codes `0/1/2`. Read their actual schemas and meanings; do not invent a mapping.

## Review output and authorized fixes

Start with a short verdict, then concrete issues ordered by impact. Each issue includes the file and line when available, the problem, and a specific fix. Separate confirmed defects from optional polish. Give a concise report rather than a rewritten wall of code unless requested.

For a review-only request, offer to apply all fixes in one pass and wait for Bob's confirmation before editing. If Bob has already requested fixes, improvements, or refactoring, carry out that authorized work without asking again. Bob prefers concise, copy-paste-ready scripts and batched fixes; go step by step only when requested.

Validate changes with appropriate existing checks and the relevant PS5.1/PS7 parsers or runtimes. Exercise destructive paths with mocks or safe previews. Report what was checked and any runtime unavailable for validation; do not run maintenance operations merely to review code.
