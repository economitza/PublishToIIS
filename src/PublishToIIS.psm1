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

    $branch = $null; $commit = $null; $commitDate = $null

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $insideRepo = (& git -C $ProjectPath rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -eq 0 -and "$insideRepo".Trim() -eq 'true') {
            $branch = ("$(& git -C $ProjectPath rev-parse --abbrev-ref HEAD 2>$null)").Trim()
            $commit = ("$(& git -C $ProjectPath rev-parse --short HEAD 2>$null)").Trim()
            $commitDate = ("$(& git -C $ProjectPath show -s --format=%cI HEAD 2>$null)").Trim()
        }
    }

    if (-not $commit) {
        Write-Warning "New-DeployInfo: '$ProjectPath' no es una copia de trabajo git (o git no está disponible); se escribe el sello sin rama/commit."
        $branch = $null; $commit = $null; $commitDate = $null
    }

    $info = [pscustomobject]@{
        branch      = $branch
        commit      = $commit
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

    # Resolver la ruta del repo: parámetro explícito o variable de entorno guardada en la instalación
    if (-not $RepoPath) {
        $RepoPath = $env:PUBLISHTOIIS_REPO
        if (-not $RepoPath) {
            $RepoPath = [Environment]::GetEnvironmentVariable('PUBLISHTOIIS_REPO', 'Machine')
        }
    }

    if (-not $RepoPath) {
        throw "No se encontró la ruta del repo. Pásala con -RepoPath o reinstala con Install.ps1 para fijar PUBLISHTOIIS_REPO."
    }
    if (-not (Test-Path $RepoPath)) {
        throw "La ruta del repo no existe: $RepoPath"
    }
    if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
        throw "La ruta '$RepoPath' no es una copia de trabajo git (falta .git)."
    }

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

Set-Alias -Name Publish-Update -Value Update-PublishToIIS

Export-ModuleMember -Function Publish, Get-MSBuild, Get-PublishConfig, Update-PublishToIIS, Protect-ProductionWebConfig, New-DeployInfo -Alias Publish-Update
