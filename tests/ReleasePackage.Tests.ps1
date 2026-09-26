[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester resolves variables assigned in BeforeAll inside later It blocks; static analysis does not follow that framework scope.')]
param()

BeforeAll {
    $repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $packageScript = Join-Path $repositoryRoot 'tools/New-ReleaseArchive.ps1'
    Add-Type -AssemblyName System.IO.Compression
}

Describe 'Release archive' {
    It 'builds under Windows PowerShell 5.1' {
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $outputRoot = Join-Path $TestDrive 'ps51'
        $output = & $windowsPowerShell -NoLogo -NoProfile -File $packageScript -OutputDirectory $outputRoot 2>&1

        $LASTEXITCODE | Should -Be 0
        $archive = @($output | Where-Object { $_ -is [string] -and $_ -like '*.zip' }) | Select-Object -Last 1
        Test-Path -LiteralPath $archive | Should -BeTrue
    }

    It 'packages runnable files under one versioned folder without tests or reports' {
        $archive = & $packageScript -OutputDirectory $TestDrive
        Test-Path -LiteralPath $archive | Should -BeTrue

        $zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $entries = @($zip.Entries | ForEach-Object FullName)
            $version = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()
            $prefix = "PreFlightCheck-$version/"
            $entries | Should -Contain "${prefix}Start-Maintenance.cmd"
            $entries | Should -Contain "${prefix}Start-Maintenance.ps1"
            $entries | Should -Contain "${prefix}Dashboard.Core.psm1"
            $entries | Should -Contain "${prefix}Invoke-GuiTask.ps1"
            $entries | Should -Contain "${prefix}PreBackupMaintenance.ps1"
            $entries | Should -Contain "${prefix}Maintenance.Core.psm1"
            $entries | Should -Contain "${prefix}README.md"
            $entries | Should -Contain "${prefix}LICENSE"
            @($entries | Where-Object { $_ -match '/(tests|Reports|GuiRuns|\.git)/' }).Count | Should -Be 0
        } finally {
            $zip.Dispose()
        }
    }
}
