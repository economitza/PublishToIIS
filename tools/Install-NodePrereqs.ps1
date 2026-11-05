<#
.SYNOPSIS
    Prepara un servidor para publicar entornos `kind: node` (escandallos) con el publicador.

.DESCRIPTION
    Una vez por servidor, en una consola elevada y con el MISMO usuario que registró la tarea
    «Publish Local» (la que publica). Idempotente: lo que ya está se respeta.

      1) Node.js LTS (instalador MSI oficial, con su comprobación SHA-256 contra SHASUMS256.txt de
         nodejs.org), en C:\Program Files\nodejs. No toca IIS: node.exe lo arranca el
         AspNetCoreModuleV2 del Hosting Bundle, que ya está porque sirve la API.
      2) Clon del repo (por defecto E:\git\escandallos-hotel, de GitHub) por HTTPS con un token
         fine-grained de SOLO LECTURA de ese repo (Contents: Read), guardado solo en la
         configuración de ESE clon (http.extraHeader) y con acceso solo para administradores y
         SYSTEM. La credencial de los otros clones no se toca.
      3) Comprobación: el módulo AspNetCoreModuleV2 y un git archive del repo.

    Sin -GitHubToken, el token se lee del portapapeles: pegar en la consola de un escritorio remoto
    falla a menudo aunque el portapapeles llegue.

.EXAMPLE
    .\tools\Install-NodePrereqs.ps1 -DryRun
    .\tools\Install-NodePrereqs.ps1
#>
[CmdletBinding()]
param(
    [string]$NodeVersion = '24.18.0',
    [string]$GitRoot = 'E:\git',
    [string]$Repo = 'escandallos-hotel',
    [string]$RepoUrl = 'https://github.com/economitza/escandallos-hotel.git',
    [string]$Branch = 'integracio',
    [securestring]$GitHubToken,
    [string]$PublishTaskName = 'Publish Local',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) { throw 'Lánzalo en una consola elevada (instala Node y protege el fichero con el token).' }

$tarea = Get-ScheduledTask -TaskName $PublishTaskName -ErrorAction SilentlyContinue
if ($tarea -and $tarea.Principal.UserId -and ($tarea.Principal.UserId -notlike "*$env:USERNAME")) {
    Write-Warning "La tarea '$PublishTaskName' corre como '$($tarea.Principal.UserId)' y tú eres '$env:USERDOMAIN\$env:USERNAME': el clon tiene que hacerlo ese usuario."
}

function Protect-SecretFile([string]$Path) {
    # Solo administradores y SYSTEM (por SID: los nombres de grupo cambian con el idioma)
    & icacls $Path /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
    if ($LASTEXITCODE) { throw "icacls no pudo proteger $Path ($LASTEXITCODE)." }
}

