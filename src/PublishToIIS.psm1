# Dot-source the config module
$configPath = Join-Path $PSScriptRoot '..\config\config.ps1'
if (Test-Path $configPath) {
    . $configPath
}

function Get-MSBuild {
    $cmd = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidates = @(
        "C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools\\MSBuild\\Current\\Bin\\MSBuild.exe",
        "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\MSBuild\\Current\\Bin\\MSBuild.exe",
        "C:\\Program Files\\Microsoft Visual Studio\\2022\\Professional\\MSBuild\\Current\\Bin\\MSBuild.exe",
        "C:\\Program Files (x86)\\Microsoft Visual Studio\\2019\\BuildTools\\MSBuild\\Current\\Bin\\MSBuild.exe",
        "C:\\Program Files (x86)\\Microsoft Visual Studio\\2019\\Community\\MSBuild\\Current\\Bin\\MSBuild.exe"
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }

    throw "MSBuild not found. Install Visual Studio Build Tools or add MSBuild to PATH."
}

function Stop-IISAppPool {
    param([Parameter(Mandatory)][string]$Name)

    Import-Module WebAdministration -ErrorAction Stop

    if (-not (Test-Path "IIS:\AppPools\$Name")) {
        throw "Application pool '$Name' not found in IIS."
    }

    if ((Get-WebAppPoolState -Name $Name).Value -ne 'Stopped') {
        Stop-WebAppPool -Name $Name
    }

    # Wait until fully stopped so the worker process releases file locks
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-WebAppPoolState -Name $Name).Value -ne 'Stopped') {
        if ((Get-Date) -gt $deadline) { throw "Timed out waiting for app pool '$Name' to stop." }
        Start-Sleep -Milliseconds 250
    }
}

function Start-IISAppPool {
    param([Parameter(Mandatory)][string]$Name)

    Import-Module WebAdministration -ErrorAction Stop

    if (-not (Test-Path "IIS:\AppPools\$Name")) {
        throw "Application pool '$Name' not found in IIS."
    }

    if ((Get-WebAppPoolState -Name $Name).Value -ne 'Started') {
        Start-WebAppPool -Name $Name
    }

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-WebAppPoolState -Name $Name).Value -ne 'Started') {
        if ((Get-Date) -gt $deadline) { throw "Timed out waiting for app pool '$Name' to start." }
        Start-Sleep -Milliseconds 250
    }
}

function Protect-ProductionWebConfig {
    <#
    .SYNOPSIS
        Gestiona el web.config al publicar: por defecto preserva el de producción.

    .DESCRIPTION
        Comportamiento por defecto: copia el web.config del destino (producción)
        sobre el recién publicado, manteniendo la configuración del servidor.
        Con -Override se publica el web.config del repo y el de producción se
        guarda al lado como 'web.config.previous' para poder comparar/restaurar.

    .OUTPUTS
        'preserved' | 'overridden' | 'no-production-webconfig'
    #>
    param(
        [Parameter(Mandatory)][string]$TargetWebConfig,
        [Parameter(Mandatory)][string]$ReleasingWebConfig,
        [switch]$Override
    )

    if (-not (Test-Path $TargetWebConfig)) {
        return 'no-production-webconfig'
    }

    if ($Override) {
        Copy-Item $TargetWebConfig "$ReleasingWebConfig.previous" -Force
        return 'overridden'
    }

    Copy-Item $TargetWebConfig $ReleasingWebConfig -Force
    return 'preserved'
}

# ─── Aprovisionamiento de sites IIS desde una plantilla ─────────────────────
# Lo que hacía tools\New-LocalIisSite.ps1 en su fase elevada, ahora en el módulo
# para que Publish pueda crear el site la primera vez que publica en un entorno
# nuevo (entrada con `templateSite` en environments.json). Idempotente: lo que ya
# existe se respeta y solo se crea lo que falta.

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
           "Genera uno (p.ej. mkcert '*.$(($Target -split '\.', 2)[1])') e impórtalo, o indica otro site plantilla.")
}

function Get-ConnectionStringNodes {
    # Nodos <add> de connectionStrings de un Web.config, siguiendo configSource
    # si la sección vive en otro fichero (connections.config). Devuelve pares
    # (fichero, nodo) para poder guardar cada documento tocado.
    param([string]$WebConfigPath)
    if (-not (Test-Path $WebConfigPath)) { return @() }
    $xml = New-Object Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($WebConfigPath)
    $section = $xml.SelectSingleNode('/configuration/connectionStrings')
    if (-not $section) { return @() }
    $source = $section.GetAttribute('configSource')
    if ($source) {
        $ext = Join-Path (Split-Path $WebConfigPath -Parent) $source
        if (-not (Test-Path $ext)) { return @() }
        $xml = New-Object Xml.XmlDocument
        $xml.PreserveWhitespace = $true
        $xml.Load($ext)
        $section = $xml.SelectSingleNode('/connectionStrings')
        if (-not $section) { return @() }
        return @($section.SelectNodes('add') | ForEach-Object { [pscustomobject]@{ path = $ext; doc = $xml; node = $_ } })
    }
    @($section.SelectNodes('add') | ForEach-Object { [pscustomobject]@{ path = $WebConfigPath; doc = $xml; node = $_ } })
}

function Set-ConnectionStringCatalog {
    <#
    .SYNOPSIS
        Cambia la base de datos (Initial Catalog / Database) de las cadenas de conexión de un config.

    .DESCRIPTION
        Recorre los <add> de connectionStrings del Web.config indicado (o del
        connections.config al que apunte por configSource) y, para cada cadena
        cuyo catálogo aparezca como clave del mapa, lo sustituye por el valor. Las
        demás cadenas no se tocan. Es lo que permite que un site aprovisionado
        desde una plantilla nazca apuntando a SU base de datos y no a la de la
        plantilla. Devuelve el número de cadenas modificadas.

    .EXAMPLE
        Set-ConnectionStringCatalog -WebConfigPath E:\wwwrootDevecoEsp3\Web.config -DatabaseMap @{ CCEspana = 'CCEspana_esp3' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WebConfigPath,
        [Parameter(Mandatory)][hashtable]$DatabaseMap
    )
    $entries = Get-ConnectionStringNodes -WebConfigPath $WebConfigPath
    $changed = 0
    $docs = @{}
    foreach ($e in $entries) {
        $cs = $e.node.GetAttribute('connectionString')
        $new = [regex]::Replace($cs, '(?i)(Initial Catalog|Database)\s*=\s*([^;]+)', {
            param($m)
            $db = $m.Groups[2].Value.Trim()
            if ($DatabaseMap.ContainsKey($db)) { "$($m.Groups[1].Value)=$($DatabaseMap[$db])" } else { $m.Value }
        }.GetNewClosure())
        if ($new -ne $cs) {
            $e.node.SetAttribute('connectionString', $new)
            $docs[$e.path] = $e.doc
            $changed++
        }
    }
    foreach ($p in $docs.Keys) { $docs[$p].Save($p) }
    $changed
}

function Get-LocalIntegratedSqlServers {
    # Data Sources del Web.config que apuntan a la instancia LOCAL con
    # Integrated Security: son los que autentican con la identidad del app pool.
    param([string]$WebConfigPath)
    $servers = @()
    foreach ($e in (Get-ConnectionStringNodes -WebConfigPath $WebConfigPath)) {
        $cs = [string]$e.node.GetAttribute('connectionString')
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

function ConvertTo-DatabaseMap {
    # El mapa llega como hashtable (código) o como PSCustomObject (JSON de
    # environments.json / orden ad hoc). Siempre hashtable, sin distinguir mayúsculas.
    param($Map)
    if ($null -eq $Map) { return $null }
    if ($Map -is [hashtable]) { return $Map }
    $h = @{}
    foreach ($p in $Map.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
    if ($h.Count) { $h } else { $null }
}

function Initialize-IisSite {
    <#
    .SYNOPSIS
        Deja listo un site de IIS (carpeta, app pool, site, bindings http/https con
        certificado y configuración sembrada) clonando un site plantilla. Idempotente.

    .DESCRIPTION
        Es el aprovisionamiento que Publish ejecuta antes del primer despliegue en
        un entorno cuya entrada declara `templateSite`. Pasos (lo que ya existe se
        respeta, solo se crea lo que falta):
          1) carpeta de destino
          2) app pool -AppPoolName (por defecto -Name), clonando runtime/pipeline
             del pool de la plantilla
          3) site -Name con bindings *:80 y *:443 (SNI) para -HostName, con el
             certificado de la plantilla si cubre el host (wildcard) o el primero
             válido de LocalMachine\My. Si ya hay un site con ese host header bajo
             OTRO nombre, se usa ese (no se crea un segundo).
          4) siembra de Web.config y connections.config desde la carpeta de la
             plantilla (Publish los preserva en cada swap, como en los servidores)
             y, con -DatabaseMap, cambio del catálogo de las cadenas de conexión
             sembradas para que el site nazca con SU base de datos
          5) si la plantilla conecta a SQL local con Integrated Security, réplica
             del acceso del pool plantilla al nuevo (login + usuarios + roles)
          6) con -HostsIp, entrada "<ip> <hostname>" en el archivo hosts (solo
             tiene sentido en el portátil; en un servidor con DNS no se pasa)

        Requiere privilegios de administrador (IIS). Devuelve un objeto con lo
        que se ha hecho (`actions`) y el app pool efectivo del site.

    .EXAMPLE
        Initialize-IisSite -Name devecoesp3 -Destination E:\wwwrootDevecoEsp3 -HostName devecoesp3.economitza.com -TemplateSite devecoesp1 -DatabaseMap @{ CCEspana = 'CCEspana_esp3' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]*$')][string]$Name,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$HostName,
        [string]$AppPoolName,
        [string]$TemplateSite,
        $DatabaseMap,
        [string]$HostsIp,
        [switch]$SkipSqlAccess
    )
    $ErrorActionPreference = 'Stop'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Initialize-IisSite requiere privilegios de administrador (IIS).' }
    Import-Module WebAdministration -ErrorAction Stop

    if (-not $AppPoolName) { $AppPoolName = $Name }
    $DatabaseMap = ConvertTo-DatabaseMap $DatabaseMap
    $actions = New-Object System.Collections.Generic.List[string]

    $template = $null
    $templatePath = $null
    if ($TemplateSite) {
        $template = Get-Website -Name $TemplateSite -ErrorAction SilentlyContinue
        if (-not $template) { throw "El site plantilla '$TemplateSite' no existe en este IIS." }
        $templatePath = [Environment]::ExpandEnvironmentVariables([string]$template.physicalPath)
    }
    $templateHttps = if ($template) {
        $template.bindings.Collection | Where-Object protocol -eq 'https' | Select-Object -First 1
    }

    # 1) carpeta
    if (Test-Path $Destination) {
        Write-Host "[1/6] Carpeta ya existe: $Destination" -ForegroundColor Gray
    } else {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        $actions.Add("carpeta $Destination")
        Write-Host "[1/6] Carpeta creada: $Destination" -ForegroundColor Green
    }

    # 3, antes que 2) ¿ya hay un site sirviendo este host? Entonces su pool manda.
    $site = Get-Website -Name $Name -ErrorAction SilentlyContinue
    if (-not $site) {
        $clash = Get-WebBinding | Where-Object bindingInformation -match ":$([regex]::Escape($HostName))$" | Select-Object -First 1
        if ($clash -and $clash.ItemXPath -match "@name='([^']+)'") {
            $site = Get-Website -Name $Matches[1] -ErrorAction SilentlyContinue
            if ($site) {
                Write-Warning "El host '$HostName' ya lo sirve el site '$($site.name)' (pool '$($site.applicationPool)'); se usa ese en vez de crear '$Name'."
                $AppPoolName = $site.applicationPool
            }
        }
    }

    # 2) app pool
    if (Test-Path "IIS:\AppPools\$AppPoolName") {
        Write-Host "[2/6] App pool ya existe: $AppPoolName" -ForegroundColor Gray
    } else {
        New-WebAppPool -Name $AppPoolName | Out-Null
        $runtime = 'v4.0'; $pipeline = 'Integrated'
        if ($template) {
            $tp = Get-Item "IIS:\AppPools\$($template.applicationPool)" -ErrorAction SilentlyContinue
            if ($tp) { $runtime = $tp.managedRuntimeVersion; $pipeline = [string]$tp.managedPipelineMode }
        }
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" managedRuntimeVersion $runtime
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" managedPipelineMode $pipeline
        $actions.Add("app pool $AppPoolName")
        Write-Host "[2/6] App pool creado: $AppPoolName ($runtime, $pipeline)" -ForegroundColor Green
    }

    # 3) site + bindings + certificado
    if ($site) {
        $sitePath = [Environment]::ExpandEnvironmentVariables([string]$site.physicalPath)
        if ($sitePath -ne $Destination.TrimEnd('\')) {
            throw "El site '$($site.name)' ya existe pero apunta a '$sitePath', no a '$Destination'. Corrige la entrada del entorno o el site."
        }
        Write-Host "[3/6] Site ya existe: $($site.name)" -ForegroundColor Gray
    } else {
        New-Website -Name $Name -PhysicalPath $Destination -ApplicationPool $AppPoolName `
            -HostHeader $HostName -Port 80 | Out-Null
        New-WebBinding -Name $Name -Protocol https -Port 443 -HostHeader $HostName -SslFlags 1

        $found = Find-SiteCertificate -TemplateHttpsBinding $templateHttps -Target $HostName
        $httpsBinding = Get-WebBinding -Name $Name -Protocol https -Port 443 -HostHeader $HostName
        $httpsBinding.AddSslCertificate($found.cert.Thumbprint, $found.store)
        $site = Get-Website -Name $Name
        $actions.Add("site $Name ($HostName, cert $($found.source))")
        Write-Host ("[3/6] Site creado: {0} -> {1} (http+https SNI, cert '{2}' de {3}, caduca {4:yyyy-MM-dd})" -f `
            $Name, $HostName, $found.cert.Subject.Split(',')[0], $found.source, $found.cert.NotAfter) -ForegroundColor Green
    }

    # 4) siembra de la configuración de la plantilla (Publish la preserva en el swap)
    $seeded = @()
    foreach ($file in 'Web.config', 'connections.config') {
        $dest = Join-Path $Destination $file
        if (Test-Path $dest) { continue }
        if (-not $templatePath) { continue }
        $src = Join-Path $templatePath $file
        if (Test-Path $src) {
            Copy-Item $src $dest
            $seeded += $file
        }
    }
    if ($seeded) {
        $actions.Add("config sembrada desde '$TemplateSite': $($seeded -join ', ')")
        Write-Host "[4/6] Sembrado desde '$TemplateSite': $($seeded -join ', ')" -ForegroundColor Green
        if ($DatabaseMap) {
            $n = Set-ConnectionStringCatalog -WebConfigPath (Join-Path $Destination 'Web.config') -DatabaseMap $DatabaseMap
            $desc = ($DatabaseMap.Keys | ForEach-Object { "$_ -> $($DatabaseMap[$_])" }) -join ', '
            if ($n -gt 0) {
                $actions.Add("catálogo de BD cambiado en $n cadena(s): $desc")
                Write-Host "[4/6] Base de datos: $n cadena(s) apuntadas a su catálogo ($desc)" -ForegroundColor Green
            } else {
                Write-Warning "[4/6] databaseMap ($desc) no casó con ninguna cadena de conexión sembrada."
            }
        }
    } elseif ($templatePath) {
        Write-Host "[4/6] Configuración ya presente en el destino (se preservará)" -ForegroundColor Gray
    } else {
        Write-Host "[4/6] Sin plantilla: el publish usará la configuración del repo" -ForegroundColor Yellow
    }

    # 5) acceso SQL del app pool (Integrated Security contra la instancia local)
    if ($template -and -not $SkipSqlAccess) {
        $sqlServers = Get-LocalIntegratedSqlServers -WebConfigPath (Join-Path $Destination 'Web.config')
        if (-not $sqlServers) {
            Write-Host "[5/6] La configuración no conecta a SQL local con Integrated Security: nada que replicar" -ForegroundColor Gray
        }
        foreach ($srv in $sqlServers) {
            try {
                $msg = Copy-AppPoolSqlAccess -Server $srv `
                    -TemplateLogin "IIS APPPOOL\$($template.applicationPool)" -NewLogin "IIS APPPOOL\$AppPoolName"
                $actions.Add("SQL: $msg")
                Write-Host "[5/6] SQL: $msg" -ForegroundColor Green
            } catch {
                Write-Warning "[5/6] SQL: no se pudo replicar el acceso en '$srv': $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "[5/6] Acceso SQL del pool: no se toca" -ForegroundColor Gray
    }

    # 6) hosts (solo si se pide: en un servidor con DNS sobra)
    if ($HostsIp) {
        $hostsFile = Join-Path $env:windir 'System32\drivers\etc\hosts'
        $hasEntry = Select-String -Path $hostsFile -Pattern "^\s*[^#\s]\S*\s+.*\b$([regex]::Escape($HostName))\b" -Quiet
        if ($hasEntry) {
            Write-Host "[6/6] hosts ya contiene $HostName" -ForegroundColor Gray
        } else {
            $rawHosts = [IO.File]::ReadAllText($hostsFile)
            $newline = if ($rawHosts.EndsWith("`n")) { '' } else { "`r`n" }
            [IO.File]::AppendAllText($hostsFile, "$newline$HostsIp`t$HostName`r`n")
            $actions.Add("hosts: $HostsIp $HostName")
            Write-Host "[6/6] hosts: añadido $HostsIp $HostName" -ForegroundColor Green
        }
    } else {
        Write-Host "[6/6] hosts: no se toca (resolución por DNS)" -ForegroundColor Gray
    }

    [pscustomobject]@{
        site        = $site.name
        appPool     = $AppPoolName
        destination = $Destination
        hostName    = $HostName
        template    = $TemplateSite
        actions     = @($actions)
    }
}

