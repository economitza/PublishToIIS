# Registra el carril de refresco de BD: la tarea elevada 'Publish DbRefresh' (ejecuta
# Run-PublishOrder.ps1 -Lane dbrefresh) y su drenador 'Publish DbRefresh Drainer'. Así
# un refresco, que copia la BD entera y puede tardar horas, no ocupa la tarea ni la
# cola de las publicaciones.
#
# Cada tarea nueva se registra con la MISMA identidad que su pareja del carril de
# publicación ('Publish Local' y 'Publish Queue Drainer'): quien puede publicar en
# esta máquina puede refrescar, y nadie más. Sin 'Publish Local' no hay nada que
# registrar. Lo ejecuta Install.ps1 (y por tanto cada Update-PublishToIIS), elevado.
#
#   .\Register-DbRefreshTasks.ps1          # registra lo que falte
#   .\Register-DbRefreshTasks.ps1 -Force   # vuelve a registrar las dos
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'

$publishLocal = Get-ScheduledTask -TaskName 'Publish Local' -ErrorAction SilentlyContinue
if (-not $publishLocal) {
    Write-Host "Sin tarea 'Publish Local' en esta máquina: no hay carril de refresco que registrar." -ForegroundColor Gray
    return
}
$publishDrainer = Get-ScheduledTask -TaskName 'Publish Queue Drainer' -ErrorAction SilentlyContinue

$runScript = Join-Path $PSScriptRoot 'Run-PublishOrder.ps1'
$drainerScript = Join-Path $PSScriptRoot 'Start-DeployQueueDrainer.ps1'

if ($Force -or -not (Get-ScheduledTask -TaskName 'Publish DbRefresh' -ErrorAction SilentlyContinue)) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runScript`" -Lane dbrefresh"
    # Un refresco suele tardar minutos; el límite es solo la red por si se cuelga.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName 'Publish DbRefresh' -Action $action -Principal $publishLocal.Principal `
        -Settings $settings -Description 'PublishToIIS: refresca la BD de un entorno de test (orden de %ProgramData%\PublishToIIS\dbrefresh-order.json)' -Force | Out-Null
    Write-Host "Tarea 'Publish DbRefresh' registrada (misma identidad que 'Publish Local')." -ForegroundColor Green
}

if (-not $publishDrainer) {
    Write-Host "Sin tarea 'Publish Queue Drainer': el drenador del refresco no se registra y los refrescos siguen yendo por la cola de publicaciones." -ForegroundColor Gray
    return
}
if ($Force -or -not (Get-ScheduledTask -TaskName 'Publish DbRefresh Drainer' -ErrorAction SilentlyContinue)) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$drainerScript`" -Lane dbrefresh"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances Queue
    Register-ScheduledTask -TaskName 'Publish DbRefresh Drainer' -Action $action -Principal $publishDrainer.Principal `
        -Settings $settings -Description 'PublishToIIS: drena la cola de refrescos de BD bajo demanda llamando a Publish DbRefresh' -Force | Out-Null
    Write-Host "Tarea 'Publish DbRefresh Drainer' registrada (misma identidad que 'Publish Queue Drainer')." -ForegroundColor Green
}
