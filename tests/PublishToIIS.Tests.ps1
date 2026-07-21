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

Describe 'New-DeployInfo' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_di_" + [Guid]::NewGuid())
        $script:repoDir = Join-Path $script:tmp 'repo'
        $script:outDir = Join-Path $script:tmp 'releasing'
        New-Item -ItemType Directory -Path $script:repoDir | Out-Null
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
        # Working copy git mínima con un commit en una rama conocida
        git -C $script:repoDir init --quiet --initial-branch=test-branch
        git -C $script:repoDir -c user.email=t@t -c user.name=t commit --allow-empty -m 'init' --quiet
    }

    AfterEach {
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes deploy-info.json with branch, commit and metadata from the working copy' {
        $info = New-DeployInfo -ProjectPath $script:repoDir -OutputDir $script:outDir -Environment 'devecoand2'
        $file = Join-Path $script:outDir 'deploy-info.json'
        Test-Path $file | Should -BeTrue
        $json = Get-Content $file -Raw | ConvertFrom-Json
        $json.branch | Should -Be 'test-branch'
        $json.commit | Should -Match '^[0-9a-f]{7,}$'
        $json.commitDate | Should -Not -BeNullOrEmpty
        $json.publishDate | Should -Not -BeNullOrEmpty
        $json.environment | Should -Be 'devecoand2'
        $json.publishedBy | Should -Be "$env:USERNAME@$env:COMPUTERNAME"
        $info.commit | Should -Be $json.commit
    }

    It 'resolves git info from a subdirectory of the working copy (project inside repo)' {
        $sub = Join-Path $script:repoDir 'CentralCompres'
        New-Item -ItemType Directory -Path $sub | Out-Null
        $json = New-DeployInfo -ProjectPath $sub -OutputDir $script:outDir -Environment 'e'
        $json.branch | Should -Be 'test-branch'
    }

    It 'still writes the stamp (with null branch/commit) when the path is not a git repo' {
        $noRepo = Join-Path $script:tmp 'norepo'
        New-Item -ItemType Directory -Path $noRepo | Out-Null
        $json = New-DeployInfo -ProjectPath $noRepo -OutputDir $script:outDir -Environment 'e' -WarningAction SilentlyContinue
        $file = Join-Path $script:outDir 'deploy-info.json'
        Test-Path $file | Should -BeTrue
        $json.branch | Should -BeNullOrEmpty
        $json.commit | Should -BeNullOrEmpty
        $json.publishDate | Should -Not -BeNullOrEmpty
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
