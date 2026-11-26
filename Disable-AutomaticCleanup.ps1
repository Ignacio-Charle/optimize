$ErrorActionPreference = 'Stop'
$taskName = 'Informe de memoria del PC'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$task.Actions | ForEach-Object {
    if ($_.Arguments -notmatch 'MemoryMonitor\.ps1.*-Automatic') {
        throw "La tarea '$taskName' no coincide con esta implementación; no se modificó."
    }
}
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSScriptRoot\MemoryMonitor.ps1`" -Mode Report"
Set-ScheduledTask -TaskName $taskName -Action $action | Out-Null
Write-Output "Limpieza automática desactivada. La tarea '$taskName' conserva el informe horario."
