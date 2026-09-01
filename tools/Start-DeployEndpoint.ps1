# Arranca el listener del endpoint de despliegue. Lo ejecuta la tarea
# programada 'Publish Endpoint' (registrada con Register-DeployEndpointTask.ps1,
# que configura los reintentos: si el proceso muere, el Programador de tareas
# lo relanza) o una consola a mano para probar.
[CmdletBinding()]
param(
    [int]$Port = 8770,
    [string]$TaskName = 'Publish Local'
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force
Start-DeployEndpoint -Port $Port -TaskName $TaskName
