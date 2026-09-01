# Bucle drenador de la cola de despliegue. Lo ejecuta la tarea programada
# 'Publish Queue Drainer'. Procesa la cola FIFO de una en una llamando a la
# tarea elevada 'Publish Local' (via Invoke-DeployQueueDrain) y duerme entre
# pasadas. Corre SIN privilegios: solo dispara la tarea elevada, que es quien
# publica. Un fallo puntual se anota y el bucle sigue.
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 3,
    [string]$TaskName = 'Publish Local'
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force
$auditPath = Join-Path (Join-Path $env:ProgramData 'PublishToIIS') 'drainer.log'

while ($true) {
    try {
        $n = Invoke-DeployQueueDrain -TaskName $TaskName
        if ($n -gt 0) {
            "$((Get-Date).ToString('s')) | drenadas $n orden(es)" |
                Add-Content $auditPath -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }
    catch {
        "$((Get-Date).ToString('s')) | ERROR | $($_.Exception.Message)" |
            Add-Content $auditPath -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds $IntervalSeconds
}