function New-DeployInfo {
    <#
    .SYNOPSIS
        Escribe deploy-info.json (rama, commit, fechas, entorno, quién lo pidió) en el directorio publicado.

    .DESCRIPTION
        Sello de versión del despliegue (Fase 1 del dashboard de publicación): toma
        rama/commit de la copia de trabajo git de ProjectPath y lo escribe como
        deploy-info.json en OutputDir. Pensado para ejecutarse tras el MSBuild y antes
        del swap, de modo que el sello viaje atómicamente con el site y quede
        consultable en GET /deploy-info.json.

        Si ProjectPath no es una copia de trabajo git, avisa y escribe el sello con
        branch/commit nulos: el sello nunca debe abortar una publicación.

    .OUTPUTS
        PSCustomObject con el contenido escrito.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$OutputDir,
        [string]$Environment,
        # EQUIPO\usuario que pidió la publicación (viene de la orden). Sin él, el
        # del proceso actual: en una publicación a mano pide y ejecuta el mismo.
        [string]$RequestedBy
    )

    $branch = $null; $commit = $null; $commitFull = $null; $commitDate = $null

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $insideRepo = (& git -C $ProjectPath rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -eq 0 -and "$insideRepo".Trim() -eq 'true') {
            $branch = ("$(& git -C $ProjectPath rev-parse --abbrev-ref HEAD 2>$null)").Trim()
            # Convención de git: las abreviaturas son PREFIJOS del SHA completo.
            # Se guarda el SHA completo (comparable con cualquier herramienta) y
            # un corto de longitud FIJA (9) para mostrar — --short a secas varía
            # de longitud según el repo y provoca "discrepancias" aparentes.
            $commitFull = ("$(& git -C $ProjectPath rev-parse HEAD 2>$null)").Trim()
            $commit = ("$(& git -C $ProjectPath rev-parse --short=9 HEAD 2>$null)").Trim()
            $commitDate = ("$(& git -C $ProjectPath show -s --format=%cI HEAD 2>$null)").Trim()
        }
    }

    if (-not $commit) {
        Write-Warning "New-DeployInfo: '$ProjectPath' no es una copia de trabajo git (o git no está disponible); se escribe el sello sin rama/commit."
        $branch = $null; $commit = $null; $commitFull = $null; $commitDate = $null
    }

    $info = [pscustomobject]@{
        branch      = $branch
        commit      = $commit
        commitFull  = $commitFull
        commitDate  = $commitDate
        publishDate = (Get-Date).ToString('o')
        environment = $Environment
        # publishedBy = cuenta que ejecutó el swap; requestedBy = quien lo pidió.
        # En un despliegue por endpoint son distintos (listener vs. quien hizo clic).
        publishedBy = "$env:USERNAME@$env:COMPUTERNAME"
        requestedBy = if ($RequestedBy) { $RequestedBy } else { Get-RequesterIdentity }
    }

    $file = Join-Path $OutputDir 'deploy-info.json'
    $info | ConvertTo-Json | Set-Content -Path $file -Encoding UTF8
    return $info
}

