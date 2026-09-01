# Arranca el listener del endpoint de despliegue. Lo ejecuta la tarea programada
# 'Publish Endpoint' (o una consola a mano para probar). Se mantiene vivo: si el
# listener cae por lo que sea, lo relanza tras una pausa y deja rastro en
# endpoint.log; asi el proceso de la tarea no termina (que la dejaba en Ready y
# el puerto sin nadie escuchando -> 502 en el proxy).
[CmdletBinding()]
param(
    [int]$Port = 8770,
    [string]$TaskName = 'Publish Local',
    [string]$DrainerTaskName = 'Publish Queue Drainer'
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force
$auditPath = Join-Path (Join-Path $env:ProgramData 'PublishToIIS') 'endpoint.log'

while ($true) {
    try {
        Start-DeployEndpoint -Port $Port -TaskName $TaskName -DrainerTaskName $DrainerTaskName
        "$((Get-Date).ToString('s')) | - | listener termino sin error; relanzando" |
            Add-Content $auditPath -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        "$((Get-Date).ToString('s')) | - | listener CAIDO: $($_.Exception.Message); relanzando" |
            Add-Content $auditPath -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
}
