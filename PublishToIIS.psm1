function Publish {
    param(
        [string]$ProjectPath = "C:\Users\joaquimms\Documents\git\20260430\central-de-compres\CentralCompres\CentralCompres.csproj",
        [string]$Destination  = "C:\inetpub\wwwroot\economitza_espana"
    )
    Write-Host "ENTER Publish function" -ForegroundColor Cyan
    # Parem tot el servidor IIS per a que no bloquegi res
    iisreset /stop


    # 1. Rutas derivadas
    $parentDir = Split-Path $Destination -Parent
    $tempDir = Join-Path $parentDir "temp_publish_backup"
    $backupWebConfig = Join-Path $tempDir "web.config"
    $targetWebConfig = Join-Path $Destination "web.config"

    # Crear carpeta temp si no existe
    if (!(Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir | Out-Null
    }

    # 2. Backup del web.config existente (si existe)
    if (Test-Path $targetWebConfig) {
        Copy-Item $targetWebConfig $backupWebConfig -Force
    }

    try {
        # 3. Ejecutar MSBuild publish
        msbuild $ProjectPath `
            /p:Configuration=Release `
            /p:DeployOnBuild=true `
            /p:PublishUrl="$Destination" `
            /p:WebPublishMethod=FileSystem `
            /p:DeployTarget=WebPublish

        # 4. Restaurar web.config original
        if (Test-Path $backupWebConfig) {
            Copy-Item $backupWebConfig $targetWebConfig -Force
        }
    }
    finally {
        # Restaurem el servidor
        iisreset /start

    }

}

Export-ModuleMember -Function Publish