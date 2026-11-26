$ErrorActionPreference = 'Stop'
$taskName = 'Informe de memoria del PC'
$scriptPath = Join-Path $PSScriptRoot 'MemoryMonitor.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "No se encuentra $scriptPath" }

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Clean -Automatic"
$triggers = @()
for ($hour = 0; $hour -lt 24; $hour++) {
    $triggers += New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($hour))
}
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$task = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description 'Diagnóstico horario de RAM, CPU y disco; limpieza diaria de temporales del usuario solo con umbrales configurados.' -Force
Write-Output "Tarea registrada para ${currentUser}: $($task.TaskName)"
Write-Output 'La tarea se ejecuta con el usuario conectado, nivel Limited, StartWhenAvailable y sin instancias simultáneas.'
