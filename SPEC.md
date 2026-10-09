# SPEC.md

Project contract for PreFlightCheck: what the project is, how it is packaged, how it runs, and what it must
guarantee. Written for anyone, human or AI, who needs to understand the project itself.

`AGENTS.md` points here for these facts and separately covers how an agent works in this repository.
[docs/architecture.mdx](docs/architecture.mdx) explains the implementation in depth (flows, field lists, test
map, extension checklists). [README.md](README.md) is the operator guide. The source and its tests are the
ground truth for current behavior; when this file and the code disagree, treat it as a defect to report and
resolve deliberately, not as permission to change either side silently. This file does not change based on
who is reading it.

## Project Context

PreFlightCheck is a Windows 11 pre-backup maintenance toolkit. It reviews the system, checks Windows and
file-system health, previews application updates and cleanup, and performs operator-confirmed maintenance
before a Veeam backup. It was tailored to a Dell G5 5590; the Dell helper rejects other models, and the
README asks operators to review suitability on other computers. The repository is `PadtGit/PreFlightCheck`
(default branch `main`), released under the MIT license. The current version is in `VERSION`.

### Stack

- Languages and hosts: PowerShell 7 x64 (`#Requires -Version 7.0`) for the dashboard and its worker; Windows
  PowerShell 5.1 (`#Requires -Version 5.1`) for maintenance. Two small C# types are compiled at runtime with
  `Add-Type` (AC power status and handle-level file validation).
- UI: WPF, with the XAML inline in `Start-Maintenance.ps1`.
- Configuration: script parameters and one `request.json` per dashboard task. There are no configuration files.
- Native tools and Windows cmdlets: DISM, SFC, CHKDSK, `vssadmin`, WinGet, `Get-Volume`, `Get-PhysicalDisk`,
  `Repair-Volume`, `Get-WinEvent`, `Get-MpComputerStatus`, `Clear-RecycleBin`, and
  `Delete-DeliveryOptimizationCache`.
- Tests: Pester 6.2.0 under `tests/`.
- Lint: PSScriptAnalyzer 1.25.0 with `PSScriptAnalyzerSettings.psd1`, run by `tools/Invoke-FullScriptAnalysis.ps1`.
- CI: GitHub Actions (`.github/workflows/verify.yml`, `.github/workflows/release-archive.yml`); Dependabot
  checks the pinned GitHub Actions monthly (`.github/dependabot.yml`).
- Docs: hand-written Markdown and MDX. There is no documentation site or generator.
- Release artifact: `dist/PreFlightCheck-<version>.zip`, built by `tools/New-ReleaseArchive.ps1`.

### Repository Layout

- `Start-Maintenance.cmd`: launcher. Requires `%ProgramFiles%\PowerShell\7\pwsh.exe` and starts the dashboard
  with `-STA`.
- `Start-Maintenance.ps1`: PowerShell 7 WPF dashboard (inline XAML, navigation, confirmations, session state,
  completion polling).
- `Dashboard.Core.psm1`: PowerShell 7 presentation helpers shared by the dashboard and worker (result
  evidence, labels and styles, live activity, cleanup selection key).
- `Invoke-GuiTask.ps1`: PowerShell 7 worker. Runs one allowlisted dashboard task as a Windows PowerShell 5.1
  child and writes its results.
- `PreBackupMaintenance.ps1`: Windows PowerShell 5.1 maintenance entry point with modes `Audit`, `Clean`,
  `Health`, `SystemRepair`, and `Updates`.
- `Invoke-PreBackupRun.ps1`: Windows PowerShell 5.1 guided sequence.
- `Maintenance.Core.psm1`: Windows PowerShell 5.1 shared module (restart and AC-power checks, guided findings
  and disposition, guarded Temp-file enumeration and deletion).
- `Update-Applications.ps1`: Windows PowerShell 5.1 command-line WinGet preview and selected-install wrapper.
- `Weekly-DellReview.ps1`: Windows PowerShell 5.1 attended Dell G5 5590 support-page review.
- `PSScriptAnalyzerSettings.psd1`: analyzer settings for all 75 built-in rules.
- `tools/`: `Invoke-LocalVerify.ps1` (local CI runner), `Invoke-FullScriptAnalysis.ps1` (full analyzer and
  release gate), `New-ReleaseArchive.ps1` (release ZIP).
- `tests/`: Pester tests (mocks and fixtures only).
- `docs/`: hand-written documents (`architecture.mdx`, `Full-ScriptAnalyzer-Review.md`,
  `Dashboard-Design-Audit.md`).
