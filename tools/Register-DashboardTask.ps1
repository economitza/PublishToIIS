# Registra la tarea 'Publish Dashboard': arranca el dashboard con Windows (al
# iniciar sesion), HEADLESS con pythonw (sin ventana de consola) y SIN privilegios.
# El dashboard es un cliente puro: solo toca los endpoints, nunca publica ni eleva,
# asi que no necesita consola viva ni administrador. La elevacion solo hace falta
# para registrar la tarea (una vez).
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string]$TaskName = 'Publish Dashboard',
    [string]$PythonExe
)
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$server = Join-Path $repo 'dashboard\server.py'
if (-not (Test-Path $server)) { throw "No se encontro $server." }

if (-not $PythonExe) {
    # pythonw = sin ventana (headless). Si no hay, python normal.
    $py = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python.exe -ErrorAction SilentlyContinue }
    if (-not $py) { throw 'No se encontro pythonw/python en el PATH. Pasa -PythonExe.' }
    $PythonExe = $py.Source
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Elevando por UAC (solo para registrar; el dashboard correra SIN privilegios)...' -ForegroundColor Yellow
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
             '-Port', $Port, '-TaskName', "`"$TaskName`"", '-PythonExe', "`"$PythonExe`"")
    Start-Process powershell -Verb RunAs -ArgumentList $fwd
    return
}

# Parar cualquier dashboard suelto (la consola vieja) para liberar el puerto.
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" |
    Where-Object { $_.CommandLine -match 'dashboard\\server\.py' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$action = New-ScheduledTaskAction -Execute $PythonExe -Argument "`"$server`" $Port"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
# SIN privilegios (RunLevel Limited): el dashboard solo consulta y toca endpoints.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description "PublishToIIS: dashboard cliente (sin privilegios, headless) en http://localhost:$Port" -Force | Out-Null
Write-Host "Tarea '$TaskName' registrada (al iniciar sesion, SIN privilegios, headless)." -ForegroundColor Green

Start-ScheduledTask -TaskName $TaskName
Write-Host "Dashboard arrancado en http://localhost:$Port (sin consola). Ya no depende de una ventana abierta." -ForegroundColor Gray
