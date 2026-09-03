# Crea (o completa) un site IIS local para una URL dada y publica en él un
# proyecto con PublishToIIS. Pensado para poder olvidarse del manejo del IIS:
# un solo comando deja carpeta, app pool, site, bindings http/https con su
# certificado, entrada en hosts y la aplicación publicada en Release.
#
#   .\New-LocalIisSite.ps1 -HostName esp1.emkt.test -ProjectPath C:\ruta\repo\CentralCompres
#
# Pasos (idempotente: lo que ya existe se respeta, solo se crea lo que falta;
# los 1-6 los hace Initialize-IisSite, la misma función con la que Publish aprovisiona
# un entorno que declara `templateSite`):
#   1) carpeta de destino (por defecto C:\inetpub\wwwroot\<hostname>; los puntos
#      en el nombre de carpeta no afectan a IIS)
#   2) app pool <hostname>, clonando runtime/pipeline del pool del site plantilla
#   3) site <hostname> con bindings *:80 y *:443 (SNI) usando el certificado del
#      site plantilla si cubre el hostname (wildcard); si no, busca uno válido
#      en Cert:\LocalMachine\My
#   4) siembra del Web.config del site plantilla en el destino (el publish del
#      módulo lo preserva, igual que en los servidores)
#   5) si ese Web.config conecta a SQL local con Integrated Security, replica el
#      acceso del pool plantilla al nuevo: login "IIS APPPOOL\<hostname>" y las
#      mismas bases de datos y roles (sin esto el site nace con "Login failed
#      for user 'IIS APPPOOL\...'")
#   6) entrada "<ip> <hostname>" en el archivo hosts si no existe
#   7) build + publish (Release) vía el módulo PublishToIIS: swap seguro,
#      deploy-info.json y Web.config preservado
#
# Requiere elevación: se auto-eleva por UAC, espera al proceso elevado y vuelca
# su log (%ProgramData%\PublishToIIS\new-localsite.log) en la consola original.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')]
    [string]$HostName,

    # Carpeta del proyecto (o .csproj) a publicar. Obligatorio salvo -SkipPublish.
    [string]$ProjectPath,

    # Carpeta física del site. Por defecto C:\inetpub\wwwroot\<HostName>.
    [string]$Destination,

    # Site IIS existente del que clonar certificado, app pool y Web.config.
    [string]$TemplateSite = 'economitza_espana',

    [string]$Configuration = 'Release',

    [string]$HostsIp = '127.0.0.1',

    # Solo aprovisionar (carpeta, pool, site, cert, hosts) sin build/publish.
    [switch]$SkipPublish
)
$ErrorActionPreference = 'Stop'

if (-not $Destination) { $Destination = Join-Path 'C:\inetpub\wwwroot' $HostName }
if (-not $SkipPublish -and -not $ProjectPath) {
    throw 'Falta -ProjectPath (o usa -SkipPublish para aprovisionar sin publicar).'
}

$dataDir = Join-Path $env:ProgramData 'PublishToIIS'
$logPath = Join-Path $dataDir 'new-localsite.log'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Elevando por UAC...' -ForegroundColor Yellow
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
             '-HostName', "`"$HostName`"", '-Destination', "`"$Destination`"",
             '-TemplateSite', "`"$TemplateSite`"", '-Configuration', "`"$Configuration`"",
             '-HostsIp', "`"$HostsIp`"")
    if ($ProjectPath) { $fwd += @('-ProjectPath', "`"$ProjectPath`"") }
    if ($SkipPublish) { $fwd += '-SkipPublish' }
    $p = Start-Process powershell -Verb RunAs -ArgumentList $fwd -Wait -PassThru
    # La consola elevada es otra: el rastro útil queda en el transcript.
    if (Test-Path $logPath) {
        Write-Host "--- log del proceso elevado ($logPath) ---" -ForegroundColor Gray
        Get-Content $logPath | Where-Object { $_ -notmatch '^\*{22}|^(Windows PowerShell transcript|Transcripci|Hora de |Nombre de usuario|Usuario RunAs|Nombre de configuraci|Equipo|Aplicaci|Id. de proceso|Versi|N.mero de compilaci|CLRVersion|WSManStackVersion|PSRemotingProtocolVersion|SerializationVersion|PSCompatibleVersions)' } |
            ForEach-Object { Write-Host "  | $_" }
    }
    if ($p.ExitCode -ne 0) { throw "El proceso elevado terminó con código $($p.ExitCode). Revisa $logPath." }
    return
}

# ---------- fase elevada ----------

if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
Start-Transcript -Path $logPath -Force | Out-Null
$failed = $false
try {
    Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force
    Import-Module WebAdministration

    # Pasos 1-6 en el módulo (Initialize-IisSite): los mismos que ejecuta Publish al
    # aprovisionar un entorno con `templateSite`. Aquí pool y site se llaman como
    # el hostname y la entrada en hosts sí se escribe: es un site local.
    $plantilla = $TemplateSite
    if ($plantilla -and -not (Get-Website -Name $plantilla -ErrorAction SilentlyContinue)) {
        Write-Warning "El site plantilla '$plantilla' no existe: sin siembra de Web.config y con valores de pool por defecto."
        $plantilla = ''
    }
    $prov = Initialize-IisSite -Name $HostName -Destination $Destination -HostName $HostName `
        -TemplateSite $plantilla -HostsIp $HostsIp
    if ($prov.actions.Count) { Write-Host ("Aprovisionado: " + ($prov.actions -join '; ')) -ForegroundColor Green }
    else { Write-Host 'Site ya aprovisionado; nada que crear.' -ForegroundColor Gray }

    # 7) build + publish con el módulo (swap seguro, preserva Web.config)
    if ($SkipPublish) {
        Write-Host "[7/7] Publish omitido (-SkipPublish)" -ForegroundColor Yellow
    } else {
        Write-Host "[7/7] Publicando '$ProjectPath' ($Configuration) en $Destination..." -ForegroundColor Yellow
        Publish -ProjectPath $ProjectPath -Destination $Destination -AppPoolName $prov.appPool -Configuration $Configuration

        try {
            $resp = Invoke-WebRequest "https://$HostName/" -UseBasicParsing -TimeoutSec 300
            Write-Host "Smoke: https://$HostName/ responde $($resp.StatusCode)" -ForegroundColor Green
        } catch {
            Write-Warning "Smoke: https://$HostName/ no responde limpio: $($_.Exception.Message)"
        }
    }

    Write-Host "Hecho: https://$HostName/" -ForegroundColor Cyan
}
catch {
    $failed = $true
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
}
if ($failed) { exit 1 }