function Publish {
    param(
        [string]$ProjectPath,
        [string]$Destination,
        [string]$Environment,
        [string]$AppPoolName,
        [string]$Configuration = "Release",
        [hashtable]$MSBuildProperties = @{},
        [switch]$KeepPrevious,
        [switch]$OverrideWebconfig,
        [string]$RequestedBy,
        # Aprovisionamiento (ver Initialize-IisSite): si el entorno declara un site
        # plantilla, el site se crea la primera vez y se respeta las siguientes.
        # Se resuelven de la entrada del entorno (templateSite, hostName/siteUrl,
        # databaseMap) cuando no se pasan explícitos.
        [string]$TemplateSite,
        [string]$HostName,
        $DatabaseMap
    )

    # Check for admin privileges
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "This script requires administrator privileges. Please run PowerShell as Administrator."
    }

    $ErrorActionPreference = "Stop"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "ENTER Publish function" -ForegroundColor Cyan

    # Rutas, pool y aprovisionamiento no indicados: se toman de la config central.
    # Con las rutas explícitas (entorno ad hoc) un entorno desconocido no es error.
    $cfg = $null
    if ($Environment -or -not $ProjectPath -or -not $Destination -or -not $AppPoolName) {
        if (-not (Get-Command Get-PublishConfig -ErrorAction SilentlyContinue)) {
            # try to dot-source config if available relative to module
            $maybeCfg = Join-Path $PSScriptRoot '..\config\config.ps1'
            if (Test-Path $maybeCfg) { . $maybeCfg }
        }

        if (Get-Command Get-PublishConfig -ErrorAction SilentlyContinue) {
            try { $cfg = Get-PublishConfig -Environment $Environment }
            catch { if (-not $ProjectPath -or -not $Destination) { throw } }
        }
    }
    if ($cfg) {
        if (-not $ProjectPath -and $cfg.origin) { $ProjectPath = $cfg.origin }
        if (-not $Destination -and $cfg.destination) { $Destination = $cfg.destination }
        if (-not $AppPoolName -and $cfg.appPool) { $AppPoolName = $cfg.appPool }
        # By convention the app pool matches the environment name; use it when not set explicitly
        if (-not $AppPoolName -and $cfg._environment) { $AppPoolName = $cfg._environment }
        if (-not $TemplateSite -and $cfg.templateSite) { $TemplateSite = [string]$cfg.templateSite }
        if (-not $HostName -and $cfg.hostName) { $HostName = [string]$cfg.hostName }
        if (-not $HostName -and $cfg.siteUrl) { $HostName = ([Uri][string]$cfg.siteUrl).Host }
        if (-not $DatabaseMap -and $cfg.databaseMap) { $DatabaseMap = $cfg.databaseMap }
    }
    if (-not $ProjectPath -or -not $Destination) {
        throw "Publish necesita ProjectPath y Destination (explícitos o por -Environment en environments.json)."
    }

    $msbuild = Get-MSBuild
    Write-Host "Using MSBuild: $msbuild" -ForegroundColor Yellow

    $parentDir = Split-Path $Destination -Parent
    $siteName = Split-Path $Destination -Leaf

    # Default the app pool to the site (destination) name when not configured
    if (-not $AppPoolName) { $AppPoolName = $siteName }

    # Aprovisionamiento: con site plantilla declarado, el site/pool/carpeta se
    # crean si faltan (y se respetan si existen) ANTES de construir nada. El
    # nombre del site en IIS es el del entorno, como el del pool.
    if ($TemplateSite) {
        if (-not $HostName) {
            throw "El entorno declara templateSite '$TemplateSite' pero no hay hostname (campo hostName o siteUrl)."
        }
        $iisSiteName = if ($Environment) { $Environment } else { $siteName }
        Write-Host "Aprovisionando site '$iisSiteName' ($HostName) desde la plantilla '$TemplateSite'..." -ForegroundColor Yellow
        $prov = Initialize-IisSite -Name $iisSiteName -AppPoolName $AppPoolName -Destination $Destination `
            -HostName $HostName -TemplateSite $TemplateSite -DatabaseMap $DatabaseMap
        $AppPoolName = $prov.appPool
        if ($prov.actions.Count) { Write-Host ("Aprovisionado: " + ($prov.actions -join '; ')) -ForegroundColor Green }
        else { Write-Host "Site ya aprovisionado; nada que crear." -ForegroundColor Gray }
    }

    $releasingDir = Join-Path $parentDir "${siteName}_releasing"
    $previousDir = Join-Path $parentDir "${siteName}_previous"

    $targetWebConfig = Join-Path $Destination "web.config"
    $releasingWebConfig = Join-Path $releasingDir "web.config"

    $poolStopped = $false
    $swapCompleted = $false

    try {
        Write-Host "Destination:  $Destination" -ForegroundColor Gray
        Write-Host "Releasing:    $releasingDir" -ForegroundColor Gray
        Write-Host "Previous:     $previousDir" -ForegroundColor Gray

        # Limpiar publicación temporal anterior
        if (Test-Path $releasingDir) {
            Write-Host "Removing stale releasing directory..." -ForegroundColor Yellow
            Remove-Item $releasingDir -Recurse -Force
        }

        New-Item -ItemType Directory -Path $releasingDir | Out-Null

        Write-Host "Running MSBuild publish into releasing directory..." -ForegroundColor Yellow

        # Resolve ProjectPath: if it's a folder, find a .csproj inside
        if (Test-Path $ProjectPath -PathType Container) {
            $csproj = Get-ChildItem -Path $ProjectPath -Filter *.csproj -Recurse -File | Select-Object -First 1
            if ($csproj) { $projectToBuild = $csproj.FullName } else { throw "No .csproj found under $ProjectPath" }
        }
        else { $projectToBuild = $ProjectPath }

        # Build extra MSBuild properties passed by the caller (e.g. @{ MvcBuildViews = 'true' })
        $extraProps = @()
        foreach ($key in $MSBuildProperties.Keys) {
            $extraProps += "/p:$key=$($MSBuildProperties[$key])"
        }
        if ($extraProps.Count) {
            Write-Host "Extra MSBuild properties: $($extraProps -join ' ')" -ForegroundColor Gray
        }

        & $msbuild $projectToBuild `
            /p:Configuration=$Configuration `
            /p:DeployOnBuild=true `
            /p:PublishUrl="$releasingDir" `
            /p:WebPublishMethod=FileSystem `
            /p:DeployTarget=WebPublish `
            @extraProps `
            /v:minimal

        if ($LASTEXITCODE -ne 0) {
            throw "MSBuild failed with exit code $LASTEXITCODE."
        }

        Write-Host "MSBuild publish completed" -ForegroundColor Green

        # web.config: por defecto se preserva el de producción; con -OverrideWebconfig
        # se publica el del repo y el de producción queda como web.config.previous.
        $webConfigResult = Protect-ProductionWebConfig -TargetWebConfig $targetWebConfig `
            -ReleasingWebConfig $releasingWebConfig -Override:$OverrideWebconfig
        switch ($webConfigResult) {
            'preserved'  { Write-Host "Production web.config preserved (repo one discarded)" -ForegroundColor Green }
            'overridden' { Write-Host "REPO web.config PUBLISHED (-OverrideWebconfig); production copy saved as web.config.previous" -ForegroundColor Yellow }
            default      { Write-Host "No production web.config found; publishing the repo one" -ForegroundColor Yellow }
        }
        # connections.config va aparte del Web.config (configSource) y en el repo
        # está gitignored: sin esto cada publish arrastraba el del ORIGEN a todos
        # los sites construidos desde él (misma BD para todos). Misma política que
        # el web.config: el del site se preserva; -OverrideWebconfig publica el del build.
        $connResult = Protect-ProductionWebConfig -TargetWebConfig (Join-Path $Destination 'connections.config') `
            -ReleasingWebConfig (Join-Path $releasingDir 'connections.config') -Override:$OverrideWebconfig
        switch ($connResult) {
            'preserved'  { Write-Host "Site connections.config preserved" -ForegroundColor Green }
            'overridden' { Write-Host "BUILD connections.config PUBLISHED (-OverrideWebconfig); site copy saved as connections.config.previous" -ForegroundColor Yellow }
        }

        # Sello de versión del despliegue: viaja dentro de releasing/ y por tanto con el swap
        $deployInfoEnv = if ($Environment) { $Environment } else { $siteName }
        $deployInfo = New-DeployInfo -ProjectPath $ProjectPath -OutputDir $releasingDir -Environment $deployInfoEnv -RequestedBy $RequestedBy
        if ($deployInfo.commit) {
            Write-Host "deploy-info.json stamped: $($deployInfo.branch)@$($deployInfo.commit) -> $deployInfoEnv" -ForegroundColor Green
        }

        # Si había un previous viejo, eliminarlo antes del swap
        if (Test-Path $previousDir) {
            Write-Host "Removing old previous directory..." -ForegroundColor Yellow
            Remove-Item $previousDir -Recurse -Force
        }

        Write-Host "Stopping app pool '$AppPoolName' for final swap..." -ForegroundColor Yellow
        Stop-IISAppPool -Name $AppPoolName
        $poolStopped = $true

        # Mover destino actual a previous
        if (Test-Path $Destination) {
            Rename-Item -Path $Destination -NewName "${siteName}_previous"
        }

        # Activar nueva release
        Rename-Item -Path $releasingDir -NewName $siteName

        $swapCompleted = $true
        Write-Host "Directory swap completed" -ForegroundColor Green
    }
    catch {
        Write-Host "Publish failed: $($_.Exception.Message)" -ForegroundColor Red

        # Intento de rollback si el swap quedó a medias
        if ($poolStopped -and -not $swapCompleted) {
            Write-Host "Attempting rollback..." -ForegroundColor Yellow

            $destinationExists = Test-Path $Destination
            $previousExists = Test-Path $previousDir

            if (-not $destinationExists -and $previousExists) {
                Rename-Item -Path $previousDir -NewName $siteName
                Write-Host "Rollback completed" -ForegroundColor Green
            }
        }

        throw
    }
    finally {
        if ($poolStopped) {
            Write-Host "Starting app pool '$AppPoolName'..." -ForegroundColor Yellow
            Start-IISAppPool -Name $AppPoolName
        }

        if ($swapCompleted -and -not $KeepPrevious) {
            if (Test-Path $previousDir) {
                Write-Host "Removing previous directory..." -ForegroundColor Yellow
                Remove-Item $previousDir -Recurse -Force
            }
        }

        $sw.Stop()
        Write-Host ("Total execution time: {0:hh\:mm\:ss\.fff}" -f $sw.Elapsed) -ForegroundColor Cyan
    }
}

function Invoke-DeployOrder {
    <#
    .SYNOPSIS
        Ejecuta una "orden de despliegue": valida entorno/rama, hace checkout y publica.

    .DESCRIPTION
        Cuerpo compartido por el job de deploy de GitLab CI (Fase 3 del dashboard) y
        el ensayo local, para que ambos ejecuten EXACTAMENTE el mismo código.

        Por defecto es DRY-RUN: valida el entorno contra una lista blanca, valida el
        formato de la rama y resuelve el plan (repo, destino, argumentos de Publish)
        SIN tocar el repo ni publicar. Con -Execute hace fetch/checkout/pull de la
        rama en la copia de trabajo del entorno y llama a Publish (requiere admin).

        Seguridad: prod/staging quedan fuera de la lista blanca por defecto; hay que
        pasarlos explícitamente en -AllowedEnvironments para poder desplegarlos.

    .OUTPUTS
        PSCustomObject con el plan resuelto.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Environment,
        [string]$Branch = 'main',
        [string[]]$AllowedEnvironments,
        [switch]$OverrideWebconfig,
        [string]$Configuration,
        [switch]$Execute,
        [string]$RequestedBy,
        # Definicion de entorno ad hoc (worktree efimero) que viaja en la orden:
        # sustituye a la config central para ESTA ejecucion. Mismo dominio de
        # confianza: quien escribe la orden tambien puede editar environments.json.
        [psobject]$EnvironmentDef
    )

    $ErrorActionPreference = 'Stop'

    if (-not (Get-Command Get-PublishConfig -ErrorAction SilentlyContinue)) {
        $maybeCfg = Join-Path $PSScriptRoot '..\config\config.ps1'
        if (Test-Path $maybeCfg) { . $maybeCfg }
    }

    if ($EnvironmentDef) {
        foreach ($campo in 'name', 'origin', 'destination') {
            if (-not $EnvironmentDef.$campo) { throw "EnvironmentDef sin '$campo'." }
        }
        if ($EnvironmentDef.name -ne $Environment) {
            throw "Environment '$Environment' no coincide con EnvironmentDef.name '$($EnvironmentDef.name)'."
        }
        if ($Environment -in @('prod', 'staging')) { throw "Nombre de entorno ad hoc no permitido: '$Environment'." }
        $centrales = Get-AllowedEnvironments
        if ($Environment -in $centrales) {
            throw "El entorno ad hoc '$Environment' colisiona con uno de environments.json."
        }
    }
    else {
        $AllowedEnvironments = Get-AllowedEnvironments -AllowedEnvironments $AllowedEnvironments
        if ($Environment -notin $AllowedEnvironments) {
            throw "Entorno no permitido: '$Environment'. Permitidos: $($AllowedEnvironments -join ', ')"
        }
    }
    if ($Branch -notmatch '^[A-Za-z0-9._/+\-]+$') {
        throw "Rama con formato inválido: '$Branch'"
    }

    # Pre-check de admin en modo real: fallar aquí (antes del checkout) con un
    # mensaje accionable, en vez de dejar que Publish reviente a medias.
    if ($Execute) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            throw ("El publish requiere privilegios de administrador (parar el app pool y swap de IIS) " +
                   "y el proceso actual NO está elevado. Arranca el dashboard/consola como administrador, " +
                   "o registra el runner con una cuenta con permisos de admin.")
        }
    }

    $cfg = if ($EnvironmentDef) { $EnvironmentDef } else { Get-PublishConfig -Environment $Environment }
    $repo = Split-Path ($cfg.origin.TrimEnd('\', '/')) -Parent

    $pubArgs = @{ Environment = $Environment }
    if ($EnvironmentDef) {
        # Con entorno ad hoc, Publish recibe las rutas explicitas y no consulta
        # la config central (donde este entorno no existe).
        $pubArgs.ProjectPath = $cfg.origin
        $pubArgs.Destination = $cfg.destination
        if ($cfg.appPool) { $pubArgs.AppPoolName = $cfg.appPool }
        if ($cfg.templateSite) { $pubArgs.TemplateSite = [string]$cfg.templateSite }
        if ($cfg.hostName) { $pubArgs.HostName = [string]$cfg.hostName }
        elseif ($cfg.siteUrl) { $pubArgs.HostName = ([Uri][string]$cfg.siteUrl).Host }
        if ($cfg.databaseMap) { $pubArgs.DatabaseMap = $cfg.databaseMap }
    }
    if ($OverrideWebconfig) { $pubArgs.OverrideWebconfig = $true }
    if ($Configuration) { $pubArgs.Configuration = $Configuration }
    if ($RequestedBy) { $pubArgs.RequestedBy = $RequestedBy }

    $plan = [pscustomobject]@{
        environment       = $Environment
        branch            = $Branch
        requestedBy       = $RequestedBy
        repo              = $repo
        origin            = $cfg.origin
        destination       = $cfg.destination
        overrideWebconfig = [bool]$OverrideWebconfig
        configuration     = if ($Configuration) { $Configuration } else { 'Release (default)' }
        provision         = if ($cfg.templateSite) { "site desde plantilla '$($cfg.templateSite)' si no existe" } else { '-' }
        mode              = if ($Execute) { 'EXECUTE' } else { 'DRY-RUN' }
    }

    Write-Host "== Plan de despliegue ==" -ForegroundColor Cyan
    ($plan | Format-List | Out-String).Trim() | Write-Host

    if (-not $Execute) {
        Write-Host "DRY-RUN: no se toca el repo ni se publica. Repite con -Execute para ejecutar." -ForegroundColor Yellow
        return $plan
    }

    Write-Host "Checkout de '$Branch' en $repo..." -ForegroundColor Yellow
    # La tarea programada corre -NonInteractive con stdin nulo: un prompt de git
    # (host key SSH, credenciales, passphrase) se quedaría colgado para siempre y
    # sin rastro. Se fuerza modo batch para que falle con error visible; el host
    # key de un remoto nuevo se acepta a la primera (TOFU) y se persiste.
    $gitEnvPrev = @{ GIT_TERMINAL_PROMPT = $env:GIT_TERMINAL_PROMPT; GIT_SSH_COMMAND = $env:GIT_SSH_COMMAND }
    $env:GIT_TERMINAL_PROMPT = '0'
    if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new' }
    try {
        & git -C $repo fetch --prune
        if ($LASTEXITCODE) { throw "git fetch falló (código $LASTEXITCODE). Si pide credenciales u host key, ejecuta 'git -C $repo fetch' una vez a mano con el mismo usuario." }
        & git -C $repo checkout $Branch
        if ($LASTEXITCODE) { throw "git checkout falló (código $LASTEXITCODE)." }
        & git -C $repo pull --ff-only
        if ($LASTEXITCODE) { throw "git pull falló (código $LASTEXITCODE)." }
    }
    finally {
        $env:GIT_TERMINAL_PROMPT = $gitEnvPrev.GIT_TERMINAL_PROMPT
        $env:GIT_SSH_COMMAND = $gitEnvPrev.GIT_SSH_COMMAND
    }

    Publish @pubArgs
    return $plan
}

function Read-PublishOrder {
    <#
    .SYNOPSIS
        Lee y valida un fichero de orden de publicación (publish-order.json).

    .DESCRIPTION
        Formato de la orden: JSON con `environment` y `branch` obligatorios y
        opcionalmente `execute` (por defecto false = dry-run) y `overrideWebconfig`.
        La orden la escribe un proceso sin privilegios y la consume la tarea
        elevada 'Publish Local' (tools\Run-PublishOrder.ps1); esta función hace la
        validación de formato y la lista blanca de entornos / revalidación de la
        rama las aplica después Invoke-DeployOrder (defensa en profundidad).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "No hay orden de publicación en '$Path'."
    }
    $raw = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    # Tipo de orden: 'publish' (por defecto) o 'update' (actualizar el propio
    # módulo en el servidor: git pull + reinstalar + reiniciar el listener).
    $kind = if ($raw.kind) { [string]$raw.kind } else { 'publish' }
    if ($kind -notin @('publish', 'update')) { throw "Tipo de orden desconocido: '$kind'." }
    if ($kind -eq 'update') {
        return [pscustomobject]@{
            kind        = 'update'
            environment = ''
            branch      = ''
            execute     = $true
            overrideWebconfig = $false
            runId       = [string]$raw.runId
            requestedBy = [string]$raw.requestedBy
            environmentDef = $null
        }
    }
    if (-not $raw.environment) { throw "La orden no indica 'environment'." }
    if (-not $raw.branch) { throw "La orden no indica 'branch'." }
    if ($raw.branch -notmatch '^[A-Za-z0-9._/+\-]+$') {
        throw "Rama con formato inválido en la orden: '$($raw.branch)'"
    }

    if ($raw.environmentDef) {
        foreach ($campo in 'name', 'origin', 'destination') {
            if (-not $raw.environmentDef.$campo) { throw "environmentDef sin '$campo' en la orden." }
        }
        if ($raw.environmentDef.name -ne $raw.environment) {
            throw "La orden es incoherente: environment '$($raw.environment)' != environmentDef.name '$($raw.environmentDef.name)'."
        }
    }

    [pscustomobject]@{
        kind              = 'publish'
        environment       = [string]$raw.environment
        branch            = [string]$raw.branch
        execute           = [bool]$raw.execute
        overrideWebconfig = [bool]$raw.overrideWebconfig
        runId             = [string]$raw.runId
        requestedBy       = [string]$raw.requestedBy
        environmentDef    = $raw.environmentDef
    }
}

