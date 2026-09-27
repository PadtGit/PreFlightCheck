# Bundled settings provenance

- Source: historical local `PSScriptAnalyzerSettingsFull.psd1` outside this repository (SHA-256 below identifies the original).
- Original SHA-256: `CFE75D3F012C9050D2C75EE1BDAD3A87C2204A83F8498D5433DF9731D137DF98`
- Validated dependency: PSScriptAnalyzer **1.25.0**, run with PowerShell 7.
- The original source is unchanged. The bundled asset is the single runtime settings copy.
- Changes: remove four unavailable rule blocks, correct coverage/version comments, and trim trailing
  whitespace so the asset passes PreFlightCheck's own analyzer gate (rule values unchanged).
- Removed names: `PSAvoidParameterNameConflictWithBuiltInMembers`, `PSAvoidUninitializedVariable`, `PSMissingParamArgument`, `PSMissingTypeArgument`.
- Remaining values, formatting preferences, severity selection, and compatibility targets are preserved.
- PowerShell 5.1 and 7.0–7.4 syntax targets are inherited from the source; syntax analysis is not runtime testing.
- Manually check the omitted concerns using [review guidance](security-review.md); no equivalent analyzer coverage is claimed.
- The helper checks every remaining configured name against Get-ScriptAnalyzerRule before analysis.
- Future settings/version changes require explicit maintenance and rerunning the gate tests; never edit settings just to make a reviewed project pass.
