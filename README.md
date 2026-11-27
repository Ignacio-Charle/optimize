# Windows Resource Monitor

[![Windows tests](https://github.com/Ignacio-Charle/optimize/actions/workflows/ci.yml/badge.svg)](https://github.com/Ignacio-Charle/optimize/actions/workflows/ci.yml)

A local Windows 11 monitor for RAM, CPU, and disk usage, with a local history and opt-in cleanup. Compatible with Windows PowerShell 5.1.

## Output files

- `reports/latest-report.md`: human-readable report.
- `reports/latest-report.json`: structured metrics with explicit units and collector status.
- `reports/latest-report.html`: standalone, responsive viewer with no JavaScript or external resources.
- `reports/history.jsonl`: rotated local history; excluded from Git.

The default run only creates or updates monitor-owned reports. It does not delete files.

## Usage

```powershell
# Read-only report (default)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemoryMonitor.ps1

# Simulate cleanup; never deletes files
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemoryMonitor.ps1 -Mode Simulate

# Manual cleanup, limited to the validated dedicated directory
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemoryMonitor.ps1 -Mode Clean

# Preview cleanup without deleting
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemoryMonitor.ps1 -Mode Clean -WhatIf

# Run cleanup tests against controlled temporary fixtures
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Cleanup.Tests.ps1
```

The scheduled task runs one hourly report and performs cleanup at most once per day. Automatic cleanup requires eligible files at least seven days old and either low disk space or eligible temporary files reaching the configured size threshold. Change thresholds in `MemoryMonitor.config.json`.

Disable automatic cleanup while keeping the hourly report:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Disable-AutomaticCleanup.ps1
```

Remove the scheduled task with:

```powershell
Unregister-ScheduledTask -TaskName 'Informe de memoria del PC' -Confirm:$false
```

Install or update the task for the current user without elevation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-MemoryMonitorTask.ps1
```

The task runs as the interactive current user, at Limited run level, with `StartWhenAvailable` and `IgnoreNew` for concurrent instances. The user must be signed in. It can run while VS Code is closed. Windows notifications are disabled by default; when enabled, they are only attempted for persistent RAM or disk alerts.

## Cleanup safety

Cleanup is disabled by default. `-Mode Clean` also requires the explicit `-CleanupEnabled` switch or `CleanupEnabled=true` in the configuration. Automatic cleanup is limited to `<LOCALAPPDATA>\WindowsMemoryMonitor`; `CleanupRootName` may only be a simple directory name. General `%TEMP%` cleanup is not part of the scheduled workflow.

Default limits: 7 days old, 500 inspected entries, 100 deletions, 256 MiB total logical file size, and a 10-second inspection budget. `-WhatIf` previews without deleting. The script revalidates the root and every candidate immediately before deletion. A race remains if another process replaces a path after validation; do not enable cleanup on trees that can be modified by untrusted processes.

The deleted-byte total is a logical file-size estimate, not a measurement of actual disk-space reclaimed. Disk free space is reported separately as an observation.
