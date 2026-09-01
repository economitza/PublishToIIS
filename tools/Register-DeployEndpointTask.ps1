# Registra (una sola vez, requiere elevación por UAC) la tarea programada
# 'Publish Endpoint': arranca el listener HTTP del endpoint de despliegue al
# iniciarse el servidor y lo relanza si muere. El listener corre SIN privilegios
# (RunLevel Limited) a propósito: lo único que hace es escribir la orden y
# disparar la tarea elevada 'Publish Local', que es quien publica.
#
# La elevacion se necesita para: registrar la tarea, reservar la URL ACL del
# puerto de loopback (imprescindible para que un proceso sin privilegios pueda
# escuchar) y generar el token si no existe.
#
#   .\Register-DeployEndpointTask.ps1              # puerto 8770 por defecto
#   .\Register-DeployEndpointTask.ps1 -Port 8771
[CmdletBinding()]
param(
    [int]$Port = 8770,
    [string]$TaskName = 'Publish Endpoint',
    [string]$DrainerTaskName = 'Publish Queue Drainer',
    [string]$PublishTaskName = 'Publish Local'
)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Elevando por UAC...' -ForegroundColor Yellow
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
             '-Port', $Port, '-TaskName', "`"$TaskName`"", '-DrainerTaskName', "`"$DrainerTaskName`"",
             '-PublishTaskName', "`"$PublishTaskName`"")
    Start-Process powershell -Verb RunAs -ArgumentList $fwd
    return
}

Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

$dataDir = Join-Path $env:ProgramData 'PublishToIIS'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

# Misma concesion que en Register-PublishLocalTask: los ficheros de intercambio
# los escribe la tarea elevada y los lee/limpia el listener sin privilegios.
& icacls $dataDir /grant "$($env:USERDOMAIN)\$($env:USERNAME):(OI)(CI)M" /T | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "No se pudieron ajustar los permisos de $dataDir (icacls $LASTEXITCODE)." }

# Token de API: si no existe se genera aqui y se enseña UNA vez. Es lo que hay
# que copiar al cliente (PUBLISHTOIIS_API_TOKEN). Para rotarlo:
# New-DeployEndpointToken -Force y reiniciar la tarea.
$tokenPath = Join-Path $dataDir 'api-token.txt'
if (-not (Test-Path $tokenPath)) {
    $token = New-DeployEndpointToken
    Write-Host "Token de API generado en ${tokenPath}:" -ForegroundColor Yellow
    Write-Host "  $token" -ForegroundColor Cyan
    Write-Host 'Copialo ahora al cliente (variable PUBLISHTOIIS_API_TOKEN); no se volvera a mostrar.' -ForegroundColor Yellow
}
else {
    Write-Host "Token de API ya presente en $tokenPath (se conserva)." -ForegroundColor Gray
}

# Reserva de URL ACL: sin ella HttpListener solo puede escuchar elevado. Se
# delega en el helper Set-DeployEndpointUrlAcl para mantener este script legible.
& (Join-Path $PSScriptRoot 'Set-DeployEndpointUrlAcl.ps1') -Port $Port -User "$($env:USERDOMAIN)\$($env:USERNAME)"

# Trigger, principal y settings compartidos por las dos tareas de fondo.
$trigger = New-ScheduledTaskTrigger -AtStartup
# S4U: corren aunque nadie tenga sesion iniciada, sin guardar contraseña.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType S4U -RunLevel Limited
# Sin limite de ejecucion (son servicios) y relanzadas por el Programador si mueren.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1)

# Tarea 1: el listener HTTP (acepta y encola).
$endpointScript = Join-Path $PSScriptRoot 'Start-DeployEndpoint.ps1'
$endpointAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$endpointScript`" -Port $Port -TaskName `"$PublishTaskName`""
Register-ScheduledTask -TaskName $TaskName -Action $endpointAction -Trigger $trigger -Principal $principal `
    -Settings $settings -Description "PublishToIIS: endpoint HTTP de despliegue en 127.0.0.1 puerto $Port (ver docs\deploy-endpoint.md)" -Force | Out-Null
Write-Host "Tarea '$TaskName' registrada (al arranque, sin privilegios, puerto $Port)." -ForegroundColor Green

# Tarea 2: el drenador de la cola (serializa las publicaciones, una a una).
$drainerScript = Join-Path $PSScriptRoot 'Start-DeployQueueDrainer.ps1'
$drainerAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$drainerScript`" -TaskName `"$PublishTaskName`""
Register-ScheduledTask -TaskName $DrainerTaskName -Action $drainerAction -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'PublishToIIS: drena la cola FIFO de despliegue llamando a la tarea Publish Local (ver docs\deploy-endpoint.md)' -Force | Out-Null
Write-Host "Tarea '$DrainerTaskName' registrada (al arranque, sin privilegios)." -ForegroundColor Green

Start-ScheduledTask -TaskName $TaskName
Start-ScheduledTask -TaskName $DrainerTaskName
Write-Host "Tareas arrancadas. Prueba: Invoke-RestMethod http://127.0.0.1:$Port/health" -ForegroundColor Gray
