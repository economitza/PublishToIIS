<#
.SYNOPSIS
    Prepara un servidor para publicar entornos `kind: aspnetcore` (la API) con el publicador.

.DESCRIPTION
    Una vez por servidor, en una consola elevada y con el MISMO usuario que registró la tarea
    «Publish Local» (la que compila y publica). Idempotente: lo que ya está se respeta.

      1) SDK de .NET del canal indicado (el Hosting Bundle de IIS solo trae el runtime, que sirve
         la API pero no la compila), instalado con dotnet-install.ps1 en la carpeta de dotnet.
      2) Clon del repo de la API junto al del e-market (por defecto E:\git\central-compres-api),
         con el mismo protocolo (SSH o HTTPS) que el clon del e-market, que ya sabe autenticarse.
      3) NuGet.Config en la carpeta común de los clones (E:\git\NuGet.Config) con el registro
         NuGet de GitLab, donde el CI publica EconomitzaDB. dotnet lo encuentra subiendo desde el
         proyecto, sea cual sea el usuario. Acceso solo para administradores y SYSTEM: lleva el token.
      4) Comprobación: dotnet restore del proyecto de la API.

    El token es de GitLab con permiso de leer paquetes: un token de acceso personal con alcance
    `read_api` o un token de despliegue del proyecto economitzadbnuget con `read_package_registry`.
    Si no se pasa -NuGetToken, se lee del portapapeles: pegar en la consola de un escritorio
    remoto falla a menudo aunque el portapapeles llegue.

.EXAMPLE
    .\tools\Install-AspNetCorePrereqs.ps1 -DryRun
    .\tools\Install-AspNetCorePrereqs.ps1
#>
[CmdletBinding()]
param(
    [string]$SdkChannel = '10.0',
    [string]$GitRoot = 'E:\git',
    [string]$WebRepo = 'central-de-compres',
    [string]$ApiRepo = 'central-compres-api',
    [string]$ApiRepoPath = 'economitza/api/central-compres-api.git',
    [string]$ApiProject = 'central-de-compres-integracio\central-de-compres-integracio.csproj',
    [string]$NuGetFeedUrl = 'https://git.rcassociats.com/api/v4/projects/218/packages/nuget/index.json',
    # Usuario de GitLab del token personal, o el usuario del token de despliegue
    [string]$NuGetUser,
    [securestring]$NuGetToken,
    [string]$PublishTaskName = 'Publish Local',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) { throw 'Lánzalo en una consola elevada (instala el SDK y protege el NuGet.Config).' }

$yo = "$env:USERDOMAIN\$env:USERNAME"
$tarea = Get-ScheduledTask -TaskName $PublishTaskName -ErrorAction SilentlyContinue
if ($tarea -and $tarea.Principal.UserId -and ($tarea.Principal.UserId -notlike "*$env:USERNAME")) {
    Write-Warning "La tarea '$PublishTaskName' corre como '$($tarea.Principal.UserId)' y tú eres '$yo': el clon tiene que hacerlo ese usuario (sus claves SSH o credenciales de git)."
}

# 1) SDK
$dotnetDir = Join-Path $env:ProgramFiles 'dotnet'
$dotnet = Join-Path $dotnetDir 'dotnet.exe'
$sdks = if (Test-Path $dotnet) { @(& $dotnet --list-sdks 2>$null) } else { @() }
$sdkCanal = $sdks | Where-Object { $_ -like "$SdkChannel.*" } | Select-Object -First 1
if ($sdkCanal) {
    Write-Host "[1/4] SDK de .NET $SdkChannel ya instalado: $sdkCanal" -ForegroundColor Gray
}
elseif ($DryRun) {
    Write-Host "[1/4] Instalaría el SDK de .NET $SdkChannel en $dotnetDir (ahora: $(if ($sdks) { $sdks -join '; ' } else { 'ninguno' }))" -ForegroundColor Yellow
}
else {
    $installer = Join-Path $env:TEMP 'dotnet-install.ps1'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer -UseBasicParsing
    & $installer -Channel $SdkChannel -InstallDir $dotnetDir -NoPath
    $sdkCanal = @(& $dotnet --list-sdks) | Where-Object { $_ -like "$SdkChannel.*" } | Select-Object -First 1
    if (-not $sdkCanal) { throw "El SDK $SdkChannel no aparece en 'dotnet --list-sdks' tras instalarlo." }
    Write-Host "[1/4] SDK instalado: $sdkCanal" -ForegroundColor Green
}