- `.github/`: CI workflows and Dependabot configuration.
- `.claude/`: Claude Code settings, hooks, canonical skills, and environment notes (`.claude/CLAUDE.md`).
- `.agents/skills/`: tracked copy of `.claude/skills/` for Codex.
- `AGENTS.md`, `CLAUDE.md` (imports `AGENTS.md`), `CONTRIBUTING.md`, `README.md`, `CHANGELOG.md`, `SPEC.md`,
  `VERSION`, `LICENSE`.
- Generated and ignored (see `.gitignore`): `GuiRuns/`, `Reports/`, `ValidationReport/`, `dist/`, `*.log`,
  `.validation-deps/`, `.worktrees/`, `.claude/settings.local.json`. Untracked local agent configuration (for
  example a `.codex/` folder) is not part of the project.

### Runtime Requirements

- Windows 11.
- 64-bit PowerShell 7 in its standard location for the dashboard and worker.
- Windows PowerShell 5.1 at `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` for maintenance.
- Administrator rights for the dashboard (it relaunches itself elevated), for actual `Clean`, `Health`, and
  `SystemRepair`, and for the guided run.
- Confirmed AC power for any actual maintenance.
- WinGet from Microsoft's App Installer, for application updates only.

## Goals

- Leave the system clean and healthy before a backup runs: verify Windows and file-system health, show
  pending restarts, and remove only safely identifiable old temporary files.
- Enforce one safe order for the full routine: review -> health -> update preview -> cleanup preview ->
  cleanup -> final review.
- Keep the operator in control: preview where supported, confirm changes, and stop with a clear reason when
  repair, restart, or review is needed.
- Preserve evidence: full native-tool output and machine-readable reports for every task, with a concise
  result and access to details.
- Apply the same safeguards to the dashboard, the guided run, and direct command-line use.
- Ship as plain scripts that can be read, reviewed, and run from one folder.

## Non-Goals

- PreFlightCheck does not start, schedule, or detect Veeam jobs, and its exit code is not an automatic backup
  veto.
- Results describe observations. They do not certify a restorable backup, a malware-free system, or the
  health of every application.
- No automatic reboot, shadow-copy deletion, Windows Update cache reset, network reset, or irreversible
  component-store base reset.
- No firmware or driver installation. The Dell helper only reports and opens the official support page.
- No WinGet bootstrap, other package managers, application catalog, or preset system.
- No cleanup outside the two Temp roots and the two opt-in extras (Recycle Bin, Delivery Optimization cache).
- No compile step, generated runtime script, installed PowerShell module, or persistent settings file.
- No dashboard cancellation or rollback of a running task.

## Distribution Model

There is no build step. The files in the repository root are the files that run.

1. Scripts find their siblings through `$PSScriptRoot` and import the two modules by path with
   `Import-Module -Force`. All runtime files must stay together in one folder.
2. `tools/New-ReleaseArchive.ps1` reads `VERSION` (format `major.minor.patch`), checks that every file in its
   explicit list exists, and writes `dist/PreFlightCheck-<version>.zip` with one root folder,
   `PreFlightCheck-<version>/`. It refuses to overwrite an existing archive.
3. The archive contains exactly: `Start-Maintenance.cmd`, `Start-Maintenance.ps1`, `Dashboard.Core.psm1`,
   `Invoke-GuiTask.ps1`, `Invoke-PreBackupRun.ps1`, `Maintenance.Core.psm1`, `PreBackupMaintenance.ps1`,
   `Update-Applications.ps1`, `Weekly-DellReview.ps1`, `VERSION`, `README.md`, `CHANGELOG.md`, and `LICENSE`.
   Tests, tooling, agent configuration, developer documentation, and reports are excluded.

Because runtime files are loaded by relative path from one folder, a new runtime dependency must be a file
in that folder and in the archive list (and in `tests/ReleasePackage.Tests.ps1`). Nothing is downloaded or
installed at runtime.

## Runtime Model

- Maintenance never runs on the window's thread. Each layer is a separate process: the dashboard
  (`pwsh.exe`, STA, elevated), one hidden worker per task (`pwsh.exe`), and the maintenance child
  (`powershell.exe` 5.1). The guided run starts one more 5.1 child per step.
- Values cross process boundaries only as files and discrete arguments (`request.json`, command-line
  switches, `report.json`, `guided-result.json`, `finished.json`). There is no shared runspace state; module
  state is process-local.