function Get-RequesterIdentity {
    # Quién pide la publicación, como EQUIPO\usuario del proceso actual. Es el
    # valor por defecto de -RequestedBy en toda la cadena: quien lo recibe de
    # fuera (endpoint, cola, orden) conserva el recibido y solo cae aquí si falta.
    "$env:COMPUTERNAME\$env:USERNAME"
}

function Get-PublishDataDir {
    # Carpeta de intercambio entre el proceso SIN privilegios (que deja la orden)
    # y la tarea elevada 'Publish Local' (que la consume).
    param([string]$DataDir)
    if ($DataDir) { return $DataDir }
    Join-Path $env:ProgramData 'PublishToIIS'
}

function Get-AllowedEnvironments {
    # Lista blanca por defecto: entornos de config salvo prod/staging.
    param([string[]]$AllowedEnvironments)
    if ($AllowedEnvironments) { return $AllowedEnvironments }

    $cfgFile = Join-Path $PSScriptRoot '..\config\environments.json'
    $names = (Get-Content $cfgFile -Raw | ConvertFrom-Json).environments.PSObject.Properties.Name
    @($names | Where-Object { $_ -notin @('prod', 'staging') })
}

function Read-AdHocEnvironment {
    <#
    .SYNOPSIS
        Lee y valida un fichero de entorno ad hoc (worktrees efímeros).

    .DESCRIPTION
        Un entorno ad hoc es un JSON con la MISMA forma que una entrada de
        environments.json más su `name`: sirve para publicar desde un worktree
        efímero sin ensuciar la config central. Por convención el fichero vive en
        la raíz del propio worktree (p. ej. `.publish-env.json`).

        Reglas: `name`, `origin` y `destination` obligatorios; el nombre NO puede
        coincidir con un entorno de environments.json (para eso está la config
        central) ni ser prod/staging.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { throw "No existe el fichero de entorno ad hoc: '$Path'" }
    $def = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach ($campo in 'name', 'origin', 'destination') {
        if (-not $def.$campo) { throw "El entorno ad hoc '$Path' no define '$campo'." }
    }
    if ($def.name -in @('prod', 'staging')) { throw "Nombre de entorno ad hoc no permitido: '$($def.name)'." }

    $cfgFile = Join-Path $PSScriptRoot '..\config\environments.json'
    if (Test-Path $cfgFile) {
        $centrales = (Get-Content $cfgFile -Raw | ConvertFrom-Json).environments.PSObject.Properties.Name
        if ($def.name -in $centrales) {
            throw "El entorno ad hoc '$($def.name)' colisiona con uno de environments.json: usa la config central o cambia el nombre."
        }
    }
    return $def
}

function Write-PublishOrder {
    <#
    .SYNOPSIS
        Deja escrita una orden de publicación (publish-order.json). NO requiere privilegios.

    .DESCRIPTION
        Es la mitad sin privilegios del flujo: valida entorno y rama con las mismas
        reglas que Invoke-DeployOrder y escribe la orden que consumirá la tarea
        elevada 'Publish Local'. Cada orden lleva un `runId` que la tarea devuelve
        en el resultado, para poder distinguirlo del de la ejecución anterior.

    .OUTPUTS
        PSCustomObject con `path` (fichero de orden) y `runId`.
    #>
    [CmdletBinding()]
    param(
        [string]$Environment,
        [Parameter(Mandatory)][string]$Branch,
        [switch]$Execute,
        [switch]$OverrideWebconfig,
        [string[]]$AllowedEnvironments,
        # Entorno ad hoc para worktrees efimeros (ver Read-AdHocEnvironment): la
        # definicion viaja DENTRO de la orden y no toca environments.json.
        [string]$EnvironmentFile,
        [string]$DataDir,
        [string]$RunId = [Guid]::NewGuid().ToString(),
        [string]$RequestedBy
    )

    $ErrorActionPreference = 'Stop'

    $envDef = $null
    if ($EnvironmentFile) {
        $envDef = Read-AdHocEnvironment -Path $EnvironmentFile
        if ($Environment -and $Environment -ne $envDef.name) {
            throw "-Environment '$Environment' no coincide con el name '$($envDef.name)' de '$EnvironmentFile'."
        }
        $Environment = $envDef.name
    }
    elseif (-not $Environment) {
        throw 'Indica -Environment (config central) o -EnvironmentFile (entorno ad hoc).'
    }
    else {
        $allowed = Get-AllowedEnvironments -AllowedEnvironments $AllowedEnvironments
        if ($Environment -notin $allowed) {
            throw "Entorno no permitido: '$Environment'. Permitidos: $($allowed -join ', ')"
        }
    }
    if ($Branch -notmatch '^[A-Za-z0-9._/+\-]+$') {
        throw "Rama con formato inválido: '$Branch'"
    }

    $dir = Get-PublishDataDir -DataDir $DataDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Intento de limpiar el resultado anterior. GOTCHA: el fichero lo escribe la
    # tarea ELEVADA y con la ACL por defecto de %ProgramData% un proceso sin
    # privilegios no puede borrarlo (sí sobrescribirlo la tarea). Por eso esto es
    # best-effort y la garantía de verdad es el -Since de Wait-PublishResult.
    Remove-Item (Join-Path $dir 'publish-order.result.json') -Force -ErrorAction SilentlyContinue

    $orderPath = Join-Path $dir 'publish-order.json'
    $orden = [ordered]@{
        environment       = $Environment
        branch            = $Branch
        execute           = [bool]$Execute
        overrideWebconfig = [bool]$OverrideWebconfig
        runId             = $RunId
        requestedBy       = if ($RequestedBy) { $RequestedBy } else { Get-RequesterIdentity }
        requestedAt       = (Get-Date).ToString('o')
    }
    if ($envDef) { $orden.environmentDef = $envDef }
    [pscustomobject]$orden | ConvertTo-Json -Compress -Depth 6 | Set-Content $orderPath -Encoding UTF8

    [pscustomobject]@{ path = $orderPath; runId = $RunId }
}

function Write-UpdateOrder {
    <#
    .SYNOPSIS
        Deja escrita una orden de ACTUALIZACIÓN del módulo (publish-order.json, kind=update). Sin privilegios.

    .DESCRIPTION
        Misma mecánica que Write-PublishOrder, otro tipo de orden: la tarea
        elevada 'Publish Local' la consume y, en vez de publicar, hace
        Update-PublishToIIS (git pull + reinstalar) y reinicia el listener del
        endpoint para que cargue el código nuevo. Es lo que permite actualizar el
        publicador de un servidor sin entrar por RDP.
    #>
    [CmdletBinding()]
    param(
        [string]$DataDir,
        [string]$RunId = [Guid]::NewGuid().ToString(),
        [string]$RequestedBy
    )
    $ErrorActionPreference = 'Stop'
    $dir = Get-PublishDataDir -DataDir $DataDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Remove-Item (Join-Path $dir 'publish-order.result.json') -Force -ErrorAction SilentlyContinue

    $orderPath = Join-Path $dir 'publish-order.json'
    [pscustomobject]@{
        kind        = 'update'
        runId       = $RunId
        requestedBy = if ($RequestedBy) { $RequestedBy } else { Get-RequesterIdentity }
        requestedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress | Set-Content $orderPath -Encoding UTF8

    [pscustomobject]@{ path = $orderPath; runId = $RunId }
}

function Start-PublishTask {
    # Dispara la tarea elevada. Se aísla en su propia función para poder
    # sustituirla en los tests y para dejar un único punto de cambio si algún día
    # el disparo llega por otra vía (runner de CI, servicio, ...).
    param(
        [string]$TaskName = 'Publish Local',
        [string]$DataDir
    )
    $out = & schtasks /run /tn $TaskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("No se pudo disparar la tarea '$TaskName' (código $LASTEXITCODE): $out. " +
               "Regístrala una vez con tools\Register-PublishLocalTask.ps1.")
    }
}

function Write-PublishLogTail {
    # Vuelca lo que la tarea haya escrito en el transcript desde la última vez.
    # Se abre con ReadWrite|Delete a propósito: el fichero lo tiene abierto
    # Start-Transcript y con el share por defecto no se podría leer en caliente.
    param(
        [string]$Path,
        [long]$Position,
        # Marca de creación del transcript que ya habíamos visto: si cambia, la
        # tarea ha empezado uno nuevo y hay que leerlo desde el principio
        [ref]$Stamp
    )

    if (-not (Test-Path $Path)) { return $Position }
    try {
        $creado = (Get-Item $Path).CreationTimeUtc
        if ($Stamp -and $Stamp.Value -ne $creado) {
            $Stamp.Value = $creado
            $Position = 0
        }

        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                              [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            # Si el fichero ha encogido, es un transcript nuevo: volver al principio
            if ($fs.Length -lt $Position) { $Position = 0 }
            if ($fs.Length -eq $Position) { return $Position }
            [void]$fs.Seek($Position, [IO.SeekOrigin]::Begin)
            $reader = New-Object IO.StreamReader($fs)
            $texto = $reader.ReadToEnd()
            $Position = $fs.Length
        }
        finally { $fs.Dispose() }

        foreach ($linea in $texto -split "`r?`n") {
            if ($linea.Trim()) { Write-Host "  | $linea" -ForegroundColor DarkGray }
        }
    }
    catch {
        # Un fallo leyendo el log no puede tumbar la espera del resultado
        Write-Verbose "No se pudo leer el log: $($_.Exception.Message)"
    }
    return $Position
}

function Wait-PublishResult {
    <#
    .SYNOPSIS
        Espera a que la tarea elevada deje el resultado de la publicación.

    .DESCRIPTION
        Con -RunId (o, en su defecto, -Since) descarta el resultado de una
        ejecución anterior: imprescindible porque el fichero de resultado lo
        escribe la tarea elevada y quien la dispara (sin privilegios) no siempre
        puede borrarlo antes. El runId es determinista; el reloj no, con dos
        llamadas seguidas.
    #>
    [CmdletBinding()]
    param(
        [string]$DataDir,
        [string]$RunId,
        [datetime]$Since,
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 2,
        # La tarea escribe su consola en publish-order.log, no en la nuestra: sin
        # esto, quien la dispara se queda mirando una pantalla muda durante todo
        # el publish. Con -Quiet se calla y solo devuelve el resultado.
        [switch]$Quiet
    )

    $dir = Get-PublishDataDir -DataDir $DataDir
    $resultPath = Join-Path $dir 'publish-order.result.json'
    $logPath = Join-Path $dir 'publish-order.log'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    # Arrancar al final del log existente: lo de la ejecución anterior no es
    # nuestro y volcarlo confunde. Cuando la tarea cree su transcript, el cambio
    # de fecha de creación hace que se lea desde el principio.
    $logPos = 0
    $logStamp = [datetime]::MinValue
    if (Test-Path $logPath) {
        $logPos = (Get-Item $logPath).Length
        $logStamp = (Get-Item $logPath).CreationTimeUtc
    }
    if (-not $Quiet) { $PollSeconds = 1 }

    while ((Get-Date) -lt $deadline) {
        if (-not $Quiet) { $logPos = Write-PublishLogTail -Path $logPath -Position $logPos -Stamp ([ref]$logStamp) }
        if (Test-Path $resultPath) {
            # Pequeña espera defensiva: el fichero puede estar a medio escribir.
            try {
                $result = Get-Content $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $fresh = $true
                if ($RunId) {
                    $fresh = ($result.runId -eq $RunId)
                }
                elseif ($PSBoundParameters.ContainsKey('Since')) {
                    $stamp = if ($result.finishedAt) { [datetime]$result.finishedAt }
                             else { (Get-Item $resultPath).LastWriteTime }
                    $fresh = $stamp -ge $Since
                }
                if ($fresh) {
                    # Vaciar lo que la tarea escribió justo antes de terminar
                    if (-not $Quiet) { [void](Write-PublishLogTail -Path $logPath -Position $logPos -Stamp ([ref]$logStamp)) }
                    return $result
                }
            }
            catch { Start-Sleep -Milliseconds 300 }
        }
        Start-Sleep -Seconds $PollSeconds
    }

    throw "Timeout de $TimeoutSeconds s esperando el resultado en '$resultPath'. Revisa publish-order.log."
}

