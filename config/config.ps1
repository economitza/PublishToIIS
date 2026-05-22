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

    if (-not $cfgAll.environments.PSObject.Properties.Name -contains $envName) { throw "Environment '$envName' not defined in $cfgFile" }

    return $cfgAll.environments.$envName
}

Export-ModuleMember -Function Get-PublishConfig
