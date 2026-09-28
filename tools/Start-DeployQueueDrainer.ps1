# Drena la cola FIFO de despliegue UNA vez y termina. Lo dispara BAJO DEMANDA la
# tarea 'Publish Queue Drainer' cuando el endpoint encola una orden (no hay ningun
# proceso sondeando: en reposo no corre nada). Procesa las ordenes de una en una
# llamando a la tarea elevada 'Publish Local' via Invoke-DeployQueueDrain (que
# re-escanea la cola tras cada publish, asi recoge lo que llegue mientras drena);
# la tarea se registra con MultipleInstances=Queue para cubrir el disparo que
# caiga justo al terminar. Corre SIN privilegios.
[CmdletBinding()]
param(
    # Sin indicar, la tarea elevada del carril.
    [string]$TaskName,
    [ValidateSet('publish', 'dbrefresh')][string]$Lane = 'publish'
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force
$auditPath = Join-Path (Join-Path $env:ProgramData 'PublishToIIS') $(if ($Lane -eq 'dbrefresh') { 'drainer-dbrefresh.log' } else { 'drainer.log' })
$drainArgs = @{ Lane = $Lane }
if ($TaskName) { $drainArgs.TaskName = $TaskName }

try {
    $n = Invoke-DeployQueueDrain @drainArgs
    if ($n -gt 0) {
        "$((Get-Date).ToString('s')) | drenadas $n orden(es)" |
            Add-Content $auditPath -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}
catch {
    "$((Get-Date).ToString('s')) | ERROR | $($_.Exception.Message)" |
        Add-Content $auditPath -Encoding UTF8 -ErrorAction SilentlyContinue
    exit 1
}
