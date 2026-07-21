# Arranca el dashboard de publicación ELEVADO (admin), necesario SOLO para ejecutar
# un Publish en local (dev-joaquim-local). El dashboard "siempre activo" (tarea
# programada 'Publish Dashboard') corre sin privilegios a propósito, y con eso basta
# para ver estado/semáforos y para disparar los deploy remotos por GitLab.
#
# Uso: doble clic en dashboard-admin.cmd (o ejecutar este .ps1). Se auto-eleva por UAC.
# Al cerrar la ventana, la instancia normal vuelve en el próximo inicio de sesión
# (o reiníciala ya con:  Start-ScheduledTask -TaskName 'Publish Dashboard').

$ErrorActionPreference = 'Stop'
$server = Join-Path $PSScriptRoot 'server.py'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevando por UAC..." -ForegroundColor Yellow
    $host_exe = (Get-Process -Id $PID).Path   # powershell.exe o pwsh.exe
    Start-Process -FilePath $host_exe -Verb RunAs -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    return
}

# Ya elevado: liberar el puerto parando SOLO la instancia del dashboard (no otros python).
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" |
    Where-Object { $_.CommandLine -match 'dashboard\\server\.py' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "Dashboard ELEVADO en http://localhost:8765  (Ctrl+C para salir)" -ForegroundColor Green
Write-Host "Ahora el botón Publish de dev-joaquim-local ya puede publicar en local." -ForegroundColor Gray
& (Get-Command python).Source $server 8765
