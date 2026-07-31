# Registra (una sola vez, requiere elevación por UAC) la tarea programada
# 'Publish Local': RunLevel Highest, sin trigger, se dispara bajo demanda con
#   schtasks /run /tn "Publish Local"
# tras dejar la orden en %ProgramData%\PublishToIIS\publish-order.json.
#
# El registro es el ÚNICO paso que necesita privilegios. A partir de ahí la
# publicación se pide desde una consola normal con Request-Publish (o desde el
# dashboard / un job de CI), que es lo mismo que hace schtasks /run.
#
#   # equipo de desarrollo (la tarea corre mientras la sesión esté iniciada)
#   .\Register-PublishLocalTask.ps1
#
#   # servidor (la tarea corre aunque nadie tenga sesión abierta)
#   .\Register-PublishLocalTask.ps1 -Unattended
#
#   # registrar y publicar de una vez
#   .\Register-PublishLocalTask.ps1 -Environment devecoand1 -Branch main_deploy-20260730 -Execute
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$Branch,
    [switch]$Execute,
    [string]$TaskName = 'Publish Local',
    # S4U: la tarea se ejecuta aunque el usuario no tenga sesión interactiva
    # abierta (imprescindible en un servidor al que se llama desde fuera) y sin
    # guardar la contraseña. Requiere el derecho "Log on as a batch job", que los
    # administradores locales ya tienen.
    [switch]$Unattended
)
$ErrorActionPreference = 'Stop'

$dataDir = Join-Path $env:ProgramData 'PublishToIIS'
$orderPath = Join-Path $dataDir 'publish-order.json'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    # Fase sin privilegios: dejar escrita la orden (si se pidió) y elevarse.
    if ($Environment -and $Branch) {
        if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
        @{ environment = $Environment; branch = $Branch; execute = [bool]$Execute } |
            ConvertTo-Json -Compress | Set-Content $orderPath -Encoding UTF8
        Write-Host "Orden escrita en $orderPath" -ForegroundColor Gray
    }
    Write-Host 'Elevando por UAC...' -ForegroundColor Yellow
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-TaskName', "`"$TaskName`"")
    if ($Unattended) { $fwd += '-Unattended' }
    Start-Process powershell -Verb RunAs -ArgumentList $fwd
    return
}

$runScript = Join-Path $PSScriptRoot 'Run-PublishOrder.ps1'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

# Los ficheros de intercambio los escribe la tarea ELEVADA y los lee/limpia el
# proceso SIN privilegios: con la ACL por defecto de %ProgramData% ese proceso no
# puede borrarlos. Se le da Modify sobre la carpeta y su contenido.
& icacls $dataDir /grant "$($env:USERDOMAIN)\$($env:USERNAME):(OI)(CI)M" /T | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "No se pudieron ajustar los permisos de $dataDir (icacls $LASTEXITCODE)." }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runScript`""
$logonType = if ($Unattended) { 'S4U' } else { 'Interactive' }
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType $logonType -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
    -Settings $settings -Description 'PublishToIIS: publica en local la orden de %ProgramData%\PublishToIIS\publish-order.json (ver tools\Run-PublishOrder.ps1)' -Force | Out-Null
Write-Host "Tarea '$TaskName' registrada (RunLevel Highest, LogonType $logonType)." -ForegroundColor Green

# Que cualquiera que pueda iniciar sesión en la máquina NO pueda disparar un
# despliegue: la tarea la ejecuta quien la registró (y los administradores).
if ($Unattended) {
    Write-Host "Se ejecutará aunque no haya sesión iniciada. Dispárala sin privilegios con:" -ForegroundColor Gray
} else {
    Write-Host "Se ejecutará solo con la sesión de $env:USERNAME iniciada. Dispárala sin privilegios con:" -ForegroundColor Gray
}
Write-Host "  Request-Publish -Environment <entorno> -Branch <rama> -Execute" -ForegroundColor Gray

if (Test-Path $orderPath) {
    Write-Host 'Orden pendiente detectada: ejecutándola ya...' -ForegroundColor Yellow
    Start-ScheduledTask -TaskName $TaskName
}
