[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester resolves fixture variables assigned in BeforeAll in later It blocks.')]
param()

Describe 'Opened temporary file validation' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Maintenance.Core.psm1') -Force
        InModuleScope Maintenance.Core { Initialize-TemporaryFileNativeType }
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('PreFlightCheck-Handle-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($fixture)
        $root = Join-Path $fixture 'root'
        [void][IO.Directory]::CreateDirectory($root)
        $old = Join-Path $root 'old.tmp'
        $outside = Join-Path $fixture 'outside.tmp'
        $recent = Join-Path $root 'recent.tmp'
        [IO.File]::WriteAllText($old, 'old fixture')
        [IO.File]::WriteAllText($outside, 'outside fixture')
        [IO.File]::WriteAllText($recent, 'recent fixture')
        $oldDate = [DateTime]::UtcNow.AddDays(-30)
        foreach ($path in @($old, $outside)) {
            [IO.File]::SetCreationTimeUtc($path, $oldDate)
            [IO.File]::SetLastWriteTimeUtc($path, $oldDate)
        }
        $cutoff = [DateTime]::UtcNow.AddDays(-14)
    }

    AfterAll {
        if ($fixture -and [IO.Directory]::Exists($fixture)) {
            Remove-Item -LiteralPath $fixture -Recurse -Force
        }
        Remove-Module Maintenance.Core -Force -ErrorAction SilentlyContinue
    }

    It 'reads eligible size through the opened handle without deleting the file' {
        [PreBackup.NativeFile]::GetValidatedLength($root, $old, $cutoff) | Should -Be 11
        [IO.File]::Exists($old) | Should -BeTrue
    }

    It 'rejects a recent replacement at a previously selected path' {
        $replacement = Join-Path $root 'replacement.tmp'
        [IO.File]::WriteAllText($replacement, 'selected old file')
        [IO.File]::SetCreationTimeUtc($replacement, $oldDate)
        [IO.File]::SetLastWriteTimeUtc($replacement, $oldDate)
        @(Get-AgedTemporaryFile -Root $root).Path | Should -Contain $replacement
        [IO.File]::Delete($replacement)
        [IO.File]::WriteAllText($replacement, 'recent replacement')
        [IO.File]::SetCreationTimeUtc($replacement, [DateTime]::UtcNow)

        [PreBackup.NativeFile]::GetValidatedLength($root, $replacement, $cutoff) | Should -Be -1
        [IO.File]::ReadAllText($replacement) | Should -Be 'recent replacement'
    }

    It 'rejects files outside the root and directories' {
        $directory = Join-Path $root 'directory'
        [void][IO.Directory]::CreateDirectory($directory)
        [PreBackup.NativeFile]::GetValidatedLength($root, $outside, $cutoff) | Should -Be -1
        [PreBackup.NativeFile]::GetValidatedLength($root, $root, $cutoff) | Should -Be -1
        [PreBackup.NativeFile]::GetValidatedLength($root, $directory, $cutoff) | Should -Be -1
    }

    It 'rejects a changed creation or modification time' {
        [PreBackup.NativeFile]::GetValidatedLength($root, $recent, $cutoff) | Should -Be -1
        [IO.File]::SetLastWriteTimeUtc($recent, $oldDate)
        [PreBackup.NativeFile]::GetValidatedLength($root, $recent, $cutoff) | Should -Be -1
        [IO.File]::SetCreationTimeUtc($recent, $oldDate)
        [IO.File]::SetLastWriteTimeUtc($recent, [DateTime]::UtcNow)
        [PreBackup.NativeFile]::GetValidatedLength($root, $recent, $cutoff) | Should -Be -1
    }

    It 'refuses a file with an active writer and releases all parent handles' {
        $writer = [IO.File]::Open($old, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            { [PreBackup.NativeFile]::GetValidatedLength($root, $old, $cutoff) } | Should -Throw
        } finally { $writer.Dispose() }
        $renamed = Join-Path $fixture 'renamed-root'
        [IO.Directory]::Move($root, $renamed)
        [IO.Directory]::Move($renamed, $root)
        [PreBackup.NativeFile]::GetValidatedLength($root, $old, $cutoff) | Should -Be 11
    }

    It 'refuses an ancestor junction substituted after enumeration' {
        $parent = Join-Path $root 'parent'
        [void][IO.Directory]::CreateDirectory($parent)
        $selected = Join-Path $parent 'outside.tmp'
        [IO.File]::WriteAllText($selected, 'old candidate')
        [IO.File]::SetCreationTimeUtc($selected, $oldDate)
        [IO.File]::SetLastWriteTimeUtc($selected, $oldDate)
        @(Get-AgedTemporaryFile -Root $root).Path | Should -Contain $selected
        Remove-Item -LiteralPath $parent -Recurse -Force
        [void](New-Item -ItemType Junction -Path $parent -Target $fixture)
        try {
            [PreBackup.NativeFile]::GetValidatedLength($root, $selected, $cutoff) | Should -Be -1
            [IO.File]::ReadAllText($outside) | Should -Be 'outside fixture'
        } finally { Remove-Item -LiteralPath $parent -Force }
    }
}

Describe 'Temporary cleanup uses native validation results' {
    BeforeAll { Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Maintenance.Core.psm1') -Force }
    AfterAll { Remove-Module Maintenance.Core -Force -ErrorAction SilentlyContinue }

    It 'counts a native rejection as skipped and uses the opened file size for accepted candidates' {
        InModuleScope Maintenance.Core {
            Mock Get-AgedTemporaryFile { @(
                [pscustomobject]@{ Path = 'C:\fixture\root\changed.tmp'; Bytes = 99 },
                [pscustomobject]@{ Path = 'C:\fixture\root\old.tmp'; Bytes = 99 }
            ) }
            Mock Test-ContainedRegularPath { $true }
            Mock Get-Item { [pscustomobject]@{ FullName = [string]$LiteralPath[0]; PSIsContainer = $false; LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-30); CreationTimeUtc = [DateTime]::UtcNow.AddDays(-30); Length = 99 } }
            Mock Remove-TemporaryFileByHandle { if ($Path -like '*changed.tmp') { -1L } else { 11L } }

            $result = Remove-AgedTemporaryFile -Root 'C:\fixture\root' -Confirm:$false

            $result.Deleted | Should -Be 1
            $result.Skipped | Should -Be 1
            $result.LogicalBytesDeleted | Should -Be 11
            Should -Invoke Remove-TemporaryFileByHandle -Times 2 -Exactly -ParameterFilter { $Root -eq 'C:\fixture\root' -and $CutoffUtc -lt [DateTime]::UtcNow.AddDays(-13) }
        }
    }
}
