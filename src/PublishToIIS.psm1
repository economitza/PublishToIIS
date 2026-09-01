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

function New-DeployInfo {
    <#
    .SYNOPSIS
        Escribe deploy-info.json (rama, commit, fechas, entorno) en el directorio publicado.

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
        [string]$Environment
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
        publishedBy = "$env:USERNAME@$env:COMPUTERNAME"
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
        [switch]$OverrideWebconfig
    )

    # Check for admin privileges
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "This script requires administrator privileges. Please run PowerShell as Administrator."
    }

    $ErrorActionPreference = "Stop"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "ENTER Publish function" -ForegroundColor Cyan

    # If ProjectPath, Destination or AppPoolName not provided, load from central config
    if (-not $ProjectPath -or -not $Destination -or -not $AppPoolName) {
        if (-not (Get-Command Get-PublishConfig -ErrorAction SilentlyContinue)) {
            # try to dot-source config if available relative to module
            $maybeCfg = Join-Path $PSScriptRoot '..\config\config.ps1'
            if (Test-Path $maybeCfg) { . $maybeCfg }
        }

        if (Get-Command Get-PublishConfig -ErrorAction SilentlyContinue) {
            $cfg = Get-PublishConfig -Environment $Environment
            if (-not $ProjectPath -and $cfg.origin) { $ProjectPath = $cfg.origin }
            if (-not $Destination -and $cfg.destination) { $Destination = $cfg.destination }
            if (-not $AppPoolName -and $cfg.appPool) { $AppPoolName = $cfg.appPool }
            # By convention the app pool matches the environment name; use it when not set explicitly
            if (-not $AppPoolName -and $cfg._environment) { $AppPoolName = $cfg._environment }
        }
    }

    $msbuild = Get-MSBuild
    Write-Host "Using MSBuild: $msbuild" -ForegroundColor Yellow

    $parentDir = Split-Path $Destination -Parent
    $siteName = Split-Path $Destination -Leaf

    # Default the app pool to the site (destination) name when not configured
    if (-not $AppPoolName) { $AppPoolName = $siteName }

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

        # Sello de versión del despliegue: viaja dentro de releasing/ y por tanto con el swap
        $deployInfoEnv = if ($Environment) { $Environment } else { $siteName }
        $deployInfo = New-DeployInfo -ProjectPath $ProjectPath -OutputDir $releasingDir -Environment $deployInfoEnv
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
        [switch]$Execute
    )

    $ErrorActionPreference = 'Stop'

    if (-not (Get-Command Get-PublishConfig -ErrorAction SilentlyContinue)) {
        $maybeCfg = Join-Path $PSScriptRoot '..\config\config.ps1'
        if (Test-Path $maybeCfg) { . $maybeCfg }
    }

    $AllowedEnvironments = Get-AllowedEnvironments -AllowedEnvironments $AllowedEnvironments

    if ($Environment -notin $AllowedEnvironments) {
        throw "Entorno no permitido: '$Environment'. Permitidos: $($AllowedEnvironments -join ', ')"
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

    $cfg = Get-PublishConfig -Environment $Environment
    $repo = Split-Path ($cfg.origin.TrimEnd('\', '/')) -Parent

    $pubArgs = @{ Environment = $Environment }
    if ($OverrideWebconfig) { $pubArgs.OverrideWebconfig = $true }
    if ($Configuration) { $pubArgs.Configuration = $Configuration }

    $plan = [pscustomobject]@{
        environment       = $Environment
        branch            = $Branch
        repo              = $repo
        origin            = $cfg.origin
        destination       = $cfg.destination
        overrideWebconfig = [bool]$OverrideWebconfig
        configuration     = if ($Configuration) { $Configuration } else { 'Release (default)' }
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
    if (-not $raw.environment) { throw "La orden no indica 'environment'." }
    if (-not $raw.branch) { throw "La orden no indica 'branch'." }
    if ($raw.branch -notmatch '^[A-Za-z0-9._/+\-]+$') {
        throw "Rama con formato inválido en la orden: '$($raw.branch)'"
    }

    [pscustomobject]@{
        environment       = [string]$raw.environment
        branch            = [string]$raw.branch
        execute           = [bool]$raw.execute
        overrideWebconfig = [bool]$raw.overrideWebconfig
        runId             = [string]$raw.runId
    }
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
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$Branch,
        [switch]$Execute,
        [switch]$OverrideWebconfig,
        [string[]]$AllowedEnvironments,
        [string]$DataDir,
        [string]$RunId = [Guid]::NewGuid().ToString()
    )

    $ErrorActionPreference = 'Stop'

    $allowed = Get-AllowedEnvironments -AllowedEnvironments $AllowedEnvironments
    if ($Environment -notin $allowed) {
        throw "Entorno no permitido: '$Environment'. Permitidos: $($allowed -join ', ')"
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
    [pscustomobject]@{
        environment       = $Environment
        branch            = $Branch
        execute           = [bool]$Execute
        overrideWebconfig = [bool]$OverrideWebconfig
        runId             = $RunId
        requestedBy       = "$env:USERNAME@$env:COMPUTERNAME"
        requestedAt       = (Get-Date).ToString('o')
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
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$Branch,
        [switch]$Execute,
        [switch]$OverrideWebconfig,
        [string[]]$AllowedEnvironments,
        [string]$TaskName = 'Publish Local',
        [string]$DataDir,
        [switch]$NoWait,
        [int]$TimeoutSeconds = 900,
        # Por defecto se va volcando el log de la tarea mientras publica, para no
        # dejar la consola muda durante minutos
        [switch]$Quiet
    )

    $ErrorActionPreference = 'Stop'

    $order = Write-PublishOrder -Environment $Environment -Branch $Branch `
        -Execute:$Execute -OverrideWebconfig:$OverrideWebconfig `
        -AllowedEnvironments $AllowedEnvironments -DataDir $DataDir

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
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$Branch,
        [switch]$Execute,
        [switch]$OverrideWebconfig,
        [string[]]$AllowedEnvironments,
        [string]$DataDir,
        [string]$RunId = [Guid]::NewGuid().ToString()
    )
    $ErrorActionPreference = 'Stop'

    $allowed = Get-AllowedEnvironments -AllowedEnvironments $AllowedEnvironments
    if ($Environment -notin $allowed) {
        throw "Entorno no permitido: '$Environment'. Permitidos: $($allowed -join ', ')"
    }
    if ($Branch -notmatch '^[A-Za-z0-9._/+\-]+$') {
        throw "Rama con formato inválido: '$Branch'"
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
        environment       = [string]$Environment
        branch            = [string]$Branch
        execute           = [bool]$Execute
        overrideWebconfig = [bool]$OverrideWebconfig
        runId             = $RunId
        queuedAt          = (Get-Date).ToString('o')
        requestedBy       = "$env:USERNAME@$env:COMPUTERNAME"
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
            position = $i; runId = $o.runId; environment = $o.environment
            branch = $o.branch; execute = [bool]$o.execute; queuedAt = $o.queuedAt
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
                status = 'queued'; runId = $RunId; position = $q.position
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
        [pscustomobject]@{
            status = 'running'; runId = $order.runId
            environment = $order.environment; branch = $order.branch
            startedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content $resultFile -Encoding UTF8

        try {
            $res = Request-Publish -Environment ([string]$order.environment) -Branch ([string]$order.branch) `
                -Execute:([bool]$order.execute) -OverrideWebconfig:([bool]$order.overrideWebconfig) `
                -TaskName $TaskName -TimeoutSeconds $TimeoutSeconds -Quiet
            $final = [pscustomobject]@{
                status = $res.status; message = $res.message; runId = $order.runId
                environment = $order.environment; branch = $order.branch
                execute = [bool]$order.execute; finishedAt = (Get-Date).ToString('o')
            }
        }
        catch {
            $final = [pscustomobject]@{
                status = 'error'; message = $_.Exception.Message; runId = $order.runId
                environment = $order.environment; branch = $order.branch
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
        el drenador la publica cuando le toca · GET /api/result?runId=... (queued
        / running / ok / error) · GET /api/queue (cola pendiente) ·
        GET /api/log (cola del transcript de la publicación en curso).
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
        try {
            $item = Add-DeployQueueItem -Environment ([string]$req.environment) -Branch ([string]$req.branch) `
                -Execute:$execute -OverrideWebconfig:$override -DataDir $dir
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
        [string]$TaskName = 'Publish Local'
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
            $ctx = $listener.GetContext()
            $req = $ctx.Request
            $res = $ctx.Response
            try {
                try {
                    $body = ''
                    if ($req.HasEntityBody) {
                        if ($req.ContentLength64 -gt 65536) { throw 'Cuerpo demasiado grande (máximo 64 KB).' }
                        $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    }
                    $query = @{}
                    foreach ($k in $req.QueryString.AllKeys) { if ($k) { $query[$k] = $req.QueryString[$k] } }

                    $out = Invoke-DeployEndpointRequest -Method $req.HttpMethod -Path $req.Url.AbsolutePath `
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
                $res.StatusCode = $out.status
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            finally { $res.Close() }

            # Auditoría: la IP real del cliente llega en X-Forwarded-For (la pone ARR)
            $ip = [string]$req.Headers['X-Forwarded-For']
            if (-not $ip) { $ip = $req.RemoteEndPoint.Address.ToString() }
            "$((Get-Date).ToString('s')) | $ip | $($req.HttpMethod) $($req.RawUrl) | $($out.status)" |
                Add-Content $auditPath -Encoding UTF8
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }
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
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$Branch,
        [switch]$Execute,
        [switch]$OverrideWebconfig,
        [string]$Token,
        [switch]$NoWait,
        [int]$TimeoutSeconds = 1200,
        [int]$PollSeconds = 5
    )
    $ErrorActionPreference = 'Stop'

    if (-not $Token) { $Token = $env:PUBLISHTOIIS_API_TOKEN }
    if (-not $Token) {
        throw 'Sin token: pásalo con -Token o define PUBLISHTOIIS_API_TOKEN (es el api-token.txt del servidor).'
    }
    $Url = $Url.TrimEnd('/')
    $headers = @{ 'X-Api-Token' = $Token }
    $payload = @{
        environment = $Environment; branch = $Branch
        execute = [bool]$Execute; overrideWebconfig = [bool]$OverrideWebconfig
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

Set-Alias -Name Publish-Update -Value Update-PublishToIIS

Export-ModuleMember -Function Publish, Get-MSBuild, Get-PublishConfig, Update-PublishToIIS, Protect-ProductionWebConfig, New-DeployInfo, Invoke-DeployOrder, Read-PublishOrder, Write-PublishOrder, Wait-PublishResult, Request-Publish, Get-PublishToIISRepo, Register-PublishTask, New-DeployEndpointToken, Get-DeployEndpointToken, Invoke-DeployEndpointRequest, Start-DeployEndpoint, Request-RemotePublish, Add-DeployQueueItem, Get-DeployQueue, Get-DeployResult, Invoke-DeployQueueDrain, Register-DeployEndpoint, Test-DeployEndpoint -Alias Publish-Update
