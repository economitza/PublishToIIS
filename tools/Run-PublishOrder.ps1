# Ejecutado por la tarea programada elevada 'Publish Local'.
# Lee la orden de %ProgramData%\PublishToIIS\publish-order.json, la consume
# (la renombra a .consumed para que un /run accidental no re-publique) y
# ejecuta Invoke-DeployOrder. Log de cada ejecución en publish-order.log.
$ErrorActionPreference = 'Stop'

$dataDir = Join-Path $env:ProgramData 'PublishToIIS'
$orderPath = Join-Path $dataDir 'publish-order.json'
$logPath = Join-Path $dataDir 'publish-order.log'

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

    $order = Read-PublishOrder -Path $orderPath
    Move-Item -Path $orderPath -Destination "$orderPath.consumed" -Force

    Invoke-DeployOrder -Environment $order.environment -Branch $order.branch `
        -Execute:$order.execute -OverrideWebconfig:$order.overrideWebconfig

    Write-Host 'RESULT: OK'
}
catch {
    Write-Host "RESULT: ERROR - $($_.Exception.Message)"
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
