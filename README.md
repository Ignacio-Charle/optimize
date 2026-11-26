# Informe de memoria del PC

PowerShell 5.1 compatible. La ejecución manual predeterminada es solo de informe; el resultado legible se guarda en `reports\latest-report.md` y el historial JSONL rotado en `reports\history.jsonl`.

También se generan `reports/latest-report.json` (estado y métricas con unidades) y `reports/latest-report.html` (visor local autónomo, sin servidor y sin recursos externos). `latest-report.html` usa una CSP restrictiva y no ejecuta JavaScript.

## Uso

```powershell
# Informe de solo lectura (modo predeterminado)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemoryMonitor.ps1

# Simular la limpieza de temporales (nunca elimina archivos)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemoryMonitor.ps1 -Mode Simulate

# Limpieza real manual, limitada por ruta validada, edad, exclusiones y omisión de reparse points
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MemoryMonitor.ps1 -Mode Clean

# Pruebas de limpieza sobre carpetas temporales controladas
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Cleanup.Tests.ps1
```

La tarea programada usa una sola tarea para el informe horario y la limpieza automática como máximo diaria. La limpieza solo se activa si existen archivos elegibles de al menos siete días y el espacio libre del disco está en/bajo el umbral o el total de temporales elegibles alcanza su umbral. Cambia esos valores en `MemoryMonitor.config.json`. La limpieza automática solo se desactiva con `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Disable-AutomaticCleanup.ps1`; esto conserva la tarea horaria en modo solo informe. Para eliminar toda la tarea, usa `Unregister-ScheduledTask -TaskName 'Informe de memoria del PC' -Confirm:$false`.

Instala o actualiza la tarea para el usuario actual, sin elevación:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-MemoryMonitorTask.ps1
```

La tarea requiere que el usuario haya iniciado sesión; se ejecuta aunque VS Code esté cerrado. `StartWhenAvailable` permite recuperar ejecuciones perdidas al volver a estar disponible el equipo. Las notificaciones de Windows están desactivadas por defecto; al activarlas, solo se intentan para alertas persistentes de RAM o disco.

## Límites P0 de limpieza

Por defecto ninguna ejecución limpia archivos. `-Mode Clean` requiere además `-CleanupEnabled` o `CleanupEnabled=true` en `MemoryMonitor.config.json`. Una ejecución automática sólo escribe en el directorio dedicado `<LOCALAPPDATA>\WindowsMemoryMonitor`, configurable como nombre simple. La limpieza general de `%TEMP%` queda fuera de la automatización horaria y sólo puede inspeccionarse con herramientas o pruebas locales.

Los límites iniciales son: 7 días, 500 elementos inspeccionados, 100 eliminaciones, 256 MiB de tamaño lógico acumulado y 10 segundos de presupuesto objetivo. `-WhatIf` genera la vista previa sin borrar. Toda operación revalida el candidato y los ancestros literales. Hay una ventana de carrera si otro proceso sustituye una ruta después de la comprobación; por eso una tarea sobre temporales modificables por terceros debe seguir simulada hasta disponer de una API atómica adecuada.
