# Crea (o completa) un site IIS local para una URL dada y publica en él un
# proyecto con PublishToIIS. Pensado para poder olvidarse del manejo del IIS:
# un solo comando deja carpeta, app pool, site, bindings http/https con su
# certificado, entrada en hosts y la aplicación publicada en Release.
#
#   .\New-LocalIisSite.ps1 -HostName esp1.emkt.test -ProjectPath C:\ruta\repo\CentralCompres
#
# Pasos (idempotente: lo que ya existe se respeta, solo se crea lo que falta):
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

function Test-CertCoversHost {
    # ¿Alguno de los nombres DNS del certificado (con soporte wildcard de un
    # solo nivel, como hacen los navegadores) cubre el hostname?
    param([string[]]$DnsNames, [string]$Target)
    foreach ($n in $DnsNames) {
        if ($n -ieq $Target) { return $true }
        if ($n.StartsWith('*.')) {
            $suffix = $n.Substring(1) # ".emkt.test"
            if ($Target.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) -and
                $Target.Split('.').Count -eq $n.Split('.').Count) { return $true }
        }
    }
    return $false
}

function Find-SiteCertificate {
    # Certificado para el binding https: primero el del site plantilla si cubre
    # el hostname; si no, el primero de LocalMachine\My vigente que lo cubra.
    param($TemplateHttpsBinding, [string]$Target)

    if ($TemplateHttpsBinding -and $TemplateHttpsBinding.certificateHash) {
        $store = if ($TemplateHttpsBinding.certificateStoreName) { $TemplateHttpsBinding.certificateStoreName } else { 'My' }
        $cert = Get-ChildItem "Cert:\LocalMachine\$store" |
            Where-Object Thumbprint -eq $TemplateHttpsBinding.certificateHash | Select-Object -First 1
        if ($cert -and (Test-CertCoversHost -DnsNames @($cert.DnsNameList | ForEach-Object Unicode) -Target $Target)) {
            return [pscustomobject]@{ cert = $cert; store = $store; source = 'site plantilla' }
        }
    }

    $cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.NotAfter -gt (Get-Date) -and (Test-CertCoversHost -DnsNames @($_.DnsNameList | ForEach-Object Unicode) -Target $Target) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($cert) { return [pscustomobject]@{ cert = $cert; store = 'My'; source = 'LocalMachine\My' } }

    throw ("No hay ningún certificado en LocalMachine\My que cubra '$Target'. " +
           "Genera uno (p.ej. mkcert '*.$(($Target -split '\.', 2)[1])') e impórtalo, o pasa otro -TemplateSite.")
}

function Get-LocalIntegratedSqlServers {
    # Data Sources del Web.config que apuntan a la instancia LOCAL con
    # Integrated Security: son los que autentican con la identidad del app pool.
    param([string]$WebConfigPath)
    if (-not (Test-Path $WebConfigPath)) { return @() }
    [xml]$cfg = Get-Content $WebConfigPath -Raw
    $servers = @()
    foreach ($add in @($cfg.configuration.connectionStrings.add)) {
        $cs = [string]$add.connectionString
        if ($cs -match '(?i)Integrated Security\s*=\s*(True|SSPI)' -and $cs -match '(?i)Data Source\s*=\s*([^;]+)') {
            $ds = $Matches[1].Trim()
            $machine = ($ds -split '[\\,]')[0].Trim()
            if ($machine -in @('localhost', '.', '(local)', '127.0.0.1', $env:COMPUTERNAME)) { $servers += $ds }
        }
    }
    return @($servers | Select-Object -Unique)
}