- The dashboard allows one active task, refuses to close while it runs, and polls the worker's files with a
  WPF `DispatcherTimer` every 700 ms. Rendering stays on the WPF thread.
- `PreBackupMaintenance.ps1` takes the named mutex `Local\BobPreBackupMaintenance`, so only one maintenance
  invocation runs per logged-in Windows session. It is not a machine-wide lock, does not cover a whole guided
  sequence, and does not coordinate with backup software.
- Opening the dashboard starts with no health readiness and no recorded cleanup preview.

## UI And Event Contract

- The XAML is inline in `Start-Maintenance.ps1`. Named controls are bound with `FindName` into script-scope
  variables, and every event is wired explicitly (`Add_Click`, the timer's `Add_Tick`, the window's
  `Add_Closing`). A control's name does not dispatch a function by convention.
- Pages: `Runbook`, `Audit`, `Applications`, `Cleanup`, `Health`, `SystemRepair`, `Dell`. `Show-Page` sets each
  page's labels, inputs, and visible buttons; `Start-DashboardTask` turns the page and action into a request.
- Dashboard task names: `PreBackupRun`, `Audit`, `UpdatePreview`, `UpdateInstall`, `UpdateUninstall`,
  `UpdateAll`, `InstalledApps`, `CleanPreview`, `Clean`, `HealthCheck`, `HealthRepair`, `SystemRepair`,
  `DellReview`. The worker rejects any other name. A task name must stay consistent across the dashboard's
  request and completion logic, the worker's allowlist and argument mapping, and the presentation helpers.
- Apply actions (guided run, cleanup, repair, Windows repair scan) and the WinGet install, uninstall, and
  upgrade-all actions show a confirmation prompt before the task starts.
- `-UiTestOutput`, `-UiPage`, and `-UiState` render a page to an image for tests. This needs the Windows x64
  STA host but bypasses elevation and never starts maintenance.

## Configuration And Request Contract

`PreBackupMaintenance.ps1` parameters:

| Parameter | Contract |
| --- | --- |
| `Mode` | `Audit` (default), `Clean`, `Health`, `SystemRepair`, `Updates`. |
| `MinimumAgeDays` | 7-365, default 14. |
| `EmptyRecycleBin`, `ClearDeliveryCache` | `Clean` only. |
| `RepairWindows`, `ComponentCleanup` | `Health` only. |
| `ApplicationId`, `Uninstall`, `UpgradeAll`, `ShowInstalled`, `OpenUpdatePages` | `Updates` only. IDs must match `^[A-Za-z0-9][A-Za-z0-9._+-]*$`; Dell, Alienware, BIOS, and firmware IDs are rejected. `Uninstall` needs at least one ID. |
| `MaintenanceWindowConfirmed` | Required for actual `Clean`, `Health`, `SystemRepair`, and application changes. |
| `ReportDirectory` | Default `Reports` beside the script. |
| `WhatIf`, `Confirm` | From `SupportsShouldProcess`. |

A switch used with the wrong mode is rejected before any work starts.

- `Invoke-PreBackupRun.ps1`: `ReportDirectory` (mandatory), `MinimumAgeDays`, `EmptyRecycleBin`,
  `ClearDeliveryCache`, `MaintenanceWindowConfirmed`. It has no `-WhatIf`.
- `Update-Applications.ps1`: `ApplicationId`, `Install`, `ReportDirectory`, plus `-WhatIf`. Without `-Install`
  it previews; with `-Install -ApplicationId` it passes `-MaintenanceWindowConfirmed` itself, so `-Install` is
  the operator's confirmation on that path. The other maintenance preconditions still apply.
- `Weekly-DellReview.ps1`: no parameters besides `-WhatIf`.
- `request.json` (written by `Start-DashboardTask`, read by `Invoke-GuiTask.ps1 -RequestPath`) holds `Task` plus
  only the fields that task uses: `MinimumAgeDays`, `EmptyRecycleBin`, and `ClearDeliveryCache` (guided run and
  cleanup tasks), `ApplicationId` (install and uninstall), and `ComponentCleanup` (`HealthRepair`). The worker
  maps the task to a fixed script and switches; no request field selects a script or command text. The request
  is a local transport between the operator's own processes, not an authorization boundary.

## Safety Requirements

PreFlightCheck changes a live system right before a backup. These requirements hold for every caller:

