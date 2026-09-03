# Ejecutado por la tarea programada elevada 'Publish Local'.
# Lee la orden de %ProgramData%\PublishToIIS\publish-order.json, la consume
# (la renombra a .consumed para que un /run accidental no re-publique) y
# ejecuta Invoke-DeployOrder; si la orden es kind=update, en vez de publicar
# actualiza el propio módulo (Update-PublishToIIS) y reinicia el listener del
# endpoint para que cargue el código nuevo.
#
# Deja dos rastros para quien la disparó SIN privilegios (Request-Publish, el
# dashboard o el job de CI), que no ve la consola de la tarea:
#   - publish-order.log         transcript completo
#   - publish-order.result.json estado final legible por máquina
[CmdletBinding()]
param(
    # Tarea del listener HTTP a reiniciar tras una actualización del módulo.
    [string]$EndpointTaskName = 'Publish Endpoint'
)
$ErrorActionPreference = 'Stop'

$dataDir = Join-Path $env:ProgramData 'PublishToIIS'
$orderPath = Join-Path $dataDir 'publish-order.json'
$logPath = Join-Path $dataDir 'publish-order.log'
$resultPath = Join-Path $dataDir 'publish-order.result.json'

$startedAt = Get-Date
$order = $null
$restartEndpoint = $false

function Write-Result {
    param([string]$Status, [string]$Message)
    [pscustomobject]@{
        status      = $Status
        message     = $Message
        kind        = if ($order -and $order.kind) { $order.kind } else { 'publish' }
        # Eco del runId de la orden: es lo que permite a quien la pidió saber que
        # este resultado es el suyo y no el de la ejecución anterior.
        runId       = $order.runId
        environment = $order.environment
        branch      = $order.branch
        execute     = if ($order) { [bool]$order.execute } else { $false }
        requestedBy = $order.requestedBy
        startedAt   = $startedAt.ToString('o')
        finishedAt  = (Get-Date).ToString('o')
        ranBy       = "$env:USERNAME@$env:COMPUTERNAME"
        logPath     = $logPath
    } | ConvertTo-Json | Set-Content $resultPath -Encoding UTF8
}

function Get-RepoVersion {
    param([string]$Repo)
    $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $Repo 'PublishToIIS.psd1')), "ModuleVersion\s*=\s*'(\d+\.\d+\.\d+)'")
    if ($m.Success) { $m.Groups[1].Value } else { '?' }
}

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

    $order = Read-PublishOrder -Path $orderPath
    Move-Item -Path $orderPath -Destination "$orderPath.consumed" -Force

    if ($order.kind -eq 'update') {
        # Actualización del propio módulo. La cola FIFO del endpoint garantiza que
        # no coincide con un publish; aquí solo hay que traer el código y reinstalar.
        $repo = Get-PublishToIISRepo
        $antes = Get-RepoVersion -Repo $repo
        Update-PublishToIIS -RepoPath $repo
        $despues = Get-RepoVersion -Repo $repo
        $commit = [string](& git -C $repo rev-parse --short HEAD 2>$null)
        Write-Host 'RESULT: OK'
        Write-Result -Status 'ok' -Message "Módulo actualizado en $env:COMPUTERNAME: $antes -> $despues ($commit). El listener del endpoint se reinicia para cargar el código nuevo."
        $restartEndpoint = $true
    }
    else {
        $deployArgs = @{
            Environment       = $order.environment
            Branch            = $order.branch
            Execute           = [bool]$order.execute
            OverrideWebconfig = [bool]$order.overrideWebconfig
            RequestedBy       = $order.requestedBy
        }
        # Entorno ad hoc (worktree efimero): la definicion viaja en la propia orden
        if ($order.environmentDef) { $deployArgs.EnvironmentDef = $order.environmentDef }
        Invoke-DeployOrder @deployArgs

        Write-Host 'RESULT: OK'
        $done = if ($order.execute) { "Publicado $($order.branch) en $($order.environment)." }
                else { "DRY-RUN: plan resuelto para $($order.branch) en $($order.environment) (no se ha publicado nada)." }
        Write-Result -Status 'ok' -Message $done
    }
}
catch {
    Write-Host "RESULT: ERROR - $($_.Exception.Message)"
    Write-Result -Status 'error' -Message $_.Exception.Message
    exit 1
}
finally {
    if ($restartEndpoint) {
        # Después de escribir el resultado: el listener es quien lo sirve a quien
        # espera fuera, y se queda sin servicio unos segundos. El drenador y esta
        # tarea importan el módulo en cada ejecución, así que no necesitan reinicio.
        try {
            $task = Get-ScheduledTask -TaskName $EndpointTaskName -ErrorAction SilentlyContinue
            if ($task) {
                if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $EndpointTaskName }
                Start-Sleep -Seconds 2
                Start-ScheduledTask -TaskName $EndpointTaskName
                Write-Host "Tarea '$EndpointTaskName' reiniciada."
            }
            else {
                Write-Host "No hay tarea '$EndpointTaskName' en esta máquina: nada que reiniciar."
            }
        }
        catch { Write-Host "No se pudo reiniciar '$EndpointTaskName': $($_.Exception.Message)" }
    }
    Stop-Transcript | Out-Null
}
