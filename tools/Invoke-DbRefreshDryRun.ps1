# Dry-run de un refresco de BD, fuera de toda cola. Lo lanza en un proceso oculto el
# endpoint (Start-DbRefreshDryRun) para que responda al momento: un dry-run no para
# pools ni escribe en la BD, así que no tiene por qué esperar turno detrás de un
# deploy ni de otro refresco, ni necesita la tarea elevada. Deja su resultado en
# results\<runId>.json, como una orden de la cola, y su transcript en
# logs\dbrefresh-<runId>.log (GET /api/log?runId=...).
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$Environment,
    [string]$TestEmail,
    [string]$Tables,
    [string]$RequestedBy,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

# Get-PublishDataDir no se exporta: la carpeta de datos se resuelve igual que en el módulo.
$dir = if ($DataDir) { $DataDir } else { Join-Path $env:ProgramData 'PublishToIIS' }
$resultPath = Join-Path $dir "results\$RunId.json"
$logPath = Get-DbRefreshDryRunLogPath -RunId $RunId -DataDir $dir
New-Item -ItemType Directory -Path (Split-Path $logPath -Parent), (Split-Path $resultPath -Parent) -Force | Out-Null
$startedAt = (Get-Date).ToString('o')

function Write-DryRunResult([string]$Status, [string]$Message) {
    [pscustomobject]@{
        status = $Status; message = $Message; runId = $RunId; kind = 'dbrefresh'; lane = 'dryrun'
        environment = $Environment; branch = ''; requestedBy = $RequestedBy; execute = $false
        startedAt = $startedAt; finishedAt = (Get-Date).ToString('o'); logPath = $logPath
    } | ConvertTo-Json | Set-Content $resultPath -Encoding UTF8
}

Start-Transcript -Path $logPath -Force | Out-Null
try {
    $tablas = @($Tables -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $plan = Invoke-DbRefreshOrder -Environment $Environment -TestEmail $TestEmail -Tables $tablas `
        -RequestedBy $RequestedBy -RunId $RunId -DataDir $dir
    $sitios = ($plan.sites | ForEach-Object { $_.environment }) -join ', '
    Write-DryRunResult -Status 'ok' -Message "DRY-RUN: plan de refresco de $($plan.database) ($($plan.dataSource)) para $Environment; sites que comparten la BD: $sitios. El plan de tablas está en el log."
}
catch {
    Write-Host "RESULT: ERROR - $($_.Exception.Message)"
    Write-DryRunResult -Status 'error' -Message $_.Exception.Message
}
finally {
    Stop-Transcript | Out-Null
}
