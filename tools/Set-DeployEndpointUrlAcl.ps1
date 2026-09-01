# Reserva la URL ACL del loopback para que el listener del endpoint pueda
# escuchar SIN privilegios. Requiere elevacion (lo llama Register-DeployEndpointTask,
# que ya se ha elevado). Idempotente: borra la reserva previa si la hubiera.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$User
)
$ErrorActionPreference = 'Stop'

$prefix = "http://127.0.0.1:$Port/"
# Si no existia, el delete se queja y da igual: por eso no se comprueba su codigo.
& netsh http delete urlacl url=$prefix 2>&1 | Out-Null
& netsh http add urlacl url=$prefix user=$User | Out-Null
if ($LASTEXITCODE -ne 0) { throw "No se pudo reservar la URL ACL $prefix (netsh $LASTEXITCODE)." }
Write-Host "URL ACL reservada: $prefix para $User" -ForegroundColor Gray
