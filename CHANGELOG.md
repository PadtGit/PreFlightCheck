# Changelog

## 0.2.0 - P0 safety verification

- Added isolated Pester coverage for the pre-backup safety contract.
- Added GitHub Actions verification on Windows with pinned Pester and PSScriptAnalyzer versions.
- Added explicit checks that the default workflow does not delete shadow copies or reset the Windows Update cache.
- Added verification for `ShouldProcess`, `-WhatIf`, terminating orchestration errors, native exit-code handling, AC-line detection, and reparse-point-aware cleanup.
- Kept the existing safe `Audit` default and explicit cleanup/repair modes.

## 0.3.0 - 2026-09-20

- Updated the GitHub Actions test dependency from Pester 5.7.1 to Pester 6.2.0.
- Added a separate WinUtil-style System Corruption Scan action while keeping the existing Windows Health workflow.
- Added distinct WinGet actions for install/upgrade, uninstall, upgrade-all, installed-app listing, and clearing selection.
- Corrected selected-package WinGet arguments and rejected empty uninstall selections.
- Rechecked restart state after upgrade-all and surfaced installed-app output in dashboard results.
- Preserved the complete 75-rule analyzer audit while limiting the release gate to engine errors and actionable correctness findings.