function Request-Publish {
    <#
    .SYNOPSIS
        Pide una publicación SIN privilegios: escribe la orden, dispara la tarea
        elevada 'Publish Local' y espera el resultado.

    .DESCRIPTION
        Es exactamente la llamada que hará el job de CI o el dashboard: no eleva
        nada, solo deja la orden y la dispara. Todo el trabajo con privilegios
        (checkout, MSBuild, parada del app pool y swap) lo hace la tarea.

        La tarea hay que registrarla UNA vez en la máquina, con privilegios:
        tools\Register-PublishLocalTask.ps1 (con -Unattended en servidores).

    .EXAMPLE
        Request-Publish -Environment devecoand1 -Branch main_deploy-20260730 -Execute

    .EXAMPLE
        Request-Publish -Environment devecoand1 -Branch main_deploy-20260730 -NoWait
    #>
    [CmdletBinding()]
    param(
        [string]$Environment,
        [Parameter(Mandatory)][string]$Branch,
        [switch]$Execute,
        [switch]$OverrideWebconfig,
        [string[]]$AllowedEnvironments,
        # Fichero de entorno ad hoc para worktrees efimeros (convencion:
        # `.publish-env.json` en la raiz del worktree). Ver Read-AdHocEnvironment.
        [string]$EnvironmentFile,
        [string]$TaskName = 'Publish Local',
        [string]$DataDir,
        [switch]$NoWait,
        [int]$TimeoutSeconds = 900,
        # Por defecto se va volcando el log de la tarea mientras publica, para no
        # dejar la consola muda durante minutos
        [switch]$Quiet,
        [string]$RequestedBy
    )

    $ErrorActionPreference = 'Stop'

    $order = Write-PublishOrder -Environment $Environment -Branch $Branch `
        -Execute:$Execute -OverrideWebconfig:$OverrideWebconfig `
        -AllowedEnvironments $AllowedEnvironments -EnvironmentFile $EnvironmentFile `
        -DataDir $DataDir -RequestedBy $RequestedBy
    if (-not $Environment) { $Environment = (Get-Content $order.path -Raw | ConvertFrom-Json).environment }

    $dir = Get-PublishDataDir -DataDir $DataDir
    Write-Host "Orden escrita en $($order.path) (runId $($order.runId))" -ForegroundColor Gray
    Write-Host "Disparando la tarea '$TaskName'..." -ForegroundColor Yellow
    Start-PublishTask -TaskName $TaskName -DataDir $dir

    if ($NoWait) {
        return [pscustomobject]@{
            status      = 'triggered'
            environment = $Environment
            branch      = $Branch
            runId       = $order.runId
            orderPath   = $order.path
            logPath     = Join-Path $dir 'publish-order.log'
        }
    }

    $result = Wait-PublishResult -DataDir $dir -RunId $order.runId -TimeoutSeconds $TimeoutSeconds -Quiet:$Quiet
    $color = if ($result.status -eq 'ok') { 'Green' } else { 'Red' }
    Write-Host "RESULT: $($result.status) $($result.message)" -ForegroundColor $color
    return $result
}

function Request-ModuleUpdate {
    <#
    .SYNOPSIS
        Pide, SIN privilegios, que la tarea elevada actualice el módulo en esta máquina.

    .DESCRIPTION
        Escribe la orden kind=update, dispara 'Publish Local' y espera el
        resultado. La tarea hace git fetch/pull --ff-only del repo del módulo,
        reinstala (Install.ps1) y reinicia la tarea 'Publish Endpoint' para que el
        listener cargue el código nuevo; el drenador y la propia tarea importan el
        módulo en cada ejecución, así que ya van con la versión nueva. Es la mitad
        local de Request-RemoteUpdate.

    .EXAMPLE
        Request-ModuleUpdate
    #>
    [CmdletBinding()]
    param(
        [string]$TaskName = 'Publish Local',
        [string]$DataDir,
        [switch]$NoWait,
        [int]$TimeoutSeconds = 600,
        [switch]$Quiet,
        [string]$RequestedBy
    )
    $ErrorActionPreference = 'Stop'

    $order = Write-UpdateOrder -DataDir $DataDir -RequestedBy $RequestedBy
    $dir = Get-PublishDataDir -DataDir $DataDir
    Write-Host "Orden de actualización escrita en $($order.path) (runId $($order.runId))" -ForegroundColor Gray
    Write-Host "Disparando la tarea '$TaskName'..." -ForegroundColor Yellow
    Start-PublishTask -TaskName $TaskName -DataDir $dir

    if ($NoWait) {
        return [pscustomobject]@{ status = 'triggered'; kind = 'update'; runId = $order.runId; orderPath = $order.path }
    }

    $result = Wait-PublishResult -DataDir $dir -RunId $order.runId -TimeoutSeconds $TimeoutSeconds -Quiet:$Quiet
    $color = if ($result.status -eq 'ok') { 'Green' } else { 'Red' }
    Write-Host "RESULT: $($result.status) $($result.message)" -ForegroundColor $color
    return $result
}

function Get-PublishToIISRepo {
    <#
    .SYNOPSIS
        Resuelve la ruta de la copia de trabajo git del módulo, sin tener que saberla.

    .DESCRIPTION
        Por orden: el parámetro -RepoPath, la variable PUBLISHTOIIS_REPO que deja
        Install.ps1 (de proceso o de máquina) y, si el módulo se ha importado
        directamente desde el repo, su propia carpeta. Si no hay nada, el error
        dice qué hacer en vez de dejar al usuario adivinando.
    #>
    [CmdletBinding()]
    param([string]$RepoPath)

    $candidates = @(
        $RepoPath
        $env:PUBLISHTOIIS_REPO
        [Environment]::GetEnvironmentVariable('PUBLISHTOIIS_REPO', 'Machine')
        # $PSScriptRoot es <repo>\src cuando se importa desde la copia de trabajo
        (Split-Path $PSScriptRoot -Parent)
    )

    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c '.git'))) { return (Resolve-Path $c).Path }
    }

    throw ("No se encontró la copia de trabajo git del módulo. Pásala con -RepoPath, " +
           "o ejecuta Install.ps1 desde el repo una vez para fijar PUBLISHTOIIS_REPO.")
}

function Register-PublishTask {
    <#
    .SYNOPSIS
        Registra la tarea elevada 'Publish Local' sin tener que saber dónde está el repo.

    .DESCRIPTION
        Envoltorio de tools\Register-PublishLocalTask.ps1: localiza la copia de
        trabajo con Get-PublishToIISRepo y le pasa los argumentos. Es el único
        paso del flujo que necesita privilegios (el script se auto-eleva).

    .EXAMPLE
        Register-PublishTask -Unattended   # servidor: corre sin sesión iniciada
    #>
    [CmdletBinding()]
    param(
        [string]$RepoPath,
        [string]$TaskName = 'Publish Local',
        [switch]$Unattended
    )

    $repo = Get-PublishToIISRepo -RepoPath $RepoPath
    $script = Join-Path $repo 'tools\Register-PublishLocalTask.ps1'
    if (-not (Test-Path $script)) {
        throw "No se encontró $script. ¿La copia de trabajo está en una rama sin tools\?"
    }

    & $script -TaskName $TaskName -Unattended:$Unattended
}

function Update-PublishToIIS {
    <#
    .SYNOPSIS
        Actualiza el módulo: hace git fetch + pull en el repo origen y reinstala.

    .DESCRIPTION
        Localiza la copia de trabajo git (por -RepoPath o la variable de entorno
        PUBLISHTOIIS_REPO que guarda Install.ps1), trae los últimos cambios y
        ejecuta Install.ps1 para copiar la nueva versión a los módulos de PowerShell.

    .EXAMPLE
        Update-PublishToIIS

    .EXAMPLE
        Update-PublishToIIS -RepoPath 'C:\Users\me\git\PublishToIIS'
    #>
    [CmdletBinding()]
    param(
        [string]$RepoPath
    )

    $ErrorActionPreference = "Stop"

    # Parámetro explícito, PUBLISHTOIIS_REPO o el propio repo si se importó de él
    $RepoPath = Get-PublishToIISRepo -RepoPath $RepoPath

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { throw "git no está en el PATH." }

    Write-Host "Updating repo: $RepoPath" -ForegroundColor Cyan

    & git -C $RepoPath fetch --prune
    if ($LASTEXITCODE -ne 0) { throw "git fetch falló con código $LASTEXITCODE." }

    & git -C $RepoPath pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull falló con código $LASTEXITCODE." }

    Write-Host "Repo actualizado. Reinstalando módulo..." -ForegroundColor Yellow

    $installScript = Join-Path $RepoPath 'Install.ps1'
    if (-not (Test-Path $installScript)) { throw "No se encontró Install.ps1 en $RepoPath." }

    # Install.ps1 se auto-eleva (UAC) si hace falta; -NoPause evita la espera de tecla
    & $installScript -NoPause

    Write-Host "Update completado." -ForegroundColor Green
}

# ─── Endpoint HTTP de despliegue (Fase 3: disparo remoto) ────────────────────
# Un listener HTTP que corre EN el servidor destino, solo en 127.0.0.1, detrás
# de un site de IIS que hace reverse proxy (ARR) con hostname + TLS propios
# (p. ej. https://deployments-76.economitza.com). Es la mitad SIN privilegios
# del flujo, la misma que Request-Publish: escribe la orden y dispara la tarea
# elevada 'Publish Local'; todo el trabajo con privilegios lo hace la tarea.
# Ver docs\deploy-endpoint.md para el montaje completo del servidor.

function Get-ManifestVersion {
    # ModuleVersion del manifiesto leído como texto (mismo regex que
    # tools\Push-Release.ps1): no depende de Import-PowerShellDataFile ni de
    # evaluar el .psd1. $null si no se encuentra.
    param([Parameter(Mandatory)][string]$ManifestPath)
    if (-not (Test-Path $ManifestPath)) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($ManifestPath), "ModuleVersion\s*=\s*'(\d+\.\d+\.\d+)'")
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}

function Get-PublishToIISVersionInfo {
    <#
    .SYNOPSIS
        Versión, commit y rama del código del módulo que está ejecutando esta sesión.

    .DESCRIPTION
        La versión se lee del manifiesto que acompaña a ESTE fichero (el que se ha
        importado: la copia de trabajo si las tareas importan desde el repo, o la
        copia instalada). El commit y la rama salen de la copia de trabajo git si
        se localiza (Get-PublishToIISRepo). Es lo que devuelve GET /api/version y
        lo que Request-RemoteUpdate compara antes y después de actualizar.
    #>
    [CmdletBinding()]
    param([string]$RepoPath)
    $codeRoot = Split-Path $PSScriptRoot -Parent
    $version = Get-ManifestVersion -ManifestPath (Join-Path $codeRoot 'PublishToIIS.psd1')
    $repo = $null; $commit = $null; $branch = $null
    try { $repo = Get-PublishToIISRepo -RepoPath $RepoPath } catch { }
    if ($repo -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $commit = [string](& git -C $repo rev-parse --short HEAD 2>$null)
        $branch = [string](& git -C $repo rev-parse --abbrev-ref HEAD 2>$null)
    }
    [pscustomobject]@{
        version  = $version
        commit   = $commit
        branch   = $branch
        codeRoot = $codeRoot
        repo     = $repo
        host     = $env:COMPUTERNAME
    }
}

function Get-DeployEndpointTokenPath {
    param([string]$DataDir)
    Join-Path (Get-PublishDataDir -DataDir $DataDir) 'api-token.txt'
}

function New-DeployEndpointToken {
    <#
    .SYNOPSIS
        Genera el token de API del endpoint y lo deja en %ProgramData%\PublishToIIS\api-token.txt.

    .DESCRIPTION
        256 bits de RNG criptográfico en hexadecimal. El fichero es la única
        credencial del endpoint: quien lo tenga puede ordenar despliegues, así
        que se copia UNA vez al cliente (variable PUBLISHTOIIS_API_TOKEN o
        remote-api-token.txt) y no viaja por ningún otro canal. Con -Force se
        rota (el token anterior deja de valer en cuanto el listener se reinicia).
    #>
    [CmdletBinding()]
    param(
        [string]$DataDir,
        [switch]$Force
    )
    $ErrorActionPreference = 'Stop'
    $path = Get-DeployEndpointTokenPath -DataDir $DataDir
    if ((Test-Path $path) -and -not $Force) {
        throw "Ya existe un token en '$path'. Repite con -Force para rotarlo."
    }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    Set-Content -Path $path -Value $token -Encoding Ascii -NoNewline
    $token
}

function Get-DeployEndpointToken {
    [CmdletBinding()]
    param([string]$DataDir)
    $path = Get-DeployEndpointTokenPath -DataDir $DataDir
    if (-not (Test-Path $path)) {
        throw "No hay token de API en '$path'. Genera uno con New-DeployEndpointToken."
    }
    (Get-Content $path -Raw).Trim()
}

function Test-DeployEndpointToken {
    # Comparación en tiempo constante: se comparan los SHA-256 de ambos tokens
    # byte a byte sin cortocircuito, de modo que el tiempo no dependa de en qué
    # posición difieren.
    param([string]$Presented, [string]$Expected)
    if (-not $Presented -or -not $Expected) { return $false }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $a = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Presented))
        $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Expected))
    }
    finally { $sha.Dispose() }
    $diff = 0
    for ($i = 0; $i -lt $a.Length; $i++) { $diff = $diff -bor ($a[$i] -bxor $b[$i]) }
    $diff -eq 0
}

function Add-DeployQueueItem {
    <#
    .SYNOPSIS
        Encola una orden de despliegue (no publica: la deja en la cola FIFO).

    .DESCRIPTION
        El endpoint nunca rechaza por "hay otra en marcha": mete cada orden en
        %ProgramData%\PublishToIIS\queue como un fichero cuyo nombre empieza por
        timestamp ordenable, de modo que el orden lexicográfico ES el orden de
        llegada. El drenador (Invoke-DeployQueueDrain) las procesa de una en una.
        Valida entorno (lista blanca) y rama con las mismas reglas del resto del
        flujo antes de encolar nada.

    .OUTPUTS
        PSCustomObject con `runId`, `position` (1 = primera de la cola) y `path`.
    #>
    [CmdletBinding()]
    param(
        [string]$Environment,
        [string]$Branch,
        [switch]$Execute,
        [switch]$OverrideWebconfig,
        [string[]]$AllowedEnvironments,
        [string]$DataDir,
        [string]$RunId = [Guid]::NewGuid().ToString(),
        [string]$RequestedBy,
        # 'publish' (entorno + rama) o 'update' (actualizar el módulo del
        # servidor; sin entorno ni rama). Van por la MISMA cola: así nunca se
        # actualiza el módulo a mitad de una publicación.
        [ValidateSet('publish', 'update')][string]$Kind = 'publish'
    )
    $ErrorActionPreference = 'Stop'

    if ($Kind -eq 'publish') {
        if (-not $Environment -or -not $Branch) { throw "Una orden de publicación necesita 'environment' y 'branch'." }
        $allowed = Get-AllowedEnvironments -AllowedEnvironments $AllowedEnvironments
        if ($Environment -notin $allowed) {
            throw "Entorno no permitido: '$Environment'. Permitidos: $($allowed -join ', ')"
        }
        if ($Branch -notmatch '^[A-Za-z0-9._/+\-]+$') {
            throw "Rama con formato inválido: '$Branch'"
        }
    }
    else {
        $Environment = ''
        $Branch = ''
        $Execute = $true
        $OverrideWebconfig = $false
    }

    $qdir = Join-Path (Get-PublishDataDir -DataDir $DataDir) 'queue'
    if (-not (Test-Path $qdir)) { New-Item -ItemType Directory -Path $qdir -Force | Out-Null }
    $ahead = @(Get-ChildItem $qdir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count

    # Orden FIFO por contador persistente, no por reloj: la resolución de
    # DateTime en Windows (~15 ms) haría colisionar dos altas seguidas y el
    # tiebreak por runId (aleatorio) romperia el orden de llegada. El contador es
    # monótono; el listener atiende las peticiones en serie, asi que no compiten.
    $seqFile = Join-Path $qdir '.seq'
    $seq = 0
    if (Test-Path $seqFile) { [void][int]::TryParse((Get-Content $seqFile -Raw).Trim(), [ref]$seq) }
    $seq++
    Set-Content $seqFile -Value $seq -Encoding Ascii
    # El prefijo cero-rellenado ordena lexicográficamente igual que numéricamente.
    $file = Join-Path $qdir ('{0:000000000000}-{1}.json' -f $seq, $RunId)
    [pscustomobject]@{
        kind              = $Kind
        environment       = [string]$Environment
        branch            = [string]$Branch
        execute           = [bool]$Execute
        overrideWebconfig = [bool]$OverrideWebconfig
        runId             = $RunId
        queuedAt          = (Get-Date).ToString('o')
        requestedBy       = if ($RequestedBy) { $RequestedBy } else { Get-RequesterIdentity }
    } | ConvertTo-Json -Compress | Set-Content $file -Encoding UTF8

    [pscustomobject]@{ runId = $RunId; position = $ahead + 1; path = $file }
}

function Get-DeployQueue {
    # Cola pendiente, en orden de proceso (position 1 = la siguiente en salir).
    [CmdletBinding()]
    param([string]$DataDir)
    $qdir = Join-Path (Get-PublishDataDir -DataDir $DataDir) 'queue'
    if (-not (Test-Path $qdir)) { return @() }
    $i = 0
    Get-ChildItem $qdir -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
        try { $o = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
        $i++
        [pscustomobject]@{
            position = $i; runId = $o.runId; kind = $(if ($o.kind) { [string]$o.kind } else { 'publish' })
            environment = $o.environment; branch = $o.branch; execute = [bool]$o.execute
            queuedAt = $o.queuedAt; requestedBy = $o.requestedBy
        }
    }
}

function Get-DeployResult {
    <#
    .SYNOPSIS
        Estado de un despliegue por runId: encolado, en marcha o terminado.

    .DESCRIPTION
        El drenador escribe results\<runId>.json (status running -> ok/error).
        Si aún no existe, se busca el runId en la cola para devolver 'queued' con
        su posición. Null si no se conoce ese runId (404 en el endpoint).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$DataDir
    )
    $dir = Get-PublishDataDir -DataDir $DataDir
    $resultFile = Join-Path $dir "results\$RunId.json"
    if (Test-Path $resultFile) {
        try { return Get-Content $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    foreach ($q in (Get-DeployQueue -DataDir $dir)) {
        if ($q.runId -eq $RunId) {
            return [pscustomobject]@{
                status = 'queued'; runId = $RunId; position = $q.position; kind = $q.kind
                environment = $q.environment; branch = $q.branch
            }
        }
    }
    $null
}

function Invoke-DeployQueueDrain {
    <#
    .SYNOPSIS
        Procesa la cola FIFO de despliegues, una orden a la vez.

    .DESCRIPTION
        Toma la orden más antigua, la marca 'running' en results\<runId>.json,
        la publica con Request-Publish (que dispara la tarea elevada 'Publish
        Local' y espera su resultado) y escribe el resultado final. Al ser el
        único que llama a Request-Publish en la vía remota, serializa los
        despliegues sin candados: nunca hay dos publicando a la vez. Una orden
        ilegible se aparta a .bad para no atascar la cola. Poda los resultados
        de más de 7 días.

    .OUTPUTS
        Número de órdenes procesadas en esta pasada.
    #>
    [CmdletBinding()]
    param(
        [string]$DataDir,
        [string]$TaskName = 'Publish Local',
        [int]$TimeoutSeconds = 1800,
        # Tope de órdenes por pasada (0 = drenar hasta vaciar). Los tests lo usan.
        [int]$MaxItems = 0
    )
    $ErrorActionPreference = 'Stop'
    $dir = Get-PublishDataDir -DataDir $DataDir
    $qdir = Join-Path $dir 'queue'
    $rdir = Join-Path $dir 'results'
    if (-not (Test-Path $qdir)) { return 0 }
    if (-not (Test-Path $rdir)) { New-Item -ItemType Directory -Path $rdir -Force | Out-Null }

    $processed = 0
    while ($true) {
        $next = Get-ChildItem $qdir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -First 1
        if (-not $next) { break }

        try { $order = Get-Content $next.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch {
            Move-Item $next.FullName "$($next.FullName).bad" -Force -ErrorAction SilentlyContinue
            continue
        }

        $resultFile = Join-Path $rdir ($order.runId + '.json')
        $requestedBy = [string]$order.requestedBy
        $kind = if ($order.kind) { [string]$order.kind } else { 'publish' }
        [pscustomobject]@{
            status = 'running'; runId = $order.runId; kind = $kind
            environment = $order.environment; branch = $order.branch
            requestedBy = $requestedBy; startedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content $resultFile -Encoding UTF8

        try {
            if ($kind -eq 'update') {
                $res = Request-ModuleUpdate -RequestedBy $requestedBy -TaskName $TaskName -TimeoutSeconds $TimeoutSeconds -Quiet
            }
            else {
                $res = Request-Publish -Environment ([string]$order.environment) -Branch ([string]$order.branch) `
                    -Execute:([bool]$order.execute) -OverrideWebconfig:([bool]$order.overrideWebconfig) `
                    -RequestedBy $requestedBy -TaskName $TaskName -TimeoutSeconds $TimeoutSeconds -Quiet
            }
            $final = [pscustomobject]@{
                status = $res.status; message = $res.message; runId = $order.runId; kind = $kind
                environment = $order.environment; branch = $order.branch; requestedBy = $requestedBy
                execute = [bool]$order.execute; finishedAt = (Get-Date).ToString('o')
            }
        }
        catch {
            $final = [pscustomobject]@{
                status = 'error'; message = $_.Exception.Message; runId = $order.runId; kind = $kind
                environment = $order.environment; branch = $order.branch; requestedBy = $requestedBy
                execute = [bool]$order.execute; finishedAt = (Get-Date).ToString('o')
            }
        }
        $final | ConvertTo-Json | Set-Content $resultFile -Encoding UTF8
        Remove-Item $next.FullName -Force -ErrorAction SilentlyContinue

        $processed++
        if ($MaxItems -gt 0 -and $processed -ge $MaxItems) { break }
    }

    Get-ChildItem $rdir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $processed
}

function Invoke-DeployEndpointRequest {
    <#
    .SYNOPSIS
        Atiende UNA petición del endpoint de despliegue y devuelve la respuesta.

    .DESCRIPTION
        Función pura (sin sockets) para poder probarla con Pester: recibe método,
        ruta, query, cuerpo y token presentado, y devuelve un objeto con `status`
        y `body` (JSON) o `text` (texto plano). Start-DeployEndpoint le pone el
        HttpListener delante.

        Rutas: GET /health (sin token) · GET /api/environments ·
        POST /api/publish {environment, branch, execute, overrideWebconfig} →
        202 con runId; la orden se ENCOLA (nunca se rechaza por otra en marcha) y
        el drenador la publica cuando le toca · POST /api/update {requestedBy} →
        202 con runId; encola la actualización del propio módulo (git pull +
        reinstalar + reiniciar el listener), por la MISMA cola que los publish ·
        GET /api/version (versión, commit y rama del código que sirve el endpoint) ·
        GET /api/result?runId=... (queued / running / ok / error) · GET /api/queue
        (cola pendiente) · GET /api/log (cola del transcript de la publicación en curso).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        [string]$Body = '',
        [string]$Token = '',
        [string]$ExpectedToken = '',
        [string]$DataDir,
        [string]$TaskName = 'Publish Local'
    )
    $ErrorActionPreference = 'Stop'
    $Method = $Method.ToUpperInvariant()

    if ($Method -eq 'GET' -and $Path -eq '/health') {
        return [pscustomobject]@{ status = 200; body = @{ ok = $true } }
    }
    if (-not (Test-DeployEndpointToken -Presented $Token -Expected $ExpectedToken)) {
        return [pscustomobject]@{ status = 401; body = @{ error = 'Token ausente o inválido (cabecera X-Api-Token).' } }
    }

    $dir = Get-PublishDataDir -DataDir $DataDir
    $logPath = Join-Path $dir 'publish-order.log'

    if ($Method -eq 'GET' -and $Path -eq '/api/environments') {
        return [pscustomobject]@{ status = 200; body = @{ environments = @(Get-AllowedEnvironments) } }
    }

    if ($Method -eq 'GET' -and $Path -eq '/api/queue') {
        return [pscustomobject]@{ status = 200; body = @{ queue = @(Get-DeployQueue -DataDir $dir) } }
    }

    if ($Method -eq 'GET' -and $Path -eq '/api/version') {
        return [pscustomobject]@{ status = 200; body = (Get-PublishToIISVersionInfo) }
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/update') {
        $req = $null
        if ($Body) {
            try { $req = $Body | ConvertFrom-Json }
            catch { return [pscustomobject]@{ status = 400; body = @{ error = 'Cuerpo JSON inválido.' } } }
        }
        $requestedBy = (([string]$req.requestedBy) -replace '[^\p{L}\p{N}_.@\\\- ]', '').Trim()
        if ($requestedBy.Length -gt 128) { $requestedBy = $requestedBy.Substring(0, 128) }
        try {
            $item = Add-DeployQueueItem -Kind update -RequestedBy $requestedBy -DataDir $dir
        }
        catch {
            return [pscustomobject]@{ status = 400; body = @{ error = $_.Exception.Message } }
        }
        return [pscustomobject]@{ status = 202; body = @{
            status = 'queued'; kind = 'update'; runId = $item.runId; position = $item.position
            current = (Get-PublishToIISVersionInfo)
            result = "/api/result?runId=$($item.runId)"
        } }
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/publish') {
        try { $req = $Body | ConvertFrom-Json }
        catch { return [pscustomobject]@{ status = 400; body = @{ error = 'Cuerpo JSON inválido.' } } }
        if (-not $req -or -not $req.environment -or -not $req.branch) {
            return [pscustomobject]@{ status = 400; body = @{ error = "Faltan 'environment' y/o 'branch' en la orden." } }
        }
        # Solo un booleano JSON de verdad ejecuta: un string "false" convertido a
        # [bool] sería $true, así que cualquier otro tipo degrada a dry-run.
        $execute = ($req.execute -is [bool]) -and $req.execute
        $override = ($req.overrideWebconfig -is [bool]) -and $req.overrideWebconfig
        # Quién lo pidió lo declara el cliente (EQUIPO\usuario del que hizo clic).
        # Acaba en JSON y en deploy-info.json: se deja solo texto plano y corto.
        $requestedBy = (([string]$req.requestedBy) -replace '[^\p{L}\p{N}_.@\\\- ]', '').Trim()
        if ($requestedBy.Length -gt 128) { $requestedBy = $requestedBy.Substring(0, 128) }
        try {
            $item = Add-DeployQueueItem -Environment ([string]$req.environment) -Branch ([string]$req.branch) `
                -Execute:$execute -OverrideWebconfig:$override -RequestedBy $requestedBy -DataDir $dir
        }
        catch {
            return [pscustomobject]@{ status = 400; body = @{ error = $_.Exception.Message } }
        }
        # 202 sin publicar: la orden queda encolada y el drenador la coge cuando
        # no haya otra en marcha. El cliente sigue el estado por /api/result.
        return [pscustomobject]@{ status = 202; body = @{
            status = 'queued'; runId = $item.runId; position = $item.position
            environment = [string]$req.environment; branch = [string]$req.branch
            execute = $execute; overrideWebconfig = $override
            result = "/api/result?runId=$($item.runId)"
        } }
    }

    if ($Method -eq 'GET' -and $Path -eq '/api/result') {
        $runId = [string]$Query['runId']
        if (-not $runId) {
            return [pscustomobject]@{ status = 400; body = @{ error = "Falta el parámetro 'runId'." } }
        }
        $info = Get-DeployResult -RunId $runId -DataDir $dir
        if ($null -eq $info) {
            return [pscustomobject]@{ status = 404; body = @{ error = "runId desconocido: '$runId'." } }
        }
        return [pscustomobject]@{ status = 200; body = $info }
    }

    if ($Method -eq 'GET' -and $Path -eq '/api/log') {
        if (-not (Test-Path $logPath)) {
            return [pscustomobject]@{ status = 404; body = @{ error = 'Aún no hay transcript de publicación.' } }
        }
        # Mismo share que Write-PublishLogTail: el transcript puede estar abierto
        # por la tarea en este momento.
        $fs = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                              [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            $from = [Math]::Max(0, $fs.Length - 65536)
            [void]$fs.Seek($from, [IO.SeekOrigin]::Begin)
            $reader = New-Object IO.StreamReader($fs)
            $tail = $reader.ReadToEnd()
        }
        finally { $fs.Dispose() }
        return [pscustomobject]@{ status = 200; text = $tail }
    }

    [pscustomobject]@{ status = 404; body = @{ error = "Ruta desconocida: $Method $Path" } }
}

