[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester and extracted production blocks consume fixture variables in child scopes.')]
param()

BeforeAll {
    $repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repositoryRoot 'Maintenance.Core.psm1') -Force
    $efiType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $dataType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $volumeId = '\\?\Volume{11111111-1111-1111-1111-111111111111}\'
    $maintenanceAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repositoryRoot 'PreBackupMaintenance.ps1'), [ref]$null, [ref]$null)
    $storageNode = $maintenanceAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.TryStatementAst] -and
        $node.Body.Extent.Text -match '^\{\s*# Read-only storage modules'
    }, $true)
    $storageBlock = [scriptblock]::Create($storageNode.Extent.Text)
    $resultNode = $maintenanceAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Add-Result'
    }, $true)
    . ([scriptblock]::Create($resultNode.Extent.Text))
}

Describe 'Partition-aware space assessment' {
    BeforeEach {
        $volume = [pscustomobject]@{
            UniqueId = $volumeId; DriveLetter = $null; DriveType = 'Fixed'
            FileSystem = 'FAT32'; Size = 200MB; SizeRemaining = 162MB; HealthStatus = 'Healthy'
        }
        $partition = [pscustomobject]@{ AccessPaths = @($volumeId); GptType = $efiType }
    }

    It 'keeps a small EFI volume visible without the ordinary-volume warning' {
        $result = Get-VolumeSpaceAssessment -Volume $volume -Partitions @($partition)
        $result.Status | Should -Be 'Observed'
        $result.Detail | Should -Match 'EFI.*162.*200.*MiB'
        $result.Detail | Should -Match 'project caution'
    }

    It 'warns about recovery servicing space for the reported small recovery volume' {
        $partition.GptType = $recoveryType
        $volume.FileSystem = 'NTFS'; $volume.Size = 787MB; $volume.SizeRemaining = 115MB
        $result = Get-VolumeSpaceAssessment -Volume $volume -Partitions @($partition)
        $result.Status | Should -Be 'Review'
        $result.Detail | Should -Match 'Recovery.*115'
        $result.Detail | Should -Match 'servicing.*250'
    }

    It 'uses an exact byte boundary for <Role> at offset <Offset>' -ForEach @(
        @{ Role = 'Efi'; Threshold = 50MB; Offset = -1; Expected = 'Review' }
        @{ Role = 'Efi'; Threshold = 50MB; Offset = 0; Expected = 'Observed' }
        @{ Role = 'Efi'; Threshold = 50MB; Offset = 1; Expected = 'Observed' }
        @{ Role = 'Recovery'; Threshold = 250MB; Offset = -1; Expected = 'Review' }
        @{ Role = 'Recovery'; Threshold = 250MB; Offset = 0; Expected = 'Observed' }
        @{ Role = 'Recovery'; Threshold = 250MB; Offset = 1; Expected = 'Observed' }
        @{ Role = 'Data'; Threshold = 1GB; Offset = -1; Expected = 'Review' }
        @{ Role = 'Data'; Threshold = 1GB; Offset = 0; Expected = 'Observed' }
        @{ Role = 'Data'; Threshold = 1GB; Offset = 1; Expected = 'Observed' }
    ) {
        $partition.GptType = switch ($Role) { Efi { $efiType } Recovery { $recoveryType } Data { $dataType } }
        if ($Role -ne 'Efi') { $volume.FileSystem = 'NTFS' }
        $volume.Size = 2GB; $volume.SizeRemaining = $Threshold + $Offset
        (Get-VolumeSpaceAssessment -Volume $volume -Partitions @($partition)).Status | Should -Be $Expected
    }

    It 'does not mistake a hidden FAT32 data volume for EFI' {
        $partition.GptType = $dataType
        (Get-VolumeSpaceAssessment -Volume $volume -Partitions @($partition)).Status | Should -Be 'Review'
    }

    It 'accepts a type GUID without braces and a case-insensitive volume path' {
        $partition.GptType = $efiType.Trim('{}').ToUpperInvariant()
        $partition.AccessPaths = @('S:\', $volumeId.ToUpperInvariant())
        (Get-VolumeSpaceAssessment -Volume $volume -Partitions @($partition)).Status | Should -Be 'Observed'
    }

    It 'keeps the ordinary threshold when classification is <Case>' -ForEach @(
        @{ Case = 'missing' }; @{ Case = 'ambiguous' }; @{ Case = 'unknown' }
    ) {
        $partitions = @()
        if ($Case -eq 'ambiguous') { $partitions = @($partition, $partition) }
        if ($Case -eq 'unknown') { $partition.GptType = 'not-a-guid'; $partitions = @($partition) }
        $result = Get-VolumeSpaceAssessment -Volume $volume -Partitions $partitions
        $result.Status | Should -Be 'Review'
        $result.Detail | Should -Match 'unresolved'
    }

    It 'does not certify invalid measurements: <Case>' -ForEach @(
        @{ Case = 'missing free'; Size = 200MB; Free = $null }
        @{ Case = 'missing size'; Size = $null; Free = 50MB }
        @{ Case = 'zero size'; Size = 0; Free = 0 }
        @{ Case = 'negative free'; Size = 200MB; Free = -1 }
        @{ Case = 'free exceeds size'; Size = 200MB; Free = 201MB }
        @{ Case = 'not numeric'; Size = 200MB; Free = 'unknown' }
    ) {
        $volume.Size = $Size; $volume.SizeRemaining = $Free
        $result = Get-VolumeSpaceAssessment -Volume $volume -Partitions @($partition)
        $result.Status | Should -Be 'Review'
        $result.Detail | Should -Match 'unavailable|invalid'
    }

    It 'does not grant an EFI exception for an unexpected filesystem' {
        $volume.FileSystem = 'RAW'
        (Get-VolumeSpaceAssessment -Volume $volume -Partitions @($partition)).Status | Should -Be 'Review'
    }

    It 'excludes removable media from the fixed-volume assessment' {
        $volume.DriveType = 'Removable'
        @(Get-VolumeSpaceAssessment -Volume $volume -Partitions @($partition)).Count | Should -Be 0
    }
}

Describe 'Storage report integration' {
    BeforeAll {
        # Avoid Pester proxy generation for Storage's dynamic CIM enum parameters.
        function Get-PhysicalDisk { throw 'Storage fixture must mock Get-PhysicalDisk.' }
    }
    BeforeEach {
        $script:report = [pscustomobject]@{
            Results = [Collections.Generic.List[object]]::new(); VolumesBefore = @(); Disks = @()
        }
        $script:partitionQueryFails = $false
        Mock Get-Volume {
            [pscustomobject]@{ UniqueId = $volumeId; DriveLetter = $null; DriveType = 'Fixed'
                FileSystem = 'FAT32'; Size = 200MB; SizeRemaining = 162MB; HealthStatus = 'Healthy' }
        }
        Mock Get-PhysicalDisk { [pscustomobject]@{ FriendlyName = 'Fixture SSD'; MediaType = 'SSD'; HealthStatus = 'Healthy'; OperationalStatus = 'OK' } }
        Mock Get-Partition {
            if ($script:partitionQueryFails) { throw 'Fixture partition inventory unavailable' }
            [pscustomobject]@{ AccessPaths = @($volumeId); GptType = $efiType }
        }
    }

    It 'records the EFI observation through the real storage block even under WhatIf' {
        $WhatIfPreference = $true
        . $storageBlock
        $WhatIfPreference | Should -BeTrue
        @($report.Results | Where-Object { $_.Status -eq 'Review' }).Count | Should -Be 0
        @($report.Results | Where-Object { $_.Step -eq 'Space' -and $_.Status -eq 'Observed' }).Count | Should -Be 1
        $report.VolumesBefore.Count | Should -Be 1
    }

    It 'records a blocking failure if partition inventory cannot be read' {
        $script:partitionQueryFails = $true
        . $storageBlock
        @($report.Results | Where-Object { $_.Step -eq 'Storage' -and $_.Status -eq 'Failed' }).Count | Should -Be 1
    }
}
