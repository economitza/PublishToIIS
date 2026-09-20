@{
    RootModule = 'src\PublishToIIS.psm1'
    ModuleVersion = '0.7.0'
    GUID = 'd3f6d9b7-6c3a-4f0d-9a2b-123456789abc'
    Author = 'Economitza (it@economitza.com)'
    CompanyName = 'Economitza'
    Copyright = '(c) 2026 Economitza'
    Description = 'PublishToIIS - helper module to publish .NET projects to IIS with safe swap'
    FunctionsToExport = @('Publish','Invoke-HotfixBuild','Get-HotfixBinDelta','Test-SameFileContent','Invoke-Hotfix','Undo-Hotfix','Get-HotfixTarget','Invoke-SiteWarmup','Update-DeployInfoHotfix','Restore-HotfixFiles','Test-HotfixWritable','Get-SiteDeployInfo','Resolve-HotfixPlan','Get-HotfixDelta','Get-MSBuild','Get-NuGetExe','Restore-NuGetPackages','Get-PublishConfig','Update-PublishToIIS','Protect-ProductionWebConfig','New-DeployInfo','Invoke-DeployOrder','Read-PublishOrder','Write-PublishOrder','Read-AdHocEnvironment','Test-ScheduledTaskPresent','Request-PublishQueued','Wait-PublishResult','Request-Publish','Get-PublishToIISRepo','Register-PublishTask','New-DeployEndpointToken','Get-DeployEndpointToken','Invoke-DeployEndpointRequest','Start-DeployEndpoint','Request-RemotePublish','Add-DeployQueueItem','Get-DeployQueue','Get-DeployResult','Invoke-DeployQueueDrain','Register-DeployEndpoint','Test-DeployEndpoint','Register-DeployProxySite','Set-DeployToken','Get-DeployToken','Get-DeployServerUrl','Register-Dashboard','Initialize-IisSite','Set-ConnectionStringCatalog','Write-UpdateOrder','Request-ModuleUpdate','Get-PublishToIISVersionInfo','Get-RemoteDeployVersion','Request-RemoteUpdate')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('Publish-Update')
    FileList = @('src\PublishToIIS.psm1','config\environments.json','config\config.ps1')
    PrivateData = @{
        PSData = @{
            Tags = @('IIS','deploy','build')
            LicenseUri = ''
            ProjectUri = ''
            ReleaseNotes = 'Publish con swap seguro y web.config preservado; sello deploy-info.json; dashboard de publicacion; ordenes de despliegue via tarea Publish Local; endpoint HTTP de despliegue remoto con cola FIFO serializada; alta de entornos con Add-PublishEnvironment; aprovisionamiento de sites IIS desde plantilla (templateSite); actualizacion remota del modulo (POST /api/update, Request-RemoteUpdate).'
        }
    }
}
