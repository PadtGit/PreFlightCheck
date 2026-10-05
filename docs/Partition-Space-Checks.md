# Partition space checks

`PreBackupMaintenance.ps1` collects volume and physical-disk inventory, then reads
partition access paths and GPT type identifiers with `Get-Partition`. The read-only
`Get-VolumeSpaceAssessment` function in `Maintenance.Core.psm1` matches each fixed
volume's `UniqueId` to exactly one partition's `AccessPaths`. It does not infer
purpose from a label, missing drive letter, or filesystem alone.

| Partition type | Free-space threshold | Meaning |
| --- | --- | --- |
| EFI (`c12a7328-f81f-11d2-ba4b-00a0c93ec93b`) | 50 MiB | Project caution threshold for limited headroom, not a Microsoft update requirement. |
| Windows recovery (`de94bba4-06d1-4d40-a16a-bfd50179d6ac`) | 250 MiB | Allowance for Windows RE servicing; low space does not establish image corruption or backup failure. |
| Ordinary data or unresolved purpose | 1 GiB | Existing project caution threshold; backup-job requirements still need review. |

Comparisons use bytes before display rounding: exactly the threshold passes the
space comparison. PowerShell's `MB` and `GB` constants are binary, so messages use
MiB and GiB. The 250 MiB allowance conservatively implements Microsoft's 250 MB
servicing guidance. Capacity and free space come from the filesystem inventory;
filesystem capacity can be slightly smaller than total partition size.

Missing, zero-sized, negative, nonnumeric, or inconsistent measurements produce
`Review`. EFI with a filesystem other than FAT32 and recovery with a filesystem
other than NTFS also require review. Ambiguous or absent partition mappings never
qualify for the smaller thresholds. A partition enumeration error produces a
`Storage` failure. Non-fixed volumes are outside this assessment.

Each assessment uses the existing `Space` result with `Status` and `Detail`;
`Add-Result` adds the normal timestamp and step. EFI and recovery observations stay
in `report.json` and `steps.csv` even when they do not request review. No report
schema, event classification, exit-code mapping, or cleanup gate changes are
required. Every review or failure still blocks cleanup. This check does not
identify the active WinRE image, certify future update or backup success, or
mount, resize, repair, or delete anything on these partitions.

## Sources and limits

- [Microsoft UEFI/GPT partition guidance](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions?view=windows-11)
  separates total EFI capacity requirements from the additional free space needed
  for WinRE servicing. Deployment sizing guidance is not a blanket free-space
  requirement for existing EFI partitions.
- [Microsoft recovery tools requirements](https://learn.microsoft.com/en-us/troubleshoot/windows-client/windows-security/disk-partition-requirement-use-windows-re-tool)
  distinguishes modern Windows requirements from older 50/320 MiB and 1 GiB rules.
- [Microsoft GPT type definitions](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-partition_information_gpt)
  define distinct EFI, recovery, and basic-data partition identifiers.
- [Veeam Agent backup processing](https://helpcenter.veeam.com/docs/agentforwindows/userguide/backup_hiw.html)
  states that EFI partitions on GPT disks do not receive VSS snapshots. NTFS
  snapshot-space advice must not be assumed to define an EFI free-space minimum.

The EFI 50 MiB value is an explicit project policy, not a universal threshold
published by Microsoft or Veeam. No extra operator setting is required.

## Verification

`tests/VolumeSpace.Tests.ps1` exercises classification, byte boundaries, invalid
measurements, and the production storage block using isolated fixtures and mocked
inventory commands. `tests/Correctness.Tests.ps1` checks that recovery and event
reviews still block every cleanup action, while an EFI observation alone does not.
Run the focused tests and then `pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1`.
Never run real maintenance to test this behavior.