# 1) Node.js
$nodeExe = Join-Path $env:ProgramFiles 'nodejs\node.exe'
$actual = if (Test-Path $nodeExe) { ([string](& $nodeExe --version)).Trim() } else { $null }
if ($actual -eq "v$NodeVersion") {
    Write-Host "[1/3] Node.js ya instalado: $actual" -ForegroundColor Gray
}
elseif ($DryRun) {
    Write-Host "[1/3] Instalaría Node.js v$NodeVersion (ahora: $(if ($actual) { $actual } else { 'ninguno' }))" -ForegroundColor Yellow
}
else {
    $msi = "node-v$NodeVersion-x64.msi"
    $base = "https://nodejs.org/dist/v$NodeVersion"
    $destino = Join-Path $env:TEMP $msi
    Invoke-WebRequest -Uri "$base/$msi" -OutFile $destino -UseBasicParsing
    $sumas = (Invoke-WebRequest -Uri "$base/SHASUMS256.txt" -UseBasicParsing).Content
    $esperado = ($sumas -split "`n" | Where-Object { $_ -match "\s$([regex]::Escape($msi))\s*$" } | Select-Object -First 1) -replace '\s.*$', ''
    $real = (Get-FileHash $destino -Algorithm SHA256).Hash
    if (-not $esperado -or $real -ne $esperado.ToUpperInvariant()) { Remove-Item $destino -Force; throw "El SHA-256 de $msi no coincide con SHASUMS256.txt: no se instala." }
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$destino`"", '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec terminó con código $($p.ExitCode) instalando $msi." }
    Remove-Item $destino -Force
    Write-Host "[1/3] Node.js instalado: $(([string](& $nodeExe --version)).Trim())" -ForegroundColor Green
}

# 2) Clon del repo con un token de solo lectura
$dir = Join-Path $GitRoot $Repo
if ((Test-Path $dir) -and -not $DryRun) {
    & git -C $dir rev-parse --verify --quiet HEAD *> $null
    if ($LASTEXITCODE) {
        Write-Warning "$dir es un clon a medias (sin HEAD): se borra y se vuelve a clonar."
        Remove-Item $dir -Recurse -Force
    }
}
if (Test-Path (Join-Path $dir '.git')) {
    Write-Host "[2/3] Clon ya presente: $dir ($(git -C $dir remote get-url origin))" -ForegroundColor Gray
}
elseif ($DryRun) {
    Write-Host "[2/3] Clonaría $RepoUrl ($Branch) en $dir con un token de solo lectura" -ForegroundColor Yellow
}
else {
    if ($GitHubToken) {
        $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($GitHubToken))
    }
    else {
        Read-Host 'Copia el token de GitHub en tu equipo y pulsa Intro aquí (se lee del portapapeles)' | Out-Null
        $token = ([string](Get-Clipboard -Raw)).Trim()
        if ($token -notmatch '^(github_pat_|ghp_)[A-Za-z0-9_]{20,}$') {
            throw "El portapapeles no tiene un token de GitHub ($($token.Length) caracteres). Cópialo otra vez y relanza."
        }
        Set-Clipboard -Value ' '
        Write-Host "      token leído del portapapeles ($($token.Length) caracteres) y portapapeles vaciado" -ForegroundColor Gray
    }
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
    $cabecera = "Authorization: Basic $basic"
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    Write-Host "[2/3] Clonando $RepoUrl ($Branch) en $dir..." -ForegroundColor Yellow
    git -c "http.extraHeader=$cabecera" -c credential.helper= clone --branch $Branch $RepoUrl $dir
    if ($LASTEXITCODE) { throw "git clone falló ($LASTEXITCODE): ¿el token tiene Contents: Read sobre economitza/$Repo y no ha caducado?" }
    # Para los fetch del publicador: la cabecera en la config de ESE clon, sin gestor de credenciales, protegida
    git -C $dir config http.extraHeader $cabecera
    git -C $dir config credential.helper ''
    Protect-SecretFile (Join-Path $dir '.git\config')
    Write-Host "[2/3] Clonado en $dir" -ForegroundColor Green
}

# 3) Comprobación
$ancm = Join-Path $env:ProgramFiles 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
if (-not (Test-Path $ancm)) { Write-Warning "[3/3] Falta el AspNetCoreModuleV2 de IIS (Hosting Bundle de .NET): sin él, IIS no arranca node." }
elseif ($DryRun -or -not (Test-Path (Join-Path $dir '.git'))) { Write-Host "[3/3] Comprobaría: AspNetCoreModuleV2 y git archive de $dir" -ForegroundColor Yellow }
else {
    $zip = Join-Path $env:TEMP 'node-prereqs-prueba.zip'
    & git -C $dir archive --format=zip -o $zip HEAD server.mjs
    if ($LASTEXITCODE) { throw "git archive falló ($LASTEXITCODE) en $dir." }
    Remove-Item $zip -Force
    Write-Host "[3/3] AspNetCoreModuleV2 presente y git archive OK: el servidor ya publica entornos kind node" -ForegroundColor Green
}