# 2) Clon de la API, con el protocolo del clon del e-market
$apiDir = Join-Path $GitRoot $ApiRepo
$webDir = Join-Path $GitRoot $WebRepo
# Un clon cortado a medias (Ctrl+C) deja la carpeta sin HEAD: se rehace.
if ((Test-Path (Join-Path $apiDir '.git')) -and -not $DryRun) {
    & git -C $apiDir rev-parse --verify --quiet HEAD *> $null
    if ($LASTEXITCODE) {
        Write-Warning "$apiDir es un clon a medias (sin HEAD): se borra y se vuelve a clonar."
        Remove-Item $apiDir -Recurse -Force
    }
}
if (Test-Path (Join-Path $apiDir '.git')) {
    Write-Host "[2/4] Clon ya presente: $apiDir ($(git -C $apiDir remote get-url origin))" -ForegroundColor Gray
}
else {
    $webUrl = (git -C $webDir remote get-url origin).Trim()
    $apiUrl = if ($webUrl -match '^(git@[^:]+:)') { "$($Matches[1])$ApiRepoPath" }
              elseif ($webUrl -match '^(https?://[^/]+/)') { "$($Matches[1])$ApiRepoPath" }
              else { throw "No reconozco el remoto del e-market ('$webUrl') para deducir el de la API." }
    $sshCmd = (git -C $webDir config --get core.sshCommand)
    Write-Host "      e-market: $webUrl$(if ($sshCmd) { " (core.sshCommand: $sshCmd)" })" -ForegroundColor Gray
    if ($DryRun) {
        Write-Host "[2/4] Clonaría $apiUrl en $apiDir" -ForegroundColor Yellow
    }
    else {
        Write-Host "[2/4] Clonando $apiUrl en $apiDir..." -ForegroundColor Yellow
        # Sin preguntas: una petición de credenciales, de passphrase o de host key dejaba
        # el clon colgado en «Cloning into...» sin decir nada. Así falla y dice por qué.
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        $env:GIT_SSH_COMMAND = "$(if ($sshCmd) { $sshCmd } else { 'ssh' }) -oBatchMode=yes -oStrictHostKeyChecking=accept-new -oConnectTimeout=20"
        git clone $apiUrl $apiDir
        if ($LASTEXITCODE) {
            throw ("git clone $apiUrl falló ($LASTEXITCODE). Comprueba con este mismo usuario si el e-market sí puede: " +
                   "'git -C $webDir fetch'. Si ese funciona y este no, esta cuenta no tiene acceso a $ApiRepoPath en GitLab " +
                   "(p. ej. una clave de despliegue dada de alta solo en el proyecto del e-market).")
        }
        Write-Host "[2/4] Clonado $apiUrl en $apiDir" -ForegroundColor Green
    }
}

# 3) NuGet.Config común a los clones, con el registro de GitLab
$nugetConfig = Join-Path $GitRoot 'NuGet.Config'
$yaEsta = (Test-Path $nugetConfig) -and (Select-String -Path $nugetConfig -SimpleMatch $NuGetFeedUrl -Quiet)
if ($yaEsta) {
    Write-Host "[3/4] $nugetConfig ya declara el registro de GitLab" -ForegroundColor Gray
}
elseif ($DryRun) {
    Write-Host "[3/4] Escribiría $nugetConfig con el registro $NuGetFeedUrl (token pedido por consola; solo administradores y SYSTEM)" -ForegroundColor Yellow
}
else {
    if (Test-Path $nugetConfig) { throw "$nugetConfig ya existe sin el registro de GitLab: revísalo a mano en vez de pisarlo." }
    if (-not $NuGetUser) { $NuGetUser = Read-Host 'Usuario de GitLab del token (o el del token de despliegue)' }
    if ($NuGetToken) {
        $plano = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($NuGetToken))
    }
    else {
        # Pegar en la consola de un escritorio remoto falla a menudo aunque el portapapeles
        # llegue (el Bloc de notas sí pega): el token se lee directamente del portapapeles.
        Read-Host 'Copia el token de GitLab en tu equipo y pulsa Intro aquí (se lee del portapapeles)' | Out-Null
        $plano = ([string](Get-Clipboard -Raw)).Trim()
        if ($plano -notmatch '^[A-Za-z0-9._-]{20,}$') {
            throw "El portapapeles no tiene un token de GitLab ($($plano.Length) caracteres, o con espacios). Cópialo otra vez y relanza."
        }
        Set-Clipboard -Value ' '   # que el token no se quede en el portapapeles
        Write-Host "      token leído del portapapeles ($($plano.Length) caracteres) y portapapeles vaciado" -ForegroundColor Gray
    }
    $esc = [Security.SecurityElement]::Escape($plano)
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Lo escribe PublishToIIS\tools\Install-AspNetCorePrereqs.ps1: fuentes NuGet para los clones de $GitRoot. -->
<configuration>
  <packageSources>
    <add key="gitlab-economitza" value="$NuGetFeedUrl" />
  </packageSources>
  <packageSourceCredentials>
    <gitlab-economitza>
      <add key="Username" value="$NuGetUser" />
      <add key="ClearTextPassword" value="$esc" />
    </gitlab-economitza>
  </packageSourceCredentials>
</configuration>
"@
    [IO.File]::WriteAllText($nugetConfig, $xml, (New-Object System.Text.UTF8Encoding($false)))
    & icacls $nugetConfig /inheritance:r /grant:r 'BUILTIN\Administrators:F' 'NT AUTHORITY\SYSTEM:F' | Out-Null
    Write-Host "[3/4] Escrito $nugetConfig (solo administradores y SYSTEM)" -ForegroundColor Green
}

# 4) Comprobación: restore del proyecto de la API
$proyecto = Join-Path $apiDir $ApiProject
if ($DryRun -or -not (Test-Path $proyecto)) {
    Write-Host "[4/4] Comprobaría: dotnet restore $proyecto" -ForegroundColor Yellow
}
else {
    & $dotnet restore $proyecto --nologo
    if ($LASTEXITCODE) { throw "dotnet restore falló ($LASTEXITCODE): revisa el token y que el SDK sea el que pide el proyecto." }
    Write-Host "[4/4] dotnet restore OK: el servidor ya compila la API" -ForegroundColor Green
}
