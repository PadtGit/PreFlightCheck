# Full PSScriptAnalyzer review

Run from the repository using PowerShell 7:

```powershell
./tools/Invoke-FullScriptAnalysis.ps1
```

Install PSScriptAnalyzer 1.25.0 first. GitHub installs that exact version.

The settings select all 75 built-in rules returned by that version, explicitly enable
configurable rules, exclude no rules, and include Error, Warning, and Information.
The runner includes suppressed diagnostics and checks all Git-tracked and
non-ignored new .ps1, .psm1, and .psd1 files, including tests and the analysis
runner itself. It fails the release gate for analyzer engine errors, Error-severity
diagnostics, and unsuppressed correctness findings outside the documented advisory
rule set. Formatting, historical compatibility-profile, Constrained Language Mode,
encoding, and documentation diagnostics remain visible in the full audit without
blocking a release.

Reports are saved in ValidationReport: psscriptanalyzer-full.csv,
release-blocking.csv, analyzer-errors.txt, and analyzer-summary.json. GitHub uploads
these even when the analysis step fails, as the psscriptanalyzer-full-review
artifact. A zero-row release-blocking.csv means that the analyzer release gate
passed; it does not mean that the advisory audit is empty.

## Compatibility and interpretation

Syntax is checked against 5.1 and 7.0. Command/type checks use the bundled Windows
5.1 and 7.0 reference profiles; the legacy cmdlet checker uses its Windows 5.1
profile. These historical profiles are not complete inventories of Windows 11 or
newer PowerShell 7 releases. Findings must be reviewed against the actual runtime
of each script. Unknown third-party commands and types are not proof of compatibility.

Constrained Language Mode checks are enabled, with signature exemptions disabled.
The Windows Forms dashboard and native C# helpers currently require Full Language
Mode. CLM findings therefore document a real restriction of those features; enabling
the rule does not make the application CLM-compatible.

The supplied external settings file was used as a reference and left unchanged.
Four names in it are not rules in 1.25.0: PSAvoidUninitializedVariable,
PSMissingParamArgument, PSMissingTypeArgument, and
PSAvoidParameterNameConflictWithBuiltInMembers. Missing mandatory command arguments
are covered where possible by actual built-in rules such as PSUseCmdletCorrectly.
Static analysis cannot prove runtime correctness or replace Pester and Windows tests.

## Microsoft references

- [Rule list and default states](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/readme?view=ps-modules)
- [Using ScriptAnalyzer](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/using-scriptanalyzer?view=ps-modules)
- [Compatibility cmdlet profiles](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/usecompatiblecmdlets?view=ps-modules)
- [Constrained Language Mode checks](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/useconstrainedlanguagemode?view=ps-modules)


