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

function Publish {
    param(
        [string]$ProjectPath,
        [string]$Destination,
        [string]$Environment,
        [string]$AppPoolName,
        [string]$Configuration = "Release",
        [hashtable]$MSBuildProperties = @{},
        [switch]$KeepPrevious
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

        # Preservar web.config de producción, si existe.
        # Esto mantiene settings locales/IIS/productivos fuera del artefacto publicado.
        if (Test-Path $targetWebConfig) {
            Copy-Item $targetWebConfig $releasingWebConfig -Force
            Write-Host "Production web.config copied into releasing directory" -ForegroundColor Green
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

Export-ModuleMember -Function Publish, Get-MSBuild, Get-PublishConfig
