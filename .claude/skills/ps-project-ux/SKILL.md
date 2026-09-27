---
name: ps-project-ux
description: Use when Bob asks to improve PowerShell console output or dashboard presentation, make a script look better, polish UI/UX, clarify task status, add progress feedback, or adjust sidebar grouping, spacing, icons, and colors, especially in PreFlightCheck or other PadtGit projects.
---

# PowerShell Project UX

Polish the requested surface with concrete, minimal changes. Bob prefers concise, scannable output and batched improvements. Read the actual output/rendering code and its data source before proposing or editing. Preserve runtime support and operational safety.

Identify console/CLI, GUI dashboard, or both. Apply the relevant guidance only. Use a full redesign only when Bob asks for one.

## Console / CLI

Applies to health checks, cleanup previews, update previews, and related command-line tasks.

- Use consistent final status lines: green = OK, yellow = review needed, red = action required, aligned with existing project semantics. Include readable status text so color is supplementary.
- Reserve `Write-Host -ForegroundColor` for final user-facing status lines. Keep data as custom objects or other structured pipeline output; use `Write-Verbose`/`Write-Information` for diagnostics.
- Summarize results in scannable tables/lists. Use `Format-Table` or other formatting only at the final display boundary so reusable functions and report pipelines retain structured data. Avoid raw cmdlet dumps.
- Add `Write-Progress` to long operations such as DISM, SFC, and component cleanup. Use truthful phase/activity feedback when exact percentages are unavailable, and clear progress on completion or failure.
- Keep essential errors and actionable details visible while moving lengthy diagnostics to existing logs.

## GUI dashboard

Applies primarily to `Start-Maintenance.ps1` and its `Invoke-GuiTask.ps1` integration in PreFlightCheck; locate equivalents in other projects.

- Aim for Bob's WinUI-style dashboard with System / Maintenance / Dell sidebar sections. Use the WinUtil-style layout as inspiration, without directly copying it or introducing a framework migration.
- Suggest or apply focused spacing, grouping, label, icon, and color changes. Maintain the existing design conventions and task behavior.
- Distinguish idle, running, done, and blocked-needs-repair states with explicit labels and consistent visual treatment. Preserve genuine warning/failure states; do not treat every completed task as successful.
- Surface the actual meanings of exit codes `0/1/2` in the UI so Bob does not need to open `report.json`. Read the current task/report contract; do not guess which code means warning, failure, or repair required.
- Preserve guarded task eligibility: cleanup remains blocked while health/repair is pending. A display-only change must not bypass guards, trigger forced/silent updates, or introduce automatic reboot.

## Verify and deliver

Verify supported runtimes before adding syntax: the dashboard is expected to use PS7; cleanup/health/diagnostics are expected to support PS5.1. Read the checkout to confirm. Shared code must support its callers.

Check representative idle/running/success/review/action-required/blocked displays as applicable using fixtures or safe mocks. Verify that display formatting leaves report/log data intact and that changes preserve CLI output contracts. Inspect the rendered dashboard when an appropriate preview is available; otherwise state that visual rendering was not verified.

For a suggestions-only request, give concrete proposed changes. For an explicit request to improve the UI/output, apply the authorized changes together and report what changed and how it was checked. Keep output concise and code copy-paste-ready when scripts are requested.

If the change adds task functionality, also consult [ps-project-features](../ps-project-features/SKILL.md). For a broader code review, consult [ps-project-polish](../ps-project-polish/SKILL.md).