- **Guarded order.** The guided run executes review -> health -> update preview -> cleanup preview -> cleanup
  -> final review. A pending or unknown restart, a recommended repair, or a health result that is not ready
  stops it before cleanup. Any step exit code other than `0` or `2` stops it.
- **Preconditions.** Actual maintenance needs `-MaintenanceWindowConfirmed`, known AC power, a non-empty disk
  and volume inventory with every disk and fixed volume healthy, and no pending or unknown restart.
  `SystemRepair` is the only mode allowed to start with a pending restart. Actual `Clean`, `Health`, and
  `SystemRepair` need Administrator rights.
- **Health readiness.** `HealthReady` is true only after a normal (non-repair, non-preview) health run
  completes component analysis, DISM `/ScanHealth`, SFC `/verifyonly`, and an online CHKDSK scan of every
  fixed NTFS volume with a drive letter (at least one must exist), with no review, failed, repair, or restart
  result. Any review or failed result in the report clears it before the report is saved.
- **Cleanup lock.** Every actual `Clean` repeats that normal health run immediately before deleting and stops
  if it is not ready. Repair (`Health -RepairWindows` or `SystemRepair`) never unlocks cleanup, and a `-WhatIf`
  run cannot satisfy the gate. `Clean -WhatIf` is a preview without health scans. The dashboard additionally
  requires a ready health result from this session and a successful preview with the same age and options.
- **Deletion scope.** Only regular files in `%LOCALAPPDATA%\Temp` and `%SystemRoot%\Temp` whose creation and
  last-write times are both older than the cutoff. No folders, no reparse points anywhere on the path, and no
  network, device, alternate-stream, or drive-root targets. Each candidate passes `Test-ContainedRegularPath`,
  `Get-AgedTemporaryFile`, `Remove-AgedTemporaryFile` (per-file `ShouldProcess` and revalidation), and
  `Remove-TemporaryFileByHandle`, which re-checks path, attributes, and timestamps through protected handles
  before marking the file for deletion. Files that are busy or cannot be verified are skipped.
- **Optional cleanup.** Recycle Bin and Delivery Optimization cleanup run only with their own switches, in
  `Clean`, after the health gate.
- **Component cleanup.** DISM `/StartComponentCleanup` runs only with `-ComponentCleanup`, after an explicit
  healthy or repaired DISM conclusion and completed checks with no review, failure, repair, or restart, and
  after a fresh restart check. `/ResetBase` is never used.
- **Applications.** WinGet runs only from the App Installer alias in the user's `WindowsApps` folder after its
  Microsoft signature is validated; a PATH-resolved `winget.exe` is never executed. Selected actions use
  `--id <id> --exact --disable-interactivity`. `UpgradeAll` runs `winget upgrade --all --disable-interactivity`,
  does not apply the selected-ID exclusions, and may include vendor or driver packages. Every application
  change rechecks the restart state afterwards; a selected change that leaves one pending stops the run. No
  forced updates, agreement auto-acceptance, or automatic reboot.
- **Previews.** Entry points with `SupportsShouldProcess` guard every system change. A preview still writes
  reports and runs read-only checks, but never applies the previewed change. The dashboard, worker, and guided
  run have no preview mode.
- **Data.** Reports stay local and are ignored by Git. No credentials or secrets are stored.

## Result And Report Contract