function Copy-AppPoolSqlAccess {
    # Replica en $Server el acceso del login del pool plantilla al del pool
    # nuevo: crea el login de Windows si falta y, en cada BD donde la plantilla
    # tiene usuario, crea el usuario y lo mete en los mismos roles. Idempotente.
    param([string]$Server, [string]$TemplateLogin, [string]$NewLogin)

    function Escape-SqlName([string]$n) { '[' + ($n -replace '\]', ']]') + ']' }

    Add-Type -AssemblyName System.Data
    $cn = New-Object System.Data.SqlClient.SqlConnection("Data Source=$Server;Initial Catalog=master;Integrated Security=True;Encrypt=False")
    $cn.Open()
    try {
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = 'SELECT COUNT(*) FROM sys.server_principals WHERE name = @n'
        [void]$cmd.Parameters.AddWithValue('@n', $TemplateLogin)
        if ([int]$cmd.ExecuteScalar() -eq 0) { return "el pool plantilla no tiene login '$TemplateLogin' en $Server; nada que replicar" }

        $cmd.Parameters['@n'].Value = $NewLogin
        if ([int]$cmd.ExecuteScalar() -eq 0) {
            $cmd.Parameters.Clear()
            $cmd.CommandText = "CREATE LOGIN $(Escape-SqlName $NewLogin) FROM WINDOWS"
            [void]$cmd.ExecuteNonQuery()
        }

        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT name FROM sys.databases WHERE state = 0 AND name NOT IN ('master','tempdb','model','msdb')"
        $rd = $cmd.ExecuteReader()
        $dbs = @(); while ($rd.Read()) { $dbs += $rd[0] }
        $rd.Close()

        $replicated = @()
        foreach ($db in $dbs) {
            $dbCmd = $cn.CreateCommand()
            $dbCmd.CommandText = "USE $(Escape-SqlName $db); SELECT r.name FROM sys.database_role_members m JOIN sys.database_principals r ON r.principal_id = m.role_principal_id JOIN sys.database_principals u ON u.principal_id = m.member_principal_id WHERE u.name = @t; "
            [void]$dbCmd.Parameters.AddWithValue('@t', $TemplateLogin)
            $roles = @(); $rd = $dbCmd.ExecuteReader(); while ($rd.Read()) { $roles += $rd[0] }; $rd.Close()

            $dbCmd.CommandText = "USE $(Escape-SqlName $db); SELECT COUNT(*) FROM sys.database_principals WHERE name = @t"
            if ([int]$dbCmd.ExecuteScalar() -eq 0) { continue } # la plantilla no tiene usuario aquí

            $apply = $cn.CreateCommand()
            $apply.CommandText = "USE $(Escape-SqlName $db); IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$($NewLogin -replace "'", "''")') CREATE USER $(Escape-SqlName $NewLogin) FOR LOGIN $(Escape-SqlName $NewLogin); " +
                (($roles | ForEach-Object { "ALTER ROLE $(Escape-SqlName $_) ADD MEMBER $(Escape-SqlName $NewLogin); " }) -join '')
            [void]$apply.ExecuteNonQuery()
            $replicated += "$db ($($roles -join ','))"
        }
        if ($replicated) { return "acceso replicado en $Server -> " + ($replicated -join '; ') }
        return "login creado en $Server (la plantilla no tenía usuario en ninguna BD)"
    }
    finally { $cn.Close() }
}

