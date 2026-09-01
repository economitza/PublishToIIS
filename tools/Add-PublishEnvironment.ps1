# Alta interactiva de un entorno en config\environments.json y commit-push al
# repo, para que quede disponible en todas las maquinas (portatil, servidor) con
# un git pull / Update-PublishToIIS. Pregunta los campos por consola (deja vacio
# lo que no aplique), inserta la entrada preservando el formato del fichero,
# muestra un resumen y, al confirmar, commitea y pushea.
#
#   .\Add-PublishEnvironment.ps1
#   .\Add-PublishEnvironment.ps1 -Name devecoesp3 -SiteUrl https://devecoesp3.economitza.com `
#       -EndpointUrl https://deployments-76.economitza.com   # no interactivo
#
# Campos: Name (obligatorio, unico). Origin/Destination/AppPool/SiteUrl/ServerName/
# EndpointUrl opcionales - solo se escriben los que se rellenen. Con EndpointUrl el
# entorno se publica en remoto por el endpoint; sin el, en local (origin en la maquina).
[CmdletBinding()]
param(
    [string]$Name,
    [string]$Origin,
    [string]$Destination,
    [string]$AppPool,
    [string]$SiteUrl,
    [string]$ServerName,
    [string]$EndpointUrl,
    # No commitear/pushear (solo modificar el fichero local).
    [switch]$NoPush,
    # No preguntar (falla si falta algo obligatorio); util para scripts.
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$cfgPath = Join-Path $repo 'config\environments.json'
if (-not (Test-Path $cfgPath)) { throw "No se encontro $cfgPath." }

function Read-Field {
    param([string]$Prompt, [string]$Current, [switch]$Required)
    if ($Current) { return $Current }
    if ($NonInteractive) {
        if ($Required) { throw "Falta -$Prompt (modo no interactivo)." }
        return ''
    }
    $label = if ($Required) { "$Prompt (obligatorio)" } else { "$Prompt (Enter = omitir)" }
    do {
        $v = (Read-Host $label).Trim()
        if ($Required -and -not $v) { Write-Host '  ...es obligatorio.' -ForegroundColor Yellow }
    } while ($Required -and -not $v)
    return $v
}

Write-Host "== Alta de entorno en environments.json ==" -ForegroundColor Cyan
$Name        = Read-Field -Prompt 'Name'        -Current $Name -Required
$Origin      = Read-Field -Prompt 'Origin'      -Current $Origin
$Destination = Read-Field -Prompt 'Destination' -Current $Destination
$AppPool     = Read-Field -Prompt 'AppPool'     -Current $AppPool
$SiteUrl     = Read-Field -Prompt 'SiteUrl'     -Current $SiteUrl
$ServerName  = Read-Field -Prompt 'ServerName'  -Current $ServerName
$EndpointUrl = Read-Field -Prompt 'EndpointUrl' -Current $EndpointUrl

if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Nombre de entorno con caracteres no permitidos: '$Name' (usa letras, digitos, . _ -)."
}

$raw = [IO.File]::ReadAllText($cfgPath)
$nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }

# Validar el JSON y que el nombre no exista ya.
$cfg = $raw | ConvertFrom-Json
if ($cfg.environments.PSObject.Properties.Name -contains $Name) {
    throw "El entorno '$Name' ya existe en environments.json."
}

# Construir la entrada: clave a 4 espacios, campos a 6, en orden fijo; solo los
# rellenados. El valor se escapa para JSON (barras invertidas de las rutas y comillas).
$fields = [ordered]@{
    origin      = $Origin
    destination = $Destination
    appPool     = $AppPool
    siteUrl     = $SiteUrl
    serverName  = $ServerName
    endpointUrl = $EndpointUrl
}
$fieldLines = foreach ($k in $fields.Keys) {
    if ($fields[$k]) {
        $v = ([string]$fields[$k]).Replace('\', '\\').Replace('"', '\"')
        '      "' + $k + '": "' + $v + '"'
    }
}
$entry = '    "' + $Name + '": {' + $nl + ($fieldLines -join (',' + $nl)) + $nl + '    },'

# Insertar como primera entrada, justo tras la apertura de "environments": {.
# Prepender evita tener que tocar la coma final de la ultima entrada.
$anchor = [regex]'("environments"\s*:\s*\{[ \t]*\r?\n)'
$new = $anchor.Replace($raw, { param($m) $m.Value + $entry + $nl }, 1)
if ($new -eq $raw) { throw "No se encontro la apertura de 'environments' en el JSON." }

# Comprobar que el resultado sigue siendo JSON valido antes de escribir.
$null = $new | ConvertFrom-Json

Write-Host ""
Write-Host "Entrada a anadir:" -ForegroundColor Cyan
Write-Host $entry.TrimEnd(',')
Write-Host ""

if (-not $NonInteractive) {
    $accion = if ($NoPush) { 'guardar el fichero (sin commit)' } else { 'guardar, commitear y PUSHEAR a origin' }
    $ok = (Read-Host "Confirmas $accion? (s/N)").Trim().ToLower()
    if ($ok -ne 's' -and $ok -ne 'si') { Write-Host 'Cancelado, no se ha tocado nada.' -ForegroundColor Yellow; return }
}

[IO.File]::WriteAllText($cfgPath, $new, (New-Object Text.UTF8Encoding($false)))
Write-Host "environments.json actualizado." -ForegroundColor Green

if ($NoPush) {
    Write-Host "Sin commit (--NoPush). Recuerda commitear/pushear cuando quieras publicarlo." -ForegroundColor Gray
    return
}

& git -C $repo add config/environments.json
if ($LASTEXITCODE) { throw "git add fallo (codigo $LASTEXITCODE)." }
& git -C $repo commit -q -m "chore(config): entorno $Name"
if ($LASTEXITCODE) { throw "git commit fallo (codigo $LASTEXITCODE)." }
& git -C $repo push
if ($LASTEXITCODE) { throw "git push fallo (codigo $LASTEXITCODE). El commit esta hecho en local; reintenta el push a mano." }
Write-Host "Commiteado y pusheado. Ya disponible con git pull / Update-PublishToIIS en las demas maquinas." -ForegroundColor Green
