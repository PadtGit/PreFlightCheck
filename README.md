# PreFlightCheck

**Clean system, smaller backup, faster restore.**

Windows 11 pre-backup maintenance toolkit — integrity checks, disk cleanup, and health reports before your Veeam job runs.

## Quick start

1. Download or clone this repository and keep all seven script/module files together.
2. Install 64-bit PowerShell 7 in its standard location (`C:\Program Files\PowerShell\7`). Windows PowerShell 5.1 is also required for the maintenance worker.
3. Double-click `Start-Maintenance.cmd` to open the dashboard. Run previews first and review the results before applying changes.

The dashboard requests Administrator permission for cleanup and Windows health work. For full VSS details, launch the dashboard as Administrator. Command-line examples below use **Windows PowerShell 5.1**, elevated for cleanup, health checks, and full diagnostics. WinGet is required for application updates.

## Features

- System review: storage, pending restart state, Windows security status, recent errors, VSS information, and temporary-file inventory.
- Cleanup: old regular files from user and Windows Temp folders, with optional Recycle Bin and Delivery Optimization cleanup.
- Windows health: DISM, SFC, and online NTFS checks, with optional repair and component cleanup.
- Application updates: preview WinGet updates and select exact application IDs.
- Dell review: attended BIOS and driver review specifically for the **Dell G5 5590**.

This initial toolkit was tailored to a Dell G5 5590. Review suitability before using it on another computer; the Dell helper rejects other models.

## Before your Veeam backup

Run maintenance during a separate quiet window, review the reports, and finish any required restart before the backup begins. This version does **not** create a schedule, start a Veeam job, or detect whether a Veeam job is running. The operator confirms that no backup or update is active. Do not use its exit code as an automatic backup veto.

## Files and reports

| File | Purpose |
| --- | --- |
| `Start-Maintenance.cmd` | Dashboard launcher |
| `Start-Maintenance.ps1` | PowerShell 7 Windows dashboard |
| `Invoke-GuiTask.ps1` | Dashboard task worker |
| `PreBackupMaintenance.ps1` | Maintenance and diagnostic routines |
| `Maintenance.Core.psm1` | Shared checks and temporary-file handling |
| `Update-Applications.ps1` | Application update helper |
| `Weekly-DellReview.ps1` | Dell G5 5590 review helper |

Dashboard results are saved under `GuiRuns/`; direct command-line runs default to `Reports/`. Generated reports can contain local paths and system information and are excluded from version control.

## Recommended order

1. Restart Windows if Windows Update or another installer is waiting for a restart.
2. Save your work, close applications, connect AC power, and make sure there is no backup or update already running.
3. Preview available application updates:

   ```powershell
   .\Update-Applications.ps1
   ```

4. Review the `AvailableAppUpdates.txt` file in the new `Reports` folder. Install only exact IDs you recognize:

   ```powershell
   .\Update-Applications.ps1 -ApplicationId Microsoft.PowerToys -Install
   ```

   Repeat `-ApplicationId` as a comma-separated list when needed. The script does not use automatic all-package updating, unknown-version updates, forced updates, agreement auto-acceptance, or automatic reboot. WinGet is for applications here; keep drivers and firmware in the Dell workflow.

5. Preview cleanup before making changes:

   ```powershell
   .\PreBackupMaintenance.ps1 -Mode Clean -WhatIf
   ```

6. If the preview is sensible, run cleanup:

   ```powershell
   .\PreBackupMaintenance.ps1 -Mode Clean -MaintenanceWindowConfirmed
   ```

   The default cleanup only removes regular files from the current user's Temp folder and Windows Temp when both their creation and modification dates are more than 14 days old. It does not follow links or delete folders. Recycle Bin and Delivery Optimization cleanup require their own switches because their contents may still be useful.

7. Run read-only Windows and file-system health checks:

   ```powershell
   .\PreBackupMaintenance.ps1 -Mode Health -MaintenanceWindowConfirmed
   ```

   If the logs report corruption, protect important data first. Then use the repair option:

   ```powershell
   .\PreBackupMaintenance.ps1 -Mode Health -RepairWindows -MaintenanceWindowConfirmed
   ```

   Component cleanup is optional and separate. It uses Microsoft's supported component cleanup operation without the irreversible base-reset option:

   ```powershell
   .\PreBackupMaintenance.ps1 -Mode Health -ComponentCleanup -MaintenanceWindowConfirmed
   ```

8. Review Dell BIOS, firmware, and driver updates separately, about once a week:

   ```powershell
   .\Weekly-DellReview.ps1
   ```

   This helper only reports the installed BIOS and opens the official Dell G5 5590 support page. It never downloads or installs firmware. Before a BIOS update, keep a verified backup, connect AC power, close applications, have the BitLocker recovery key available, and follow the instructions on the exact Dell package. Restart and verify protection afterward.

## What the report means

Each run creates a unique report folder containing `report.json`, `steps.csv`, and relevant native-tool logs. Exit code 0 means the requested routine completed without recorded warnings; 1 means a failed or unavailable essential check; 2 means review is needed. These results cannot prove that every application is healthy, that no malware exists, or that a backup is restorable. Test backup recovery separately.

Deleting files from the source may not reduce an incremental backup by the same amount, because backup retention and stored restore points still consume space. Use the script before a backup for maintenance and measurement, then use the backup application's supported retention or compact operation when older backup chains need to shrink.

## Official references

- [Microsoft WinGet upgrade documentation](https://learn.microsoft.com/en-us/windows/package-manager/winget/upgrade)
- [Microsoft component-store cleanup documentation](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11)
- [Microsoft DISM and SFC repair guidance](https://support.microsoft.com/en-us/windows/experience/backup-recovery/use-the-system-file-checker-tool-to-repair-missing-or-corrupted-system-files)
- [Microsoft CHKDSK documentation](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkdsk)
- [Dell G5 5590 drivers and downloads](https://www.dell.com/support/home/en-us/product-support/product/g-series-15-5590-laptop/drivers)
- [Dell Update end-of-life notice](https://www.dell.com/support/kbdoc/en-us/000255949/alienware-update-and-dell-update-end-of-life-eol-announcement?lang=en)
