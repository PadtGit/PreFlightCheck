# All 75 built-in rules in PSScriptAnalyzer 1.25.0.
# Compatibility profiles are bundled historical Windows baselines, not Windows 11 profiles.
# Always-enabled rules ignore Enable; configurable rules require it.
@{
    IncludeDefaultRules = $true
    IncludeRules = @('*')
    ExcludeRules = @()
    Severity = @('Error', 'Warning', 'Information')
    Rules = @{
        PSAlignAssignmentStatement = @{ Enable = $true; CheckHashtable = $true }
        PSAvoidAssignmentToAutomaticVariable = @{ Enable = $true }
        PSAvoidDefaultValueForMandatoryParameter = @{ Enable = $true }
        PSAvoidDefaultValueSwitchParameter = @{ Enable = $true }
        PSAvoidExclaimOperator = @{ Enable = $true }
        PSAvoidGlobalAliases = @{ Enable = $true }
        PSAvoidGlobalFunctions = @{ Enable = $true }
        PSAvoidGlobalVars = @{ Enable = $true }
        PSAvoidInvokingEmptyMembers = @{ Enable = $true }
        PSAvoidLongLines = @{ Enable = $true; MaximumLineLength = 120 }
        PSAvoidMultipleTypeAttributes = @{ Enable = $true }
        PSAvoidNullOrEmptyHelpMessageAttribute = @{ Enable = $true }
        PSAvoidOverwritingBuiltInCmdlets = @{ Enable = $true }
        PSAvoidReservedWordsAsFunctionNames = @{ Enable = $true }
        PSAvoidSemicolonsAsLineTerminators = @{ Enable = $true }
        PSAvoidShouldContinueWithoutForce = @{ Enable = $true }
        PSAvoidTrailingWhitespace = @{ Enable = $true }
        PSAvoidUsingAllowUnencryptedAuthentication = @{ Enable = $true }
        PSAvoidUsingBrokenHashAlgorithms = @{ Enable = $true }
        PSAvoidUsingCmdletAliases = @{ Enable = $true }
        PSAvoidUsingComputerNameHardcoded = @{ Enable = $true }
        PSAvoidUsingConvertToSecureStringWithPlainText = @{ Enable = $true }
        PSAvoidUsingDeprecatedManifestFields = @{ Enable = $true }
        PSAvoidUsingDoubleQuotesForConstantString = @{ Enable = $true }
        PSAvoidUsingEmptyCatchBlock = @{ Enable = $true }
        PSAvoidUsingInvokeExpression = @{ Enable = $true }
        PSAvoidUsingPlainTextForPassword = @{ Enable = $true }
        PSAvoidUsingPositionalParameters = @{ Enable = $true }
        PSAvoidUsingUsernameAndPasswordParams = @{ Enable = $true }
        PSAvoidUsingWMICmdlet = @{ Enable = $true }
        PSAvoidUsingWriteHost = @{ Enable = $true }
        PSDSCDscExamplesPresent = @{ Enable = $true }
        PSDSCDscTestsPresent = @{ Enable = $true }
        PSDSCReturnCorrectTypesForDSCFunctions = @{ Enable = $true }
        PSDSCStandardDSCFunctionsInResource = @{ Enable = $true }
        PSDSCUseIdenticalMandatoryParametersForDSC = @{ Enable = $true }
        PSDSCUseIdenticalParametersForDSC = @{ Enable = $true }
        PSDSCUseVerboseMessageInDSCResource = @{ Enable = $true }
        PSMisleadingBacktick = @{ Enable = $true }
        PSMissingModuleManifestField = @{ Enable = $true }
        PSPlaceCloseBrace = @{ Enable = $true; NoEmptyLineBefore = $true; IgnoreOneLineBlock = $false; NewLineAfter = $true }
        PSPlaceOpenBrace = @{ Enable = $true; OnSameLine = $false; NewLineAfter = $true; IgnoreOneLineBlock = $false }
        PSPossibleIncorrectComparisonWithNull = @{ Enable = $true }
        PSPossibleIncorrectUsageOfAssignmentOperator = @{ Enable = $true }
        PSPossibleIncorrectUsageOfRedirectionOperator = @{ Enable = $true }
        PSProvideCommentHelp = @{ Enable = $true; ExportedOnly = $false; BlockComment = $true; VSCodeSnippetCorrection = $false; Placement = 'before' }
        PSReservedCmdletChar = @{ Enable = $true }
        PSReservedParams = @{ Enable = $true }
        PSReviewUnusedParameter = @{ Enable = $true }
        PSShouldProcess = @{ Enable = $true }
        PSUseApprovedVerbs = @{ Enable = $true }
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
        PSUseCmdletCorrectly = @{ Enable = $true }
        PSUseCompatibleCmdlets = @{ Enable = $true; compatibility = @('desktop-5.1.14393.206-windows') }
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework', 'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core') }
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
        PSUseCompatibleTypes = @{ Enable = $true; TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework', 'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core') }
        PSUseConsistentIndentation = @{ Enable = $true; Kind = 'space'; IndentationSize = 4; PipelineIndentation = 'IncreaseIndentationForFirstPipeline' }
        PSUseConsistentParameterSetName = @{ Enable = $true }
        PSUseConsistentParametersKind = @{ Enable = $true }
        PSUseConsistentWhitespace = @{ Enable = $true; CheckInnerBrace = $true; CheckOpenBrace = $true; CheckOpenParen = $true; CheckOperator = $true; CheckPipe = $true; CheckPipeForRedundantWhitespace = $true; CheckSeparator = $true; CheckParameter = $true; IgnoreAssignmentOperatorInsideHashTable = $false }
        PSUseConstrainedLanguageMode = @{ Enable = $true; IgnoreSignatures = $true }
        PSUseCorrectCasing = @{ Enable = $true }
        PSUseDeclaredVarsMoreThanAssignments = @{ Enable = $true }
        PSUseLiteralInitializerForHashtable = @{ Enable = $true }
        PSUseOutputTypeCorrectly = @{ Enable = $true }
        PSUseProcessBlockForPipelineCommand = @{ Enable = $true }
        PSUsePSCredentialType = @{ Enable = $true }
        PSUseShouldProcessForStateChangingFunctions = @{ Enable = $true }
        PSUseSingleValueFromPipelineParameter = @{ Enable = $true }
        PSUseSingularNouns = @{ Enable = $true }
        PSUseSupportsShouldProcess = @{ Enable = $true }
        PSUseToExportFieldsInManifest = @{ Enable = $true }
        PSUseUsingScopeModifierInNewRunspaces = @{ Enable = $true }
        PSUseUTF8EncodingForHelpFile = @{ Enable = $true }
    }
}

