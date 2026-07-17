Import-Module -Name (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

Describe 'Get-PublishConfig' {
    It 'loads a defined environment config' {
        $cfg = Get-PublishConfig -Environment 'dev-joaquim-local'
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.destination | Should -Match 'economitza_espana'
    }

    It 'falls back to the default environment when none is given' {
        $cfg = Get-PublishConfig
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.destination | Should -Match 'economitza_espana'
    }

    It 'throws for missing environment' {
        { Get-PublishConfig -Environment 'missing_env' } | Should -Throw
    }
}

Describe 'Protect-ProductionWebConfig' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
        $script:targetCfg = Join-Path $script:tmp 'target_web.config'
        $script:releasingCfg = Join-Path $script:tmp 'releasing_web.config'
        Set-Content $script:targetCfg '<production/>'
        Set-Content $script:releasingCfg '<repo/>'
    }

    AfterEach {
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'by default preserves the production web.config over the published one' {
        $result = Protect-ProductionWebConfig -TargetWebConfig $script:targetCfg -ReleasingWebConfig $script:releasingCfg
        $result | Should -Be 'preserved'
        Get-Content $script:releasingCfg | Should -Be '<production/>'
    }

    It 'with -Override keeps the repo web.config and saves production copy as .previous' {
        $result = Protect-ProductionWebConfig -TargetWebConfig $script:targetCfg -ReleasingWebConfig $script:releasingCfg -Override
        $result | Should -Be 'overridden'
        Get-Content $script:releasingCfg | Should -Be '<repo/>'
        Get-Content "$($script:releasingCfg).previous" | Should -Be '<production/>'
    }

    It 'does nothing when there is no production web.config' {
        Remove-Item $script:targetCfg
        $result = Protect-ProductionWebConfig -TargetWebConfig $script:targetCfg -ReleasingWebConfig $script:releasingCfg
        $result | Should -Be 'no-production-webconfig'
        Get-Content $script:releasingCfg | Should -Be '<repo/>'
    }
}
