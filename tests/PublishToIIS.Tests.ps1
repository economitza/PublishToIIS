Import-Module -Name (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

Describe 'Get-PublishConfig' {
    It 'loads dev environment config' {
        $cfg = Get-PublishConfig -Environment 'dev'
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.destination | Should -Match 'site_dev'
    }

    It 'throws for missing environment' {
        { Get-PublishConfig -Environment 'missing_env' } | Should -Throw
    }
}
