# Registra (una sola vez, requiere elevación por UAC) la tarea programada
# 'Publish Local': RunLevel Highest, sin trigger, se dispara bajo demanda con
#   schtasks /run /tn "Publish Local"
# tras dejar la orden en %ProgramData%\PublishToIIS\publish-order.json.
#
# Con -Environment/-Branch escribe además esa orden ANTES de elevarse (fase sin
# privilegios), y tras registrar la tarea la ejecuta inmediatamente.
#   .\Register-PublishLocalTask.ps1 -Environment dev-joaquim-local -Branch main_deploy-20260720a -Execute
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$Branch,
    [switch]$Execute
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
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    return
}

$runScript = Join-Path $PSScriptRoot 'Run-PublishOrder.ps1'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runScript`""
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName 'Publish Local' -Action $action -Principal $principal `
    -Settings $settings -Description 'PublishToIIS: publica en local la orden de %ProgramData%\PublishToIIS\publish-order.json (ver tools\Run-PublishOrder.ps1)' -Force | Out-Null
Write-Host "Tarea 'Publish Local' registrada (RunLevel Highest)." -ForegroundColor Green

if (Test-Path $orderPath) {
    Write-Host 'Orden pendiente detectada: ejecutándola ya...' -ForegroundColor Yellow
    Start-ScheduledTask -TaskName 'Publish Local'
}
