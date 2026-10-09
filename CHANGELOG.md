# Changelog

## Unreleased

- Assessed free space by verified partition purpose, replacing the blanket 1 GiB warning for EFI and Windows recovery partitions with explicit 50 MiB EFI caution and 250 MiB recovery servicing thresholds. Kept partition observations visible and preserved event reviews and cleanup safeguards.
- Added `SPEC.md` as the project contract and `docs/architecture.mdx` as the implementation reference, and aligned the agent instructions (`AGENTS.md`, `CLAUDE.md`) and contributor guide with them.
- Added documentation tests that check relative links and section anchors in tracked Markdown, the `CLAUDE.md` imports, and that the `README.md` version line and newest `CHANGELOG.md` release match `VERSION`.

## 0.4.3 - 2026-10-03

- Made dashboard navigation follow the displayed page with a selected outline and leading marker; kept the selected item visible and keyboard focus distinct from selection.
- Clarified Windows repair scan wording, associated each changing input label, added accessible activity names, and directed idle operators toward the guided pre-backup run.
- Standardized dashboard body text and control sizes, and kept inputs reachable at the minimum window size with safe preview and fixture checks.
- Validated temporary cleanup candidates through protected file handles before deleting them, preserving age and reparse-point safeguards.

- Required a successful dashboard cleanup preview matching the selected age and optional actions before applying cleanup; included Recycle Bin and Delivery Optimization selections in dashboard and guided previews.
- Blocked component-store cleanup when earlier integrity, file-system, or essential inventory checks are incomplete or require review, repair, or restart.
- Required normal Windows and file-system health checks in every actual cleanup invocation, blocking all cleanup actions on health review, repair, restart, or failure; kept cleanup previews available without health scans.
- Showed the saved stopping reason and nearby tool output directly in dashboard results, with expandable report findings and an exit-code legend on every task page that needs review or action; kept successful results concise.
- Retried a contradictory CHKDSK RAW result through the supported read-only volume scan, and confirmed transient Component Servicing restart markers before stopping a guided run.
- Added shared agent instructions and matching repository skills for Codex and Claude Code, with a test that detects drift between the skill copies.
- Added a Claude Code hook that blocks live maintenance entry points without `-WhatIf`.
- Added `tools/Invoke-LocalVerify.ps1` and the `pfc-verify` skill to run the CI checks locally (Windows PowerShell 5.1 parse, Pester, full analyzer) with a per-step summary; excluded unstaged deletions from the parse inventory.
- Added Claude Code hooks that run the PS5.1 parse and Pester before Claude finishes a turn with changed scripts, and that copy skill edits to the Codex copy while refusing direct edits to it.
- Read dashboard fixture output as UTF-8 in tests so they pass from consoles using an OEM code page such as 850.
- Parsed PowerShell 5.1 scripts with Windows PowerShell in CI and added monthly updates for pinned GitHub Actions.
- Aligned contributor and release documentation with the agent setup and published v0.4.2 release.

## 0.4.2 - 2026-09-25

- Reject unconfirmed Upgrade all before gathering system inventory or creating reports.
- Run System Corruption Scan tools directly with discrete arguments while keeping live output, logs, and exit-code handling.
- Move pure dashboard display helpers into a module so their tests can import them without executing the UI.
- Add an MIT license, contributor test instructions, and a ready-to-run release archive builder and upload workflow.

## 0.4.1 - 2026-09-25

- Forward native check output to the dashboard while each tool is running, including carriage-return progress updates from tools such as DISM, SFC, and CHKDSK; retain complete per-tool logs and numeric exit-code handling.
- Remove invisible NUL padding from SFC-style Unicode output so progress text and saved health conclusions remain readable under Windows PowerShell 5.1.
- Show the active operation throughout inventory, health, updates, cleanup, Dell review, and report saving, with elapsed time and a modestly taller live activity panel.
- Display a tool-provided percentage for the current operation when available and activity feedback otherwise; reset progress between checks and keep warning, restart, repair, and failure outcomes distinct.
- Preserve the finished summary and direct result/report actions, guided-run warnings, and cleanup eligibility checks.
- Validate streaming with a harmless Windows PowerShell 5.1 child process, plus dashboard fixtures and existing safety regressions.