function Start-DeployEndpoint {
    <#
    .SYNOPSIS
        Arranca el listener HTTP del endpoint de despliegue (bloqueante).

    .DESCRIPTION
        Escucha SOLO en 127.0.0.1: a internet se expone a través del site de IIS
        que hace reverse proxy con hostname y TLS (ver docs\deploy-endpoint.md).
        Corre sin privilegios a propósito — lo único que hace es escribir la
        orden y disparar la tarea elevada 'Publish Local', igual que
        Request-Publish. Cada petición queda auditada en endpoint.log (fecha,
        IP de X-Forwarded-For, ruta, status).
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 8770,
        [string]$DataDir,
        [string]$TaskName = 'Publish Local',
        # Tarea que drena la cola: se dispara al encolar (bajo demanda), en vez de
        # tener un proceso sondeando. Consumo en reposo: solo este listener,
        # bloqueado en GetContext (~0 CPU).
        [string]$DrainerTaskName = 'Publish Queue Drainer'
    )
    $ErrorActionPreference = 'Stop'

    $dir = Get-PublishDataDir -DataDir $DataDir
    $token = Get-DeployEndpointToken -DataDir $dir
    $auditPath = Join-Path $dir 'endpoint.log'

    $listener = New-Object Net.HttpListener
    $prefix = "http://127.0.0.1:$Port/"
    $listener.Prefixes.Add($prefix)
    $listener.Start()
    Write-Host "Endpoint de despliegue escuchando en $prefix (tarea destino: '$TaskName')" -ForegroundColor Green

    try {
        while ($listener.IsListening) {
            try { $ctx = $listener.GetContext() }
            catch { if ($listener.IsListening) { continue } else { break } }

            $req = $ctx.Request
            $res = $ctx.Response
            # Datos de auditoria capturados ANTES de cerrar la respuesta: sobre un
            # contexto ya cerrado, RemoteEndPoint lanza (era lo que tumbaba el
            # listener tras la primera peticion). La IP real llega en
            # X-Forwarded-For (la pone ARR); en loopback, del RemoteEndPoint.
            $method = $req.HttpMethod
            $rawUrl = $req.RawUrl
            $ip = [string]$req.Headers['X-Forwarded-For']
            if (-not $ip) { try { $ip = $req.RemoteEndPoint.Address.ToString() } catch { $ip = '?' } }
            $status = 500

            # Ningun fallo de UNA peticion puede tumbar el listener: todo el manejo
            # va en try/catch y el Close y la auditoria en el suyo.
            try {
                try {
                    $body = ''
                    if ($req.HasEntityBody) {
                        if ($req.ContentLength64 -gt 65536) { throw 'Cuerpo demasiado grande (maximo 64 KB).' }
                        $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    }
                    $query = @{}
                    foreach ($k in $req.QueryString.AllKeys) { if ($k) { $query[$k] = $req.QueryString[$k] } }

                    $out = Invoke-DeployEndpointRequest -Method $method -Path $req.Url.AbsolutePath `
                        -Query $query -Body $body -Token ([string]$req.Headers['X-Api-Token']) `
                        -ExpectedToken $token -DataDir $dir -TaskName $TaskName
                }
                catch {
                    $out = [pscustomobject]@{ status = 500; body = @{ error = $_.Exception.Message } }
                }

                if ($out.PSObject.Properties['text'] -and $null -ne $out.text) {
                    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$out.text)
                    $res.ContentType = 'text/plain; charset=utf-8'
                }
                else {
                    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $out.body -Depth 5))
                    $res.ContentType = 'application/json; charset=utf-8'
                }
                $status = $out.status
                $res.StatusCode = $out.status
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            catch { }
            finally { try { $res.Close() } catch { } }

            try {
                "$((Get-Date).ToString('s')) | $ip | $method $rawUrl | $status" |
                    Add-Content $auditPath -Encoding UTF8
            }
            catch { }

            # Orden encolada (202): disparar el drenador bajo demanda. No hay proceso
            # sondeando; el drenador procesa y termina. Su MultipleInstances=Queue
            # cubre las órdenes que lleguen mientras drena.
            if ($status -eq 202) {
                try { Start-PublishTask -TaskName $DrainerTaskName -DataDir $dir }
                catch {
                    "$((Get-Date).ToString('s')) | - | no se pudo disparar el drenador '$DrainerTaskName': $($_.Exception.Message)" |
                        Add-Content $auditPath -Encoding UTF8 -ErrorAction SilentlyContinue
                }
            }
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }
}

