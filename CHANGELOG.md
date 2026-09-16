# Changelog

## 0.2.0 - P0 safety verification

- Added isolated Pester coverage for the pre-backup safety contract.
- Added GitHub Actions verification on Windows with pinned Pester and PSScriptAnalyzer versions.
- Added explicit checks that the default workflow does not delete shadow copies or reset the Windows Update cache.
- Added verification for `ShouldProcess`, `-WhatIf`, terminating orchestration errors, native exit-code handling, AC-line detection, and reparse-point-aware cleanup.
- Kept the existing safe `Audit` default and explicit cleanup/repair modes.