## 0.3.1 - 2026-09-20

- Kept cleanup locked after either repair action; the operator must explicitly run the normal Windows Health Check after reviewing repair logs and restarting if requested.
- Required completed health diagnostics with no review, failure, or restart conditions before reporting health readiness; preview-only health runs cannot unlock cleanup.
- Required at least one eligible fixed NTFS volume to be checked; empty or unsupported storage inventories now produce a review result and keep cleanup locked.
- Made the dashboard cleanup lock explicit, disabled its apply action until health is ready, and retained cleanup preview and restart/repair warnings during refresh.
- Invalidated health readiness again before saving reports so late inventory warnings cannot bypass the guided cleanup gate.
- Distinguished a blocked health review from a repair recommendation in the guided run, preserving the actual repair flag.
- Classified CHKDSK exit codes 1 and 2 as review-required and rechecked restart state after System Corruption Scan.
- Cleared stale dashboard health readiness after repair or unsuccessful health tasks, including a worker that exits without saving its completion result.
- Restored the visible Preview available updates action and displayed its saved WinGet list in the dashboard result area while preserving full logs.
- Clarified Upgrade all package scope and documented the actual session/task report locations.
- Recorded the restart-required flag before stopping selected WinGet changes when a pending or unknown restart is detected, so the dashboard also blocks cleanup.
- Added fixture-driven behavior regressions for health eligibility, preview reachability/output, and retained exact WinGet arguments and restart checks. No maintenance commands run in these tests.
- Preserved report schemas, exit-code meanings, explicit update confirmation, and the existing full analyzer audit and release gate.

## 0.3.0 - 2026-09-20

- Updated the GitHub Actions test dependency from Pester 5.7.1 to Pester 6.2.0.
- Added a separate WinUtil-style System Corruption Scan action while keeping the existing Windows Health workflow.
- Added distinct WinGet actions for install/upgrade, uninstall, upgrade-all, installed-app listing, and clearing selection.
- Corrected selected-package WinGet arguments and rejected empty uninstall selections.
- Rechecked restart state after upgrade-all and surfaced installed-app output in dashboard results.
- Preserved the complete 75-rule analyzer audit while limiting the release gate to engine errors and actionable correctness findings.
- Removed an invalid workflow file and enabled verification for pull requests targeting release branches.
- Retried transient PSScriptAnalyzer engine failures per file while preserving a hard failure after three unsuccessful attempts.

## 0.4.0 - 2026-09-21

- Carried review findings from every guided-run step into `guided-result.json` and the dashboard summary, including the source report path.
- Return exit code 2 when the guided sequence completes with findings that need review; keep exit code 1 for a stopped run and 0 for a clean completion.
- Keep the Windows health cleanup gate separate from the guided review status.
- Preserve restart and repair flags from a failed health step and name the failed check in the stopped-run summary.
- Clarify idle, running, success, review, action-needed, restart, and repair dashboard states with readable labels and supplementary color.
- Stream the current guided step and recent worker output into a modest live activity panel, then show a concise result with direct summary and result-folder actions.

## 0.2.0 - P0 safety verification

- Added isolated Pester coverage for the pre-backup safety contract.
- Added GitHub Actions verification on Windows with pinned Pester and PSScriptAnalyzer versions.
- Added explicit checks that the default workflow does not delete shadow copies or reset the Windows Update cache.
- Added verification for `ShouldProcess`, `-WhatIf`, terminating orchestration errors, native exit-code handling, AC-line detection, and reparse-point-aware cleanup.
- Kept the existing safe `Audit` default and explicit cleanup/repair modes.
