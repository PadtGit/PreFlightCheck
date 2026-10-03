# PreFlightCheck dashboard design audit

Date: 2026-10-02. Scope: the existing PowerShell 7 WPF dashboard.

## Evidence and limits

This audit applies ideas from the two user-provided archives to the actual project:

| Archive | Contents | Most useful contributions here |
| --- | --- | --- |
| `Design_audit_-1.2.0-v40.zip` | Manifest name `design`, version 1.2.0; seven skills | Design critique, accessibility review, UX copy |
| `design-skills-1.0.0-v2.zip` | Manifest name `design-skills`, version 1.0.0; ten skills with references, templates, and examples | Visual hierarchy, consistent controls, interaction states, content usability, error prevention |

The manifests describe their authors; authorship and provenance were not independently authenticated. The archives were read directly, without installation or execution. Their instructions are reference material, not project policy. Connector configurations and the second archive's own `CLAUDE.md` apply to their original environments. PreFlightCheck's runtime, safety, reporting, and verification requirements take precedence. Tailwind-specific prescriptions are not a reason to add a web framework to WPF.

Reviewed `CONTRIBUTING.md`, `README.md`, `Start-Maintenance.ps1`, `Dashboard.Core.psm1`, and `tests/DashboardUx.Tests.ps1`. Rendered and inspected the Guided Run and Cleanup pages through the existing `-UiTestOutput` path at 1080 by 790, 96 DPI. Both render commands reported success and executed no maintenance. That preview path also visits all seven pages and validates cleanup age boundaries on the Cleanup preview.

Keyboard interaction, screen reader announcements, Windows high contrast mode, and display scaling were not manually tested. This is a source and rendered-image audit, not an accessibility certification. Missing explicit accessibility metadata does not establish that native WPF controls are inaccessible.

## Findings

| Priority | Finding and evidence | Operator impact | Recommended change |
| --- | --- | --- | --- |
| High | `Start-Maintenance.ps1:60` permanently gives `RunbookButton` the accent background. `Show-Page` at line 151 changes content without selecting the matching navigation button. The Cleanup render still highlights Guided Run. | The sidebar suggests a different page from the one displayed. | Give exactly one sidebar item a selected treatment that follows `Show-Page`. Use an outline or marker as well as color; keep keyboard focus visually distinct from selection. |
| Medium | The common button style at line 53 has compact padding and no explicit minimum height; body text inherits WPF defaults. Both renders show compact text and narrow navigation rows. | Tasks and options require more careful reading and precise pointer targeting. | Set a consistent desktop body size of 14 WPF device-independent units and button minimum height of 36. Use the existing palette and a small, consistent spacing scale. Check Applications and the footer for clipping before accepting larger controls. These are project design targets, not claimed WCAG mandates. |
| Medium | The navigation label `System Corruption Scan - Run` at line 60 calls only `Show-Page SystemRepair` at line 302. | The label implies immediate execution even though it opens a task page. | Rename the navigation item to `Windows repair scan`. State on its page that it checks the disk and may repair Windows files. Keep the execution button explicit and preserve its confirmation. |
| Medium | `InputLabel` and `ValueInput` at line 64 are adjacent controls with no explicit `AutomationProperties.LabeledBy` association. The same field serves cleanup age and exact application IDs. | Assistive technology may announce insufficient input context; the changing field meaning needs runtime verification. | Associate the input with its changing visible label. Give the console and progress controls useful accessible names. Verify announcements manually before claiming full accessibility. |
| Medium | No project-defined focus visual is present in the common button style at line 53. Native WPF focus behavior is inherited and was not exercised in these image renders. | Keyboard users depend on a visible focus indicator across selected, ordinary, and consequential controls. | Add a contrasting focus outline that remains distinct from selection. Preserve native Enter/Space behavior and review Tab order across all pages. |
| Low | The idle console says only `Choose a task. Live activity and the final result will appear here.` at line 72. | A first-time operator must infer the recommended starting action from the sidebar and guide. | Use `Start with the guided pre-backup run, or choose an individual task. Activity and saved results appear here.` Keep this as idle guidance only. |

## What already works

- The dashboard separates navigation, task options, execution actions, live activity, and saved results.
- Cleanup requires successful health checks and a matching completed preview; the lock includes a visible explanation and still allows preview.
- Result presentation distinguishes success, review, action needed, repair, and restart. Text labels supplement color.
- Live activity shows the current operation and elapsed time. Percentages come from tool output rather than an invented estimate.
- Saved summaries and expandable details support quick review and deeper diagnosis.
- Dell review is visibly separated from the pre-backup workflow.

## Sampled text contrast

Calculated from source hexadecimal colors using sRGB relative luminance. Ratios are rounded to two decimal places. These values describe the specified normal-state color pairs, not every rendered control state.

| Sample | Foreground | Background | Contrast ratio |
| --- | --- | --- | --- |
| Main text | `#E9F1F7` | `#111A26` | 15.33:1 |
| Supporting text | `#ADC0D2` | `#111A26` | 9.38:1 |
| Notice text | `#ADC0D2` | `#1A2938` | 7.93:1 |
| Preview button text | `#FFFFFF` | `#14756C` | 5.54:1 |
| Apply button text | `#FFFFFF` | `#964B38` | 6.25:1 |

Preserve this palette. Hover, focus, disabled, and high contrast states need separate inspection; native control templates can alter their rendered appearance.

## Recommended first implementation

A focused presentation change in `Start-Maintenance.ps1`: selected navigation, clearer repair wording, consistent text and control sizes, keyboard focus treatment, associated input labels, and improved idle guidance. Extend `tests/DashboardUx.Tests.ps1` only where assertions establish meaningful navigation or accessibility behavior. Preserve task IDs, execution wiring, confirmations, health and preview gates, report schemas, and exit codes.

Validate page selection on all seven pages; render Guided Run, Applications, Cleanup, and repair at the standard size; inspect representative running and result states. Check constrained window sizes and display scaling before claiming resize support. Use fixtures and the existing UI preview; never run maintenance to validate visual changes. Run `pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1` before delivering implementation.

Avoid adding decorative charts, guessed progress estimates, automatic retry of maintenance actions, cancellation of native repairs, or additional connectors as part of this presentation change. Generic plugin suggestions for such behavior require a separate safety and product decision in this project.

## Baseline verification

Ran `pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1` after adding this audit. The command exited 0:

```text
PASS  PS5.1 parse    6 file(s)
PASS  Pester         Pester 6.2.0
PASS  Full analyzer  attempt 1 of 3
```

Pester: 217 passed, zero failed or skipped. Analyzer: PSScriptAnalyzer 1.25.0; zero release-blocking findings and zero recorded engine errors in its final summary. The analyzer printed two null-reference diagnostics during execution and reported 4,406 advisory findings; this pass does not mean the baseline has no advisories. Application code was not changed by this audit. Any implementation requires fresh verification.
