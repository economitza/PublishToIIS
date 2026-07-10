function Get-PublishConfig {
    param(
        [string]$Environment
    )

    $cfgFile = Join-Path $PSScriptRoot 'environments.json'
    if (-not (Test-Path $cfgFile)) { throw "Central config not found: $cfgFile" }
    $cfgAll = Get-Content $cfgFile -Raw | ConvertFrom-Json

    $envName = $Environment
    if (-not $envName -or [string]::IsNullOrWhiteSpace($envName)) { $envName = $env:PUBLISH_ENV }
    if (-not $envName -or [string]::IsNullOrWhiteSpace($envName)) { $envName = $cfgAll.defaultEnvironment }

    if ($cfgAll.environments.PSObject.Properties.Name -notcontains $envName) { throw "Environment '$envName' not defined in $cfgFile" }

    $envCfg = $cfgAll.environments.$envName
    # Expose the resolved environment name so callers can default the app pool to it
    $envCfg | Add-Member -NotePropertyName '_environment' -NotePropertyValue $envName -Force
    return $envCfg
}
