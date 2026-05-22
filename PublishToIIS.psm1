function Get-MSBuild {
    # 1. Intento desde PATH
    $cmd = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    # 2. Rutas típicas Visual Studio
    $candidates = @(
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }

    throw "MSBuild not found (PATH or Visual Studio install required)"
}

function Publish {
    param(
        [string]$ProjectPath = "C:\Users\joaquimms\Documents\git\20260430\central-de-compres\CentralCompres\CentralCompres.csproj",
        [string]$Destination  = "C:\inetpub\wwwroot\economitza_espana"
    )

    Write-Host "ENTER Publish function" -ForegroundColor Cyan

    # Resolver MSBuild dinámicamente
    $msbuild = Get-MSBuild
    Write-Host "Using MSBuild: $msbuild" -ForegroundColor Yellow

    # Parem IIS
    iisreset /stop

    # 1. Rutas derivadas
    $parentDir = Split-Path $Destination -Parent
    $tempDir = Join-Path $parentDir "temp_publish_backup"
    $backupWebConfig = Join-Path $tempDir "web.config"
    $targetWebConfig = Join-Path $Destination "web.config"

    if (!(Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir | Out-Null
    }

    # 2. Backup web.config
    if (Test-Path $targetWebConfig) {
        Copy-Item $targetWebConfig $backupWebConfig -Force
    }

    try {
        Write-Host "Running MSBuild publish..." -ForegroundColor Yellow

        & $msbuild $ProjectPath `
            /p:Configuration=Release `
            /p:DeployOnBuild=true `
            /p:PublishUrl="$Destination" `
            /p:WebPublishMethod=FileSystem `
            /p:DeployTarget=WebPublish `
            /v:minimal

        Write-Host "MSBuild completed" -ForegroundColor Green

        # Restaurar web.config
        if (Test-Path $backupWebConfig) {
            Copy-Item $backupWebConfig $targetWebConfig -Force
            Write-Host "web.config restored" -ForegroundColor Green
        }
    }
    finally {
        iisreset /start
    }
}

Export-ModuleMember -Function Publish