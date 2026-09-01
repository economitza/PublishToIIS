# Crea (idempotente) el site IIS reverse-proxy que expone el endpoint de
# despliegue a internet: habilita el proxy de ARR, deja la carpeta + web.config
# con la regla de reescritura a 127.0.0.1:<Port> y el site con binding http:80.
# Opcionalmente restringe por IP. Requiere IIS con URL Rewrite + ARR ya
# instalados. Se auto-eleva por UAC.
#
# El binding https:443 REUSA el certificado que ya tengas en el almacen y cubra el
# host (lo normal: el wildcard *.economitza.com que ya sirve devecoesp1 y compania)
# — no saca uno nuevo. Solo si no hay ninguno, indica como conseguirlo (win-acme).
#
# NO necesita el token del endpoint (eso es cosa del cliente): solo el hostname y
# el puerto del listener.
#
#   Register-DeployProxySite -HostName deployments-76.economitza.com
#   Register-DeployProxySite -HostName deployments-76.economitza.com -RestrictToIp 88.1.2.3
#   Register-DeployProxySite -HostName deployments-76.economitza.com -DryRun   # solo muestra el plan
[CmdletBinding()]
param(
    [string]$HostName,
    [int]$Port = 8770,
    [string]$SiteName = 'deployments-endpoint',
    [string]$PhysicalPath,
    # Si se indica, se restringe el site a esa IP (allowUnlisted=false + allow IP).
    [string]$RestrictToIp,
    # Certificado para https:443. Por defecto se REUSA uno del almacen que ya
    # cubra el host (el wildcard *.economitza.com que ya sirve otros sites) — no
    # hace falta uno nuevo. -CertThumbprint fuerza uno concreto; -FromSite copia el
    # que tenga otro site (p.ej. devecoesp1).
    [string]$CertThumbprint,
    [string]$FromSite,
    [switch]$DryRun,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'

# Pedir el hostname antes de elevar (Read-Host no funciona bien tras UAC).
if (-not $HostName) {
    if ($NonInteractive) { throw 'Falta -HostName.' }
    $HostName = (Read-Host 'HostName del endpoint (ej. deployments-76.economitza.com)').Trim()
}
if ($HostName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw "HostName invalido: '$HostName'." }
if (-not $PhysicalPath) { $PhysicalPath = Join-Path 'C:\inetpub' $SiteName }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Host 'Elevando por UAC...' -ForegroundColor Yellow
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
             '-HostName', $HostName, '-Port', $Port, '-SiteName', "`"$SiteName`"", '-PhysicalPath', "`"$PhysicalPath`"")
    if ($RestrictToIp)   { $fwd += @('-RestrictToIp', $RestrictToIp) }
    if ($CertThumbprint) { $fwd += @('-CertThumbprint', $CertThumbprint) }
    if ($FromSite)       { $fwd += @('-FromSite', "`"$FromSite`"") }
    Start-Process powershell -Verb RunAs -ArgumentList $fwd
    return
}

function Test-CertCoversHost {
    # ¿Alguno de los nombres DNS del cert cubre el host? Soporta wildcard de una
    # etiqueta (*.economitza.com cubre deployments-76.economitza.com, no a.b.eco...).
    param([string[]]$DnsNames, [string]$Target)
    foreach ($n in $DnsNames) {
        if (-not $n) { continue }
        if ($n -eq $Target) { return $true }
        if ($n.StartsWith('*.')) {
            $suffix = $n.Substring(1)  # ".economitza.com"
            if ($Target.EndsWith($suffix)) {
                $label = $Target.Substring(0, $Target.Length - $suffix.Length)
                if ($label -and $label -notmatch '\.') { return $true }
            }
        }
    }
    return $false
}

$webConfig = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="to-deploy-endpoint" stopProcessing="true">
          <match url="(.*)" />
          <action type="Rewrite" url="http://127.0.0.1:$Port/{R:1}" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
"@

Write-Host "== Plan del site reverse-proxy ==" -ForegroundColor Cyan
Write-Host "  Site        : $SiteName"
Write-Host "  HostName    : $HostName  (bindings http:80 y https:443 SNI)"
Write-Host "  Proxy a     : http://127.0.0.1:$Port"
Write-Host "  Carpeta     : $PhysicalPath (web.config con la regla de reescritura)"
Write-Host "  Restringe IP: $(if ($RestrictToIp) { $RestrictToIp } else { '(no)' })"
Write-Host "  Certificado : $(if ($CertThumbprint) { "thumbprint $CertThumbprint" } elseif ($FromSite) { "el de $FromSite" } else { 'reusar del almacen el que cubra el host (wildcard)' })"
if ($DryRun) { Write-Host "DryRun: no se toca IIS." -ForegroundColor Yellow; return }

Import-Module WebAdministration -ErrorAction Stop

# Prerrequisitos: ARR + URL Rewrite instalados (el proxy no funciona sin ellos).
$mods = @((Get-WebGlobalModule).Name)
if ($mods -notcontains 'ApplicationRequestRouting') { throw 'Falta ARR (Application Request Routing). Instalalo antes (choco install iis-arr).' }
if ($mods -notcontains 'RewriteModule') { throw 'Falta URL Rewrite. Instalalo antes (choco install urlrewrite).' }

# 1) Habilitar el proxy de ARR a nivel global.
Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter 'system.webServer/proxy' -name enabled -value $true
Write-Host "ARR proxy habilitado." -ForegroundColor Gray

# 2) Carpeta + web.config con la regla de reescritura.
if (-not (Test-Path $PhysicalPath)) { New-Item -ItemType Directory -Path $PhysicalPath -Force | Out-Null }
Set-Content -Path (Join-Path $PhysicalPath 'web.config') -Value $webConfig -Encoding UTF8
Write-Host "web.config escrito en $PhysicalPath." -ForegroundColor Gray

# 3) Site + binding http:80 (idempotente). El https:443 lo crea win-acme junto con
# el cert; pre-crear un binding https sin certificado da guerra.
if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
    New-Website -Name $SiteName -HostHeader $HostName -Port 80 -PhysicalPath $PhysicalPath | Out-Null
    Write-Host "Site '$SiteName' creado." -ForegroundColor Gray
}
else {
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $PhysicalPath
    if (-not (Get-WebBinding -Name $SiteName -Protocol http -Port 80 -HostHeader $HostName -ErrorAction SilentlyContinue)) {
        New-WebBinding -Name $SiteName -Protocol http -Port 80 -HostHeader $HostName
    }
    Write-Host "Site '$SiteName' ya existia: binding http:80 asegurado." -ForegroundColor Gray
}

# 4) Restriccion por IP (opcional): denegar por defecto y permitir la IP dada.
if ($RestrictToIp) {
    $filter = 'system.webServer/security/ipSecurity'
    $ps = "IIS:\Sites\$SiteName"
    Set-WebConfigurationProperty -pspath $ps -filter $filter -name allowUnlisted -value $false
    Clear-WebConfiguration -pspath $ps -filter "$filter/add" -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -pspath $ps -filter $filter -name '.' -value @{ ipAddress = $RestrictToIp; allowed = $true }
    Write-Host "Restringido a la IP $RestrictToIp." -ForegroundColor Gray
}

# 5) Certificado para https:443. Se REUSA uno del almacen que ya cubra el host
# (lo normal: el wildcard *.economitza.com que ya sirve devecoesp1 y compania);
# no hace falta uno nuevo de Let's Encrypt. Solo si no hay ninguno, se cae al
# fallback de win-acme.
$cert = $null
if ($CertThumbprint) {
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $CertThumbprint | Select-Object -First 1
    if (-not $cert) { throw "No hay certificado con thumbprint '$CertThumbprint' en LocalMachine\My." }
}
elseif ($FromSite) {
    $b = Get-WebBinding -Name $FromSite -Protocol https -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($b -and $b.certificateHash) {
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $b.certificateHash | Select-Object -First 1
    }
    if (-not $cert) { throw "El site '$FromSite' no tiene un binding https con certificado del que copiar." }
}
else {
    $cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.NotAfter -gt (Get-Date) -and (Test-CertCoversHost -DnsNames @($_.DnsNameList | ForEach-Object Unicode) -Target $HostName) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
}

if ($cert) {
    if (-not (Get-WebBinding -Name $SiteName -Protocol https -Port 443 -HostHeader $HostName -ErrorAction SilentlyContinue)) {
        New-WebBinding -Name $SiteName -Protocol https -Port 443 -HostHeader $HostName -SslFlags 1
    }
    $httpsBinding = Get-WebBinding -Name $SiteName -Protocol https -Port 443 -HostHeader $HostName
    $httpsBinding.AddSslCertificate($cert.Thumbprint, 'My')
    Write-Host ("Binding https:443 con cert '{0}' (caduca {1:yyyy-MM-dd}) — reusado del almacen, sin cert nuevo." -f `
        $cert.Subject.Split(',')[0], $cert.NotAfter) -ForegroundColor Green
    Write-Host ""
    Write-Host "Listo. Comprueba: Invoke-RestMethod https://$HostName/health" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "No hay ningun certificado en LocalMachine\My que cubra '$HostName'." -ForegroundColor Yellow
    Write-Host "Si tienes un wildcard *.economitza.com, importalo en LocalMachine\My y reejecuta (se reusa solo)." -ForegroundColor Yellow
    Write-Host "O saca uno con win-acme (wacs.exe):" -ForegroundColor Yellow
    Write-Host "  .\wacs.exe --source iis --host $HostName --installation iis" -ForegroundColor Cyan
    Write-Host "El binding http:80 ya esta; falta el https:443 con su cert." -ForegroundColor Yellow
}
