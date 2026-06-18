<#
Install-ModuleLocal.ps1

Instala el módulo PublishToIIS localmente para:

- Windows PowerShell 5.x
- PowerShell 7+

Copiando el módulo a:

C:\Program Files\WindowsPowerShell\Modules
C:\Program Files\PowerShell\Modules

Uso:

.\Install-ModuleLocal.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Autoelevación
# ------------------------------------------------------------

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {

    Write-Host "Restarting elevated..." -ForegroundColor Yellow

    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
    )

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList $argList

    exit
}

# ------------------------------------------------------------
# Resolver paths
# ------------------------------------------------------------

$scriptDir = Split-Path -Parent $PSCommandPath
$moduleRoot = $scriptDir

$moduleName = Split-Path $moduleRoot -Leaf

Write-Host ""
Write-Host "Module Root : $moduleRoot"
Write-Host "Module Name : $moduleName"

# ------------------------------------------------------------
# Obtener versión desde manifest
# ------------------------------------------------------------

$manifestPath = Get-ChildItem `
    -Path $moduleRoot `
    -Filter '*.psd1' `
    -File |
    Select-Object -First 1

if (-not $manifestPath) {
    throw "No .psd1 manifest found in module root."
}

$manifest = Import-PowerShellDataFile $manifestPath.FullName

if (-not $manifest.ModuleVersion) {
    throw "ModuleVersion not found in manifest."
}

$moduleVersion = $manifest.ModuleVersion.ToString()

Write-Host "Module Version : $moduleVersion"

# ------------------------------------------------------------
# Targets
# ------------------------------------------------------------

$targets = @(
    'C:\Program Files\WindowsPowerShell\Modules',
    'C:\Program Files\PowerShell\Modules'
)

# ------------------------------------------------------------
# Archivos/carpetas a excluir
# ------------------------------------------------------------

$exclude = @(
    '.git',
    '.vs',
    '.vscode',
    'bin',
    'obj',
    'Install.ps1'
)

# ------------------------------------------------------------
# Instalación
# ------------------------------------------------------------

foreach ($baseTarget in $targets) {

    if (-not (Test-Path $baseTarget)) {

        Write-Warning "Target path does not exist: $baseTarget"
        continue
    }

    $targetPath = Join-Path `
        $baseTarget `
        "$moduleName\$moduleVersion"

    Write-Host ""
    Write-Host "Installing to:"
    Write-Host $targetPath -ForegroundColor Cyan

    # Eliminar versión anterior
    if (Test-Path $targetPath) {

        Write-Host "Removing previous version..."

        Remove-Item `
            -Path $targetPath `
            -Recurse `
            -Force
    }

    New-Item `
        -ItemType Directory `
        -Path $targetPath `
        -Force | Out-Null

    # Copia completa excepto exclusiones
    Get-ChildItem -Path $moduleRoot -Force | ForEach-Object {

        if ($exclude -contains $_.Name) {
            return
        }

        $destination = Join-Path $targetPath $_.Name

        Copy-Item `
            -Path $_.FullName `
            -Destination $destination `
            -Recurse `
            -Force
    }

    Write-Host "Installed successfully." -ForegroundColor Green
}

# ------------------------------------------------------------
# Validación
# ------------------------------------------------------------

Write-Host ""
Write-Host "Installed module versions:" -ForegroundColor Yellow

Get-Module `
    -ListAvailable `
    -Name $moduleName |
    Sort-Object Version -Descending |
    Select-Object Name, Version, ModuleBase |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Done." -ForegroundColor Green

Write-Host ""
Write-Host "Press any key to exit..."
[void][System.Console]::ReadKey($true)