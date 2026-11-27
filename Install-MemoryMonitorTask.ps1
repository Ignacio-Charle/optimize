$ErrorActionPreference = 'Stop'
$taskName = 'Informe de memoria del PC'
$scriptPath = Join-Path $PSScriptRoot 'MemoryMonitor.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Script not found: $scriptPath" }

$taskMarker = 'WindowsMemoryMonitor managed task v1'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    $owned = $existing.Description -eq $taskMarker
    $hasOwnAction = @($existing.Actions | Where-Object {
        $_.Execute -ieq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -and
        $_.Arguments -match 'MemoryMonitor\.ps1'
    }).Count -gt 0
    if (-not $owned -and -not $hasOwnAction) {
        throw "Conflict: '$taskName' exists but cannot be identified as managed by this tool. It was not changed."
    }
}

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$workingDirectory = $PSScriptRoot
$action = New-ScheduledTaskAction -Execute $hostPath -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Clean -Automatic" -WorkingDirectory $workingDirectory
$triggers = @()
for ($hour = 0; $hour -lt 24; $hour++) {
    $triggers += New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($hour))
}
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$task = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description $taskMarker -Force
Write-Output "Task registered for ${currentUser}: $($task.TaskName)"
Write-Output 'The task runs as the signed-in user at Limited run level, starts when available, and ignores concurrent instances.'
