$ErrorActionPreference = 'Stop'
$taskName = 'Informe de memoria del PC'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$legacyOwned = @($task.Actions | Where-Object { $_.Arguments -match 'MemoryMonitor\.ps1.*-Automatic' }).Count -gt 0
$markerOwned = $task.Description -eq 'WindowsMemoryMonitor managed task v1'
if (-not $markerOwned -and -not $legacyOwned) { throw "Conflicto: la tarea '$taskName' no está identificada como propia. No se modificó." }
$task.Actions | ForEach-Object {
    if ($_.Arguments -notmatch 'MemoryMonitor\.ps1.*-Automatic') {
        throw "La tarea '$taskName' no coincide con esta implementación; no se modificó."
    }
}
$hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $hostPath -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSScriptRoot\MemoryMonitor.ps1`" -Mode Report" -WorkingDirectory $PSScriptRoot
Set-ScheduledTask -TaskName $taskName -Action $action | Out-Null
Write-Output "Limpieza automática desactivada. La tarea '$taskName' conserva el informe horario."
