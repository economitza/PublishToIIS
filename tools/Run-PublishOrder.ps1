# Ejecutado por la tarea programada elevada 'Publish Local'.
# Lee la orden de %ProgramData%\PublishToIIS\publish-order.json, la consume
# (la renombra a .consumed para que un /run accidental no re-publique) y
# ejecuta Invoke-DeployOrder.
#
# Deja dos rastros para quien la disparó SIN privilegios (Request-Publish, el
# dashboard o el job de CI), que no ve la consola de la tarea:
#   - publish-order.log         transcript completo
#   - publish-order.result.json estado final legible por máquina
$ErrorActionPreference = 'Stop'

$dataDir = Join-Path $env:ProgramData 'PublishToIIS'
$orderPath = Join-Path $dataDir 'publish-order.json'
$logPath = Join-Path $dataDir 'publish-order.log'
$resultPath = Join-Path $dataDir 'publish-order.result.json'

$startedAt = Get-Date
$order = $null

function Write-Result {
    param([string]$Status, [string]$Message)
    [pscustomobject]@{
        status      = $Status
        message     = $Message
        # Eco del runId de la orden: es lo que permite a quien la pidió saber que
        # este resultado es el suyo y no el de la ejecución anterior.
        runId       = $order.runId
        environment = $order.environment
        branch      = $order.branch
        execute     = if ($order) { [bool]$order.execute } else { $false }
        startedAt   = $startedAt.ToString('o')
        finishedAt  = (Get-Date).ToString('o')
        ranBy       = "$env:USERNAME@$env:COMPUTERNAME"
        logPath     = $logPath
    } | ConvertTo-Json | Set-Content $resultPath -Encoding UTF8
}

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

    $order = Read-PublishOrder -Path $orderPath
    Move-Item -Path $orderPath -Destination "$orderPath.consumed" -Force

    Invoke-DeployOrder -Environment $order.environment -Branch $order.branch `
        -Execute:$order.execute -OverrideWebconfig:$order.overrideWebconfig

    Write-Host 'RESULT: OK'
    $done = if ($order.execute) { "Publicado $($order.branch) en $($order.environment)." }
            else { "DRY-RUN: plan resuelto para $($order.branch) en $($order.environment) (no se ha publicado nada)." }
    Write-Result -Status 'ok' -Message $done
}
catch {
    Write-Host "RESULT: ERROR - $($_.Exception.Message)"
    Write-Result -Status 'error' -Message $_.Exception.Message
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
