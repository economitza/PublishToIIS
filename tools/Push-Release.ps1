# Sube la version del modulo, commitea el bump y pushea, en un solo paso. Es la
# via por la que se hacen los push de este repo: la regla es +1 en el tercer
# digito (patch) por cada push. Con -Minor / -Major sube ese nivel y reinicia los
# de abajo, y a partir de ahi se sigue incrementando patch por push.
#
#   .\Push-Release.ps1            # 0.4.0 -> 0.4.1  (push normal)
#   .\Push-Release.ps1 -Minor     # 0.4.1 -> 0.5.0
#   .\Push-Release.ps1 -Major     # 0.5.0 -> 1.0.0
#   .\Push-Release.ps1 -DryRun    # solo muestra el salto, no toca nada
#
# Flujo: commitea PRIMERO tu trabajo; luego este helper anade el commit del bump
# y hace git push (que sube tu trabajo y el bump juntos).
[CmdletBinding()]
param(
    [switch]$Minor,
    [switch]$Major,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$psd1 = Join-Path $repo 'PublishToIIS.psd1'
if (-not (Test-Path $psd1)) { throw "No se encontro $psd1." }

$bytes = [IO.File]::ReadAllBytes($psd1)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$raw = [IO.File]::ReadAllText($psd1)

$m = [regex]::Match($raw, "ModuleVersion\s*=\s*'(\d+)\.(\d+)\.(\d+)'")
if (-not $m.Success) { throw "No se encontro un ModuleVersion 'X.Y.Z' en el manifiesto." }
$maj = [int]$m.Groups[1].Value; $min = [int]$m.Groups[2].Value; $pat = [int]$m.Groups[3].Value
$old = "$maj.$min.$pat"

if ($Major)     { $maj++; $min = 0; $pat = 0 }
elseif ($Minor) { $min++; $pat = 0 }
else            { $pat++ }
$new = "$maj.$min.$pat"

Write-Host "Version: $old -> $new" -ForegroundColor Cyan
if ($DryRun) { Write-Host 'DryRun: no se toca nada.' -ForegroundColor Yellow; return }

$updated = $raw.Substring(0, $m.Index) + "ModuleVersion = '$new'" + $raw.Substring($m.Index + $m.Length)
[IO.File]::WriteAllText($psd1, $updated, (New-Object Text.UTF8Encoding($hasBom)))

& git -C $repo add -- PublishToIIS.psd1
if ($LASTEXITCODE) { throw "git add fallo (codigo $LASTEXITCODE)." }
& git -C $repo commit -q -m "chore(release): v$new"
if ($LASTEXITCODE) { throw "git commit fallo (codigo $LASTEXITCODE)." }
& git -C $repo push
if ($LASTEXITCODE) { throw "git push fallo (codigo $LASTEXITCODE). El bump esta commiteado en local; reintenta el push a mano." }
Write-Host "Pusheado como v$new." -ForegroundColor Green
