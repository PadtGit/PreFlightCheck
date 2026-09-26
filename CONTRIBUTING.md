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

## Pull requests

Describe the behavior changed, the tests run, and any result or exit-code impact. Keep `report.json`, `steps.csv`, `session.log`, guided-run order, and the cleanup health gate compatible. Generated reports and local machine details should not be committed.