function Get-DeployTokenStorePath {
    param([Parameter(Mandatory)][string]$Server, [string]$DataDir)
    Join-Path (Join-Path (Get-PublishDataDir -DataDir $DataDir) 'tokens') ($Server + '.txt')
}

function Set-DeployToken {
    <#
    .SYNOPSIS
        Guarda el token del endpoint de un servidor de publicación, por su nombre.

    .DESCRIPTION
        Registro del CLIENTE en %ProgramData%\PublishToIIS\tokens\<server>.txt
        (fuera de git). Con N servidores, cada uno tiene su token: el dashboard y
        Request-RemotePublish lo resuelven por el `server` de cada entorno. Sin
        -Token se pide por consola.

    .EXAMPLE
        Set-DeployToken -Server deployments-76 -Token 1a2b...
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [string]$Token,
        [string]$DataDir
    )
    $ErrorActionPreference = 'Stop'
    if (-not $Token) { $Token = (Read-Host "Token del endpoint de '$Server'").Trim() }
    if (-not $Token) { throw 'Token vacío.' }
    $path = Get-DeployTokenStorePath -Server $Server -DataDir $DataDir
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $path -Value $Token -Encoding Ascii -NoNewline
    Write-Host "Token de '$Server' guardado en $path" -ForegroundColor Green
}

function Get-DeployToken {
    <#
    .SYNOPSIS
        Token del endpoint de un servidor (del registro por servidor).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server, [string]$DataDir)
    $path = Get-DeployTokenStorePath -Server $Server -DataDir $DataDir
    if (Test-Path $path) {
        $t = (Get-Content $path -Raw).Trim()
        if ($t) { return $t }
    }
    # Compat: token único legacy en la variable de entorno.
    if ($env:PUBLISHTOIIS_API_TOKEN) { return $env:PUBLISHTOIIS_API_TOKEN.Trim() }
    $null
}

function Get-DeployServerUrl {
    <#
    .SYNOPSIS
        endpointUrl de un servidor, leído de la sección `servers` de environments.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server)
    $cfgFile = Join-Path $PSScriptRoot '..\config\environments.json'
    $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
    $srv = $cfg.servers.$Server
    if (-not $srv -or -not $srv.endpointUrl) {
        throw "El servidor '$Server' no está en la sección 'servers' de environments.json."
    }
    $srv.endpointUrl
}

function Request-RemotePublish {
    <#
    .SYNOPSIS
        Pide una publicación a un servidor remoto a través de su endpoint HTTP.

    .DESCRIPTION
        Es el Request-Publish de larga distancia: POST a /api/publish del
        endpoint (p. ej. https://deployments-76.economitza.com) y sondeo de
        /api/result hasta el desenlace. El token sale de -Token o de la
        variable de entorno PUBLISHTOIIS_API_TOKEN.

    .EXAMPLE
        Request-RemotePublish -Url https://deployments-76.economitza.com -Environment devecoesp1 -Branch main_deploy-20260901 -Execute
    #>
    [CmdletBinding()]
    param(
        # Servidor de publicación (sección `servers` del config): de él se resuelven
        # la URL del endpoint y el token registrado. Alternativa a pasar -Url/-Token.
        [string]$Server,
        [string]$Url,
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$Branch,
        [switch]$Execute,
        [switch]$OverrideWebconfig,
        [string]$Token,
        [switch]$NoWait,
        [int]$TimeoutSeconds = 1200,
        [int]$PollSeconds = 5,
        # Quién pide: por defecto EQUIPO\usuario de este proceso. Viaja en la orden
        # hasta deploy-info.json (requestedBy) para saber quién disparó cada deploy.
        [string]$RequestedBy = (Get-RequesterIdentity)
    )
    $ErrorActionPreference = 'Stop'

    if ($Server) {
        if (-not $Url)   { $Url = Get-DeployServerUrl -Server $Server }
        if (-not $Token) { $Token = Get-DeployToken -Server $Server }
    }
    if (-not $Url) { throw 'Falta -Url o -Server (para resolver la URL del endpoint).' }
    if (-not $Token) { $Token = $env:PUBLISHTOIIS_API_TOKEN }
    if (-not $Token) {
        throw "Sin token: pásalo con -Token, o usa -Server <nombre> con el token registrado (Set-DeployToken -Server <nombre>), o define PUBLISHTOIIS_API_TOKEN."
    }
    $Url = $Url.TrimEnd('/')
    $headers = @{ 'X-Api-Token' = $Token }
    $payload = @{
        environment = $Environment; branch = $Branch
        execute = [bool]$Execute; overrideWebconfig = [bool]$OverrideWebconfig
        requestedBy = $RequestedBy
    } | ConvertTo-Json -Compress

    try {
        $trig = Invoke-RestMethod -Method Post -Uri "$Url/api/publish" -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($payload))
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "El endpoint rechazó la orden: $detail"
    }
    $pos = if ($trig.position -gt 1) { " (posición $($trig.position) en la cola)" } else { '' }
    Write-Host "Orden encolada (runId $($trig.runId))$pos. La publicación corre en el servidor." -ForegroundColor Gray
    if ($NoWait) { return $trig }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastStatus = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        try {
            $result = Invoke-RestMethod -Method Get -Uri "$Url/api/result?runId=$($trig.runId)" -Headers $headers
        }
        catch { continue } # un poll fallido (red, proxy reciclando) no aborta la espera
        if ($result.status -eq 'ok' -or $result.status -eq 'error') {
            $color = if ($result.status -eq 'ok') { 'Green' } else { 'Red' }
            Write-Host "RESULT: $($result.status) $($result.message)" -ForegroundColor $color
            return $result
        }
        # queued / running: eco del cambio de estado sin spamear cada poll
        if ($result.status -ne $lastStatus) {
            $lastStatus = $result.status
            $detalle = if ($result.status -eq 'queued') { " (posición $($result.position))" } else { '' }
            Write-Host "  ...$($result.status)$detalle" -ForegroundColor DarkGray
        }
    }
    throw "Timeout de $TimeoutSeconds s esperando el resultado (runId $($trig.runId)). Mira $Url/api/log con el token."
}