if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
Start-Transcript -Path $logPath -Force | Out-Null
$failed = $false
try {
    Import-Module WebAdministration

    $template = Get-Website -Name $TemplateSite -ErrorAction SilentlyContinue
    if (-not $template) {
        Write-Warning "El site plantilla '$TemplateSite' no existe: sin siembra de Web.config y con valores de pool por defecto."
    }
    $templateHttps = if ($template) {
        $template.bindings.Collection | Where-Object protocol -eq 'https' | Select-Object -First 1
    }

    # 1-2) carpeta de destino
    if (Test-Path $Destination) {
        Write-Host "[1/7] Carpeta ya existe: $Destination" -ForegroundColor Gray
    } else {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-Host "[1/7] Carpeta creada: $Destination" -ForegroundColor Green
    }

    # 2) app pool
    if (Test-Path "IIS:\AppPools\$HostName") {
        Write-Host "[2/7] App pool ya existe: $HostName" -ForegroundColor Gray
    } else {
        New-WebAppPool -Name $HostName | Out-Null
        $runtime = 'v4.0'; $pipeline = 'Integrated'
        if ($template) {
            $tp = Get-Item "IIS:\AppPools\$($template.applicationPool)" -ErrorAction SilentlyContinue
            if ($tp) { $runtime = $tp.managedRuntimeVersion; $pipeline = [string]$tp.managedPipelineMode }
        }
        Set-ItemProperty "IIS:\AppPools\$HostName" managedRuntimeVersion $runtime
        Set-ItemProperty "IIS:\AppPools\$HostName" managedPipelineMode $pipeline
        Write-Host "[2/7] App pool creado: $HostName ($runtime, $pipeline)" -ForegroundColor Green
    }

    # 3) site + bindings + certificado
    $site = Get-Website -Name $HostName -ErrorAction SilentlyContinue
    if ($site) {
        if ($site.physicalPath -ne $Destination) {
            Write-Warning "El site '$HostName' ya existe pero apunta a '$($site.physicalPath)', no a '$Destination'. No se toca."
        }
        Write-Host "[3/7] Site ya existe: $HostName" -ForegroundColor Gray
    } else {
        # Un binding con el mismo host header en otro site rompería el arranque.
        $clash = Get-WebBinding | Where-Object bindingInformation -match ":$([regex]::Escape($HostName))$" |
            Select-Object -First 1
        if ($clash) { throw "Ya hay un binding para '$HostName' en otro site ($($clash.ItemXPath))." }

        New-Website -Name $HostName -PhysicalPath $Destination -ApplicationPool $HostName `
            -HostHeader $HostName -Port 80 | Out-Null
        New-WebBinding -Name $HostName -Protocol https -Port 443 -HostHeader $HostName -SslFlags 1

        $found = Find-SiteCertificate -TemplateHttpsBinding $templateHttps -Target $HostName
        $httpsBinding = Get-WebBinding -Name $HostName -Protocol https -Port 443 -HostHeader $HostName
        $httpsBinding.AddSslCertificate($found.cert.Thumbprint, $found.store)
        Write-Host ("[3/7] Site creado: {0} (http+https SNI, cert '{1}' de {2}, caduca {3:yyyy-MM-dd})" -f `
            $HostName, $found.cert.Subject.Split(',')[0], $found.source, $found.cert.NotAfter) -ForegroundColor Green
    }

    # 4) siembra del Web.config de la plantilla (el publish lo preservará)
    $destWebConfig = Join-Path $Destination 'Web.config'
    if (Test-Path $destWebConfig) {
        Write-Host "[4/7] Web.config ya presente en el destino (se preservará)" -ForegroundColor Gray
    } elseif ($template) {
        $srcWebConfig = Join-Path $template.physicalPath 'Web.config'
        if (Test-Path $srcWebConfig) {
            Copy-Item $srcWebConfig $destWebConfig
            Write-Host "[4/7] Web.config sembrado desde '$TemplateSite' (misma BD y settings que la plantilla)" -ForegroundColor Green
        } else {
            Write-Warning "[4/7] La plantilla no tiene Web.config en $($template.physicalPath); el publish usará el del repo."
        }
    } else {
        Write-Host "[4/7] Sin plantilla: el publish usará el Web.config del repo" -ForegroundColor Yellow
    }

    # 5) acceso SQL del app pool (Integrated Security contra la instancia local)
    if ($template) {
        $sqlServers = Get-LocalIntegratedSqlServers -WebConfigPath $destWebConfig
        if (-not $sqlServers) {
            Write-Host "[5/7] El Web.config no conecta a SQL local con Integrated Security: nada que replicar" -ForegroundColor Gray
        }
        foreach ($srv in $sqlServers) {
            try {
                $msg = Copy-AppPoolSqlAccess -Server $srv `
                    -TemplateLogin "IIS APPPOOL\$($template.applicationPool)" -NewLogin "IIS APPPOOL\$HostName"
                Write-Host "[5/7] SQL: $msg" -ForegroundColor Green
            } catch {
                Write-Warning "[5/7] SQL: no se pudo replicar el acceso en '$srv': $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "[5/7] Sin plantilla: revisa a mano el acceso SQL del pool" -ForegroundColor Yellow
    }

    # 6) hosts
    $hostsFile = Join-Path $env:windir 'System32\drivers\etc\hosts'
    $hasEntry = Select-String -Path $hostsFile -Pattern "^\s*[^#\s]\S*\s+.*\b$([regex]::Escape($HostName))\b" -Quiet
    if ($hasEntry) {
        Write-Host "[6/7] hosts ya contiene $HostName" -ForegroundColor Gray
    } else {
        $raw = [IO.File]::ReadAllText($hostsFile)
        $newline = if ($raw.EndsWith("`n")) { '' } else { "`r`n" }
        [IO.File]::AppendAllText($hostsFile, "$newline$HostsIp`t$HostName`r`n")
        Write-Host "[6/7] hosts: añadido $HostsIp $HostName" -ForegroundColor Green
    }

    # 7) build + publish con el módulo (swap seguro, preserva Web.config)
    if ($SkipPublish) {
        Write-Host "[7/7] Publish omitido (-SkipPublish)" -ForegroundColor Yellow
    } else {
        Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force
        Write-Host "[7/7] Publicando '$ProjectPath' ($Configuration) en $Destination..." -ForegroundColor Yellow
        Publish -ProjectPath $ProjectPath -Destination $Destination -AppPoolName $HostName -Configuration $Configuration

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
