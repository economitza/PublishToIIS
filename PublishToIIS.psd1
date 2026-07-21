@{
    RootModule = 'src\PublishToIIS.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'd3f6d9b7-6c3a-4f0d-9a2b-123456789abc'
    Author = 'Economitza (it@economitza.com)'
    CompanyName = 'Economitza'
    Copyright = '(c) 2026 Economitza'
    Description = 'PublishToIIS - helper module to publish .NET projects to IIS with safe swap'
    FunctionsToExport = @('Publish','Get-MSBuild','Get-PublishConfig','Update-PublishToIIS','Protect-ProductionWebConfig','New-DeployInfo','Invoke-DeployOrder')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('Publish-Update')
    FileList = @('src\PublishToIIS.psm1','config\environments.json','config\config.ps1')
    PrivateData = @{
        PSData = @{
            Tags = @('IIS','deploy','build')
            LicenseUri = ''
            ProjectUri = ''
            ReleaseNotes = 'Initial skeleton'
        }
    }
}