Exit codes (maintenance entry point, guided run, and worker; the worker returns its child's code):

| Code | Meaning | `PreBackupMaintenance.ps1` label | Dashboard label |
| --- | --- | --- | --- |
| `0` | Completed without recorded warnings | `OK` | `SUCCESS` |
| `1` | Failed or unavailable essential check, or a stopped guided run | `ACTION NEEDED` | `ACTION NEEDED` |
| `2` | Review required, including a completed guided run with findings | `REVIEW` | `REVIEW` |

- Every maintenance step is recorded with status `Observed`, `Completed`, `Review`, `Skipped`, or `Failed`.
  Any `Failed` gives `1`; otherwise any `Review` gives `2`; otherwise `0`. The final console line and the exit
  code come from the same decision.
- The dashboard shows `RESTART` or `REPAIR` ahead of the exit-code state when those flags are set.
- `report.json` and `steps.csv` (maintenance), `guided-result.json`, `guided-steps.csv`, and `guided-run.log`
  (guided run), `finished.json`, `summary.txt`, `details.txt`, and `console.txt` (worker), and `session.log`
  (dashboard header, worker summaries) are compatibility contracts. Their producers and consumers change
  together; none carries a schema version. Field lists and the output layout are in
  [docs/architecture.mdx](docs/architecture.mdx#reports-logging-and-result-contracts).
- Dashboard output goes to `GuiRuns/<yyyyMMdd-HHmmss>-session-<id>/<NN>-<Task>-<id>/`. Direct maintenance
  writes to `Reports/<yyyyMMdd-HHmmss>-<id>/` by default.
- Native-tool output is saved in full, one UTF-8 file per tool. Status lines use the `[RUNNING] Step: detail`
  and `[Status] Step: detail` formats that the dashboard's activity reader parses.

## Documentation

- `README.md`: operator guide and limitations.
- `SPEC.md`: this project contract.
- `docs/architecture.mdx`: implementation reference. It uses MDX front matter but is read directly; no site
  builds it.
- `docs/Full-ScriptAnalyzer-Review.md`: analyzer policy. `docs/Dashboard-Design-Audit.md`: dashboard design
  review.
- `CONTRIBUTING.md`: contributor workflow. `AGENTS.md`: agent working rules (imported by `CLAUDE.md`).
- `CHANGELOG.md`: user-visible changes under `## Unreleased`, then per release.
- All of these are hand-written and edited directly. Nothing in the repository is generated from other
  source, except that `.agents/skills/` mirrors `.claude/skills/`.

## Agent Tooling

- Skills: `ps-project-polish`, `ps-project-features`, `ps-project-ux`, `powershell-security-review`,
  `pfc-verify`, and `pfc-release` (user-invoked only). The canonical copy is `.claude/skills/`;
  `.agents/skills/` must be identical, which `tests/AgentSkills.Tests.ps1` checks.
- Claude Code hooks (`.claude/settings.json`): `Block-LiveMaintenance.ps1` blocks maintenance commands
  without a literal enabled `-WhatIf`, and always blocks the dashboard, worker, and guided run;
  `Test-EditedScript.ps1` parses and analyzes each edited PowerShell file; `Sync-AgentSkill.ps1` mirrors
  skill edits; `Invoke-StopVerification.ps1` runs `Invoke-LocalVerify.ps1 -SkipAnalysis` before Claude stops
  when PowerShell files, settings, or skills differ from the base branch.
- Hooks are a guard on agent commands, not a sandbox, and other agent hosts do not run them.

## Testing And CI

- `pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1` runs, in order: a Windows PowerShell 5.1 parse of every
  5.1-marked file (tracked, plus new files that are not ignored), the Pester suite in a separate PowerShell 7
  process with Pester 6.2.0, and the full analyzer (up to three attempts). It prints PASS, FAIL, or SKIP per
  step and exits 0 only if no step failed. `-SkipAnalysis` skips the analyzer and is not a full pass.
- Tests use mocks, isolated files, fixture child processes, and UI fixtures. They never run real maintenance.
  Several tests extract functions from the production scripts by name.
- Analyzer policy: all 75 rules enabled, no exclusions. The release gate fails on Error-severity findings,
  unsuppressed findings outside the advisory list, and engine errors that persist after three attempts per
  file. The advisory rules are `PSAlignAssignmentStatement`, `PSAvoidLongLines`,
  `PSAvoidUsingDoubleQuotesForConstantString`, `PSPlaceCloseBrace`, `PSPlaceOpenBrace`,
  `PSProvideCommentHelp`, `PSUseBOMForUnicodeEncodedFile`, `PSUseCompatibleCommands`,
  `PSUseConstrainedLanguageMode`, `PSUseConsistentIndentation`, and `PSUseConsistentWhitespace`. Reports go to
  `ValidationReport/` (`psscriptanalyzer-full.csv`, `release-blocking.csv`, `analyzer-errors.txt`,
  `analyzer-summary.json`).
- `verify.yml` runs on `windows-latest` for pushes to `main`, pull requests to `main` and `release/**`, and
  manual dispatch, with read-only permissions and actions pinned to commit SHAs. It installs the pinned
  modules, parses the tracked 5.1 files with Windows PowerShell, runs Pester (NUnit XML to
  `test-results.xml`), runs the analyzer up to three times, and uploads the analyzer report and test results.

## Release Artifact

A release is valid only when its ZIP was built by `tools/New-ReleaseArchive.ps1` from the tagged source.
`release-archive.yml` runs when a GitHub release is published, checks that the tag equals `v` plus `VERSION`,
builds the archive, and uploads it to the release. `VERSION` changes only when a release is prepared, and
`CHANGELOG.md` records the release's behavior changes.