function Resolve-RemoteEndpoint {
    # URL y token del endpoint a partir de -Server (sección `servers` + token
    # registrado), de -Url/-Token explícitos o de PUBLISHTOIIS_API_TOKEN.
    param([string]$Server, [string]$Url, [string]$Token)
    if ($Server) {
        if (-not $Url)   { $Url = Get-DeployServerUrl -Server $Server }
        if (-not $Token) { $Token = Get-DeployToken -Server $Server }
    }
    if (-not $Url) { throw 'Falta -Url o -Server (para resolver la URL del endpoint).' }
    if (-not $Token) { $Token = $env:PUBLISHTOIIS_API_TOKEN }
    if (-not $Token) {
        throw "Sin token: pásalo con -Token, o usa -Server <nombre> con el token registrado (Set-DeployToken -Server <nombre>), o define PUBLISHTOIIS_API_TOKEN."
    }
    [pscustomobject]@{ url = $Url.TrimEnd('/'); headers = @{ 'X-Api-Token' = $Token } }
}

function Get-RemoteDeployVersion {
    <#
    .SYNOPSIS
        Versión, commit y rama del publicador que corre en un servidor remoto (GET /api/version).

    .EXAMPLE
        Get-RemoteDeployVersion -Server deployments-76
    #>
    [CmdletBinding()]
    param(
        [string]$Server,
        [string]$Url,
        [string]$Token,
        [int]$TimeoutSec = 15
    )
    $ErrorActionPreference = 'Stop'
    $ep = Resolve-RemoteEndpoint -Server $Server -Url $Url -Token $Token
    Invoke-RestMethod -Method Get -Uri "$($ep.url)/api/version" -Headers $ep.headers -TimeoutSec $TimeoutSec
}

function Request-RemoteUpdate {
    <#
    .SYNOPSIS
        Actualiza el publicador de un servidor remoto a través de su endpoint HTTP, sin RDP.

    .DESCRIPTION
        POST a /api/update: el servidor encola la actualización en la misma cola
        FIFO que los despliegues (nunca se actualiza a mitad de un publish), la
        tarea elevada hace git pull --ff-only + reinstalación y reinicia el
        listener del endpoint. Esta función sondea /api/result hasta el desenlace
        —tolerando el corte de unos segundos del reinicio— y termina consultando
        /api/version para enseñar el salto de versión.

        Requisito único: que el servidor ya corra una versión con soporte de
        /api/update (0.5.0 o superior). La primera vez se actualiza por RDP.

    .EXAMPLE
        Request-RemoteUpdate -Server deployments-76
    #>
    [CmdletBinding()]
    param(
        [string]$Server,
        [string]$Url,
        [string]$Token,
        [switch]$NoWait,
        [int]$TimeoutSeconds = 600,
        [int]$PollSeconds = 5,
        [string]$RequestedBy = (Get-RequesterIdentity)
    )
    $ErrorActionPreference = 'Stop'
    $ep = Resolve-RemoteEndpoint -Server $Server -Url $Url -Token $Token

    $payload = @{ requestedBy = $RequestedBy } | ConvertTo-Json -Compress
    try {
        $trig = Invoke-RestMethod -Method Post -Uri "$($ep.url)/api/update" -Headers $ep.headers `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($payload))
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "El endpoint rechazó la orden de actualización: $detail (¿el servidor aún corre una versión sin /api/update? Entonces esta vez toca RDP + Update-PublishToIIS)."
    }
    $antes = if ($trig.current) { "$($trig.current.version) ($($trig.current.commit))" } else { '?' }
    $pos = if ($trig.position -gt 1) { " (posición $($trig.position) en la cola)" } else { '' }
    Write-Host "Actualización encolada (runId $($trig.runId))$pos. Versión actual del servidor: $antes." -ForegroundColor Gray
    if ($NoWait) { return $trig }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastStatus = ''
    $result = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        try {
            $result = Invoke-RestMethod -Method Get -Uri "$($ep.url)/api/result?runId=$($trig.runId)" -Headers $ep.headers -TimeoutSec 15
        }
        catch { continue } # el listener se reinicia al final: unos polls fallidos son normales
        if ($result.status -eq 'ok' -or $result.status -eq 'error') { break }
        if ($result.status -ne $lastStatus) {
            $lastStatus = $result.status
            Write-Host "  ...$($result.status)" -ForegroundColor DarkGray
        }
        $result = $null
    }
    if (-not $result) { throw "Timeout de $TimeoutSeconds s esperando el resultado (runId $($trig.runId))." }

    $color = if ($result.status -eq 'ok') { 'Green' } else { 'Red' }
    Write-Host "RESULT: $($result.status) $($result.message)" -ForegroundColor $color
    if ($result.status -ne 'ok') { return $result }

    # El listener acaba de reiniciarse con el código nuevo: darle unos segundos.
    $despues = $null
    $verDeadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $verDeadline) {
        try { $despues = Get-RemoteDeployVersion -Url $ep.url -Token $ep.headers['X-Api-Token']; break }
        catch { Start-Sleep -Seconds 3 }
    }
    if ($despues) {
        Write-Host "Servidor $($despues.host): $antes -> $($despues.version) ($($despues.commit), rama $($despues.branch))" -ForegroundColor Green
        $result | Add-Member -NotePropertyName version -NotePropertyValue $despues -Force
    }
    else {
        Write-Warning "El endpoint no ha vuelto a responder en 90 s tras el reinicio; comprueba la tarea 'Publish Endpoint' en el servidor."
    }
    return $result
}

function Register-DeployEndpoint {
    <#
    .SYNOPSIS
        Prepara el servidor para el despliegue remoto, sin tener que saber dónde
        está el repo ni ejecutar scripts desde una carpeta concreta.

    .DESCRIPTION
        Localiza la copia de trabajo con Get-PublishToIISRepo y ejecuta
        tools\Register-DeployEndpointTask.ps1: genera el token de API, reserva la
        URL ACL del loopback y registra + arranca las tareas 'Publish Endpoint' y
        'Publish Queue Drainer'. El script se auto-eleva por UAC. Tras importar el
        módulo, basta `Register-DeployEndpoint` desde cualquier ruta.

    .EXAMPLE
        Register-DeployEndpoint
    .EXAMPLE
        Register-DeployEndpoint -Port 8771
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 8770,
        [string]$RepoPath
    )
    $repo = Get-PublishToIISRepo -RepoPath $RepoPath
    $script = Join-Path $repo 'tools\Register-DeployEndpointTask.ps1'
    if (-not (Test-Path $script)) {
        throw "No se encontró $script. Actualiza el repo (Update-PublishToIIS) para traer las tools del endpoint."
    }
    & $script -Port $Port
}

function Test-DeployEndpoint {
    <#
    .SYNOPSIS
        Comprueba que el listener del endpoint responde (GET /health en loopback).

    .DESCRIPTION
        Devuelve $true si el endpoint está vivo. Es la comprobación rápida tras
        Register-DeployEndpoint. No pasa por IIS: prueba directamente el loopback,
        así aísla "el listener corre" de "el reverse proxy está bien montado".
    #>
    [CmdletBinding()]
    param([int]$Port = 8770)
    $url = "http://127.0.0.1:$Port/health"
    try {
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 5
        if ($r.ok) {
            Write-Host "Endpoint OK en $url" -ForegroundColor Green
            return $true
        }
        Write-Warning "Respuesta inesperada de $url."
        return $false
    }
    catch {
        Write-Warning "El endpoint no responde en $url ($($_.Exception.Message)). ¿Arrancó la tarea 'Publish Endpoint'?"
        return $false
    }
}

function Register-DeployProxySite {
    <#
    .SYNOPSIS
        Crea el site IIS reverse-proxy que expone el endpoint, en una llamada.

    .DESCRIPTION
        Envoltorio de tools\Register-DeployProxySite.ps1 (localiza el repo con
        Get-PublishToIISRepo y se auto-eleva por UAC): habilita ARR, deja el
        web.config con la regla de reescritura al listener y el site con binding
        http:80, y **reusa el certificado** que ya cubra el host (el wildcard
        *.economitza.com que ya sirve otros sites) para el https:443 — no saca uno
        nuevo. Requiere URL Rewrite + ARR instalados.

    .EXAMPLE
        Register-DeployProxySite -HostName deployments-76.economitza.com
    .EXAMPLE
        Register-DeployProxySite -HostName deployments-76.economitza.com -FromSite devecoesp1 -RestrictToIp 88.1.2.3
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 8770,
        [string]$SiteName = 'deployments-endpoint',
        [string]$RestrictToIp,
        [string]$CertThumbprint,
        [string]$FromSite,
        [switch]$DryRun,
        [string]$RepoPath
    )
    $repo = Get-PublishToIISRepo -RepoPath $RepoPath
    $script = Join-Path $repo 'tools\Register-DeployProxySite.ps1'
    if (-not (Test-Path $script)) {
        throw "No se encontró $script. Actualiza el repo (Update-PublishToIIS) para traer las tools del endpoint."
    }
    $splat = @{ HostName = $HostName; Port = $Port; SiteName = $SiteName }
    if ($RestrictToIp)   { $splat.RestrictToIp = $RestrictToIp }
    if ($CertThumbprint) { $splat.CertThumbprint = $CertThumbprint }
    if ($FromSite)       { $splat.FromSite = $FromSite }
    if ($DryRun)         { $splat.DryRun = $true }
    & $script @splat
}

function Register-Dashboard {
    <#
    .SYNOPSIS
        Registra el dashboard como servicio: tarea 'Publish Dashboard', cliente
        SIN privilegios, headless (pythonw, sin consola), que arranca con Windows.

    .DESCRIPTION
        Envoltorio de tools\Register-DashboardTask.ps1 (localiza el repo y se
        auto-eleva por UAC solo para registrar). Quita la dependencia de tener una
        consola PowerShell abierta: el dashboard pasa a ser un cliente que solo
        toca los endpoints, sin elevación.

    .EXAMPLE
        Register-Dashboard
    #>
    [CmdletBinding()]
    param([int]$Port = 8765, [string]$RepoPath)
    $repo = Get-PublishToIISRepo -RepoPath $RepoPath
    $script = Join-Path $repo 'tools\Register-DashboardTask.ps1'
    if (-not (Test-Path $script)) {
        throw "No se encontró $script. Actualiza el repo (Update-PublishToIIS)."
    }
    & $script -Port $Port
}

Set-Alias -Name Publish-Update -Value Update-PublishToIIS

Export-ModuleMember -Function Publish, Get-MSBuild, Get-PublishConfig, Update-PublishToIIS, Protect-ProductionWebConfig, New-DeployInfo, Invoke-DeployOrder, Read-PublishOrder, Write-PublishOrder, Read-AdHocEnvironment, Wait-PublishResult, Request-Publish, Get-PublishToIISRepo, Register-PublishTask, New-DeployEndpointToken, Get-DeployEndpointToken, Invoke-DeployEndpointRequest, Start-DeployEndpoint, Request-RemotePublish, Add-DeployQueueItem, Get-DeployQueue, Get-DeployResult, Invoke-DeployQueueDrain, Register-DeployEndpoint, Test-DeployEndpoint, Register-DeployProxySite, Set-DeployToken, Get-DeployToken, Get-DeployServerUrl, Register-Dashboard, Initialize-IisSite, Set-ConnectionStringCatalog, Write-UpdateOrder, Request-ModuleUpdate, Get-PublishToIISVersionInfo, Get-RemoteDeployVersion, Request-RemoteUpdate -Alias Publish-Update
