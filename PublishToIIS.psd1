@{
    RootModule = 'src\PublishToIIS.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'd3f6d9b7-6c3a-4f0d-9a2b-123456789abc'
    Author = 'TODO: Add author'
    CompanyName = ''
    Copyright = '(c) TODO'
    Description = 'PublishToIIS - helper module to publish .NET projects to IIS with safe swap'
    FunctionsToExport = @('Publish','Get-MSBuild','Get-PublishConfig')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
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
