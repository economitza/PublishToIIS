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

Describe 'Invoke-DeployOrder (dry-run)' {
    It 'resuelve el plan sin efectos para un entorno válido' {
        $plan = Invoke-DeployOrder -Environment 'devecoand2' -Branch 'main_deploy-20260720a' -WarningAction SilentlyContinue
        $plan.mode | Should -Be 'DRY-RUN'
        $plan.environment | Should -Be 'devecoand2'
        $plan.branch | Should -Be 'main_deploy-20260720a'
        # repo = carpeta padre del origin (…\CentralCompres → raíz del repo)
        $plan.repo | Should -Not -Match 'CentralCompres$'
        $plan.destination | Should -Not -BeNullOrEmpty
    }

    It 'rechaza un entorno fuera de la lista blanca' {
        { Invoke-DeployOrder -Environment 'devecoand2' -AllowedEnvironments @('devecoesp1') } | Should -Throw '*no permitido*'
    }

    It 'excluye prod de la lista blanca por defecto' {
        { Invoke-DeployOrder -Environment 'prod' } | Should -Throw '*no permitido*'
    }

    It 'rechaza ramas con formato inválido (inyección)' {
        { Invoke-DeployOrder -Environment 'devecoand2' -Branch 'main; rm -rf /' } | Should -Throw '*formato inválido*'
    }
}

Describe 'Read-PublishOrder' {
    BeforeEach {
        $script:orderPath = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_order_" + [Guid]::NewGuid() + ".json")
    }

    AfterEach {
        Remove-Item $script:orderPath -Force -ErrorAction SilentlyContinue
    }

    It 'lee una orden completa' {
        '{"environment":"dev-joaquim-local","branch":"main_deploy-20260720a","execute":true,"overrideWebconfig":false}' |
            Set-Content $script:orderPath -Encoding UTF8
        $order = Read-PublishOrder -Path $script:orderPath
        $order.environment | Should -Be 'dev-joaquim-local'
        $order.branch | Should -Be 'main_deploy-20260720a'
        $order.execute | Should -BeTrue
        $order.overrideWebconfig | Should -BeFalse
    }

    It 'execute es false (dry-run) si la orden no lo indica' {
        '{"environment":"dev-joaquim-local","branch":"main"}' | Set-Content $script:orderPath -Encoding UTF8
        (Read-PublishOrder -Path $script:orderPath).execute | Should -BeFalse
    }

    It 'rechaza órdenes sin environment o sin branch' {
        '{"branch":"main"}' | Set-Content $script:orderPath -Encoding UTF8
        { Read-PublishOrder -Path $script:orderPath } | Should -Throw "*environment*"
        '{"environment":"dev-joaquim-local"}' | Set-Content $script:orderPath -Encoding UTF8
        { Read-PublishOrder -Path $script:orderPath } | Should -Throw "*branch*"
    }

    It 'rechaza ramas con formato inválido (inyección)' {
        '{"environment":"dev-joaquim-local","branch":"main; rm -rf /"}' | Set-Content $script:orderPath -Encoding UTF8
        { Read-PublishOrder -Path $script:orderPath } | Should -Throw '*formato inválido*'
    }

    It 'falla con mensaje claro si no hay orden' {
        { Read-PublishOrder -Path $script:orderPath } | Should -Throw '*No hay orden*'
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
