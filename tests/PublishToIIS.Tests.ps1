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

Describe 'Write-PublishOrder' {
    BeforeEach {
        $script:dataDir = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_wo_" + [Guid]::NewGuid())
    }

    AfterEach {
        Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'escribe la orden y la deja legible por Read-PublishOrder' {
        $written = Write-PublishOrder -Environment 'devecoand1' -Branch 'main_deploy-20260730' -Execute -DataDir $script:dataDir
        Test-Path $written.path | Should -BeTrue
        $order = Read-PublishOrder -Path $written.path
        $order.environment | Should -Be 'devecoand1'
        $order.branch | Should -Be 'main_deploy-20260730'
        $order.execute | Should -BeTrue
        $order.runId | Should -Be $written.runId
    }

    It 'da un runId distinto a cada orden' {
        $a = Write-PublishOrder -Environment 'devecoand1' -Branch 'main' -DataDir $script:dataDir
        $b = Write-PublishOrder -Environment 'devecoand1' -Branch 'main' -DataDir $script:dataDir
        $a.runId | Should -Not -BeNullOrEmpty
        $a.runId | Should -Not -Be $b.runId
    }

    It 'crea el directorio de datos si no existe' {
        Test-Path $script:dataDir | Should -BeFalse
        Write-PublishOrder -Environment 'devecoand1' -Branch 'main' -DataDir $script:dataDir | Out-Null
        Test-Path $script:dataDir | Should -BeTrue
    }

    It 'sin -Execute la orden es dry-run' {
        $written = Write-PublishOrder -Environment 'devecoand1' -Branch 'main' -DataDir $script:dataDir
        (Read-PublishOrder -Path $written.path).execute | Should -BeFalse
    }

    It 'rechaza ramas con formato inválido (inyección) antes de escribir nada' {
        { Write-PublishOrder -Environment 'devecoand1' -Branch 'main; rm -rf /' -DataDir $script:dataDir } |
            Should -Throw '*formato inválido*'
        Test-Path (Join-Path $script:dataDir 'publish-order.json') | Should -BeFalse
    }

    It 'rechaza entornos fuera de la lista blanca (prod)' {
        { Write-PublishOrder -Environment 'prod' -Branch 'main' -DataDir $script:dataDir } | Should -Throw '*no permitido*'
    }

    It 'descarta el resultado de una ejecución anterior' {
        $resultPath = Join-Path $script:dataDir 'publish-order.result.json'
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        '{"status":"ok"}' | Set-Content $resultPath -Encoding UTF8
        Write-PublishOrder -Environment 'devecoand1' -Branch 'main' -DataDir $script:dataDir | Out-Null
        Test-Path $resultPath | Should -BeFalse
    }
}

Describe 'Wait-PublishResult' {
    BeforeEach {
        $script:dataDir = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_wr_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
    }

    AfterEach {
        Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'devuelve el resultado en cuanto aparece el fichero' {
        '{"status":"ok","environment":"devecoand1","branch":"main","message":"hecho"}' |
            Set-Content (Join-Path $script:dataDir 'publish-order.result.json') -Encoding UTF8
        $r = Wait-PublishResult -DataDir $script:dataDir -TimeoutSeconds 5
        $r.status | Should -Be 'ok'
        $r.environment | Should -Be 'devecoand1'
    }

    It 'lanza timeout si no aparece resultado' {
        { Wait-PublishResult -DataDir $script:dataDir -TimeoutSeconds 1 -PollSeconds 1 } | Should -Throw '*Timeout*'
    }

    It 'con -RunId ignora el resultado de otra ejecución' {
        '{"status":"ok","message":"otra ejecución","runId":"aaaa"}' |
            Set-Content (Join-Path $script:dataDir 'publish-order.result.json') -Encoding UTF8
        { Wait-PublishResult -DataDir $script:dataDir -RunId 'bbbb' -TimeoutSeconds 1 -PollSeconds 1 } |
            Should -Throw '*Timeout*'
    }

    It 'con -RunId acepta el resultado propio' {
        '{"status":"ok","message":"la mía","runId":"bbbb"}' |
            Set-Content (Join-Path $script:dataDir 'publish-order.result.json') -Encoding UTF8
        (Wait-PublishResult -DataDir $script:dataDir -RunId 'bbbb' -TimeoutSeconds 5).message | Should -Be 'la mía'
    }

    It 'con -Since ignora el resultado de una ejecución anterior' {
        # El proceso sin privilegios no siempre puede borrar el result.json que
        # escribió la tarea elevada: hay que descartarlo por fecha, no por borrado.
        ('{"status":"ok","message":"lo de ayer","finishedAt":"' + (Get-Date).AddHours(-2).ToString('o') + '"}') |
            Set-Content (Join-Path $script:dataDir 'publish-order.result.json') -Encoding UTF8
        { Wait-PublishResult -DataDir $script:dataDir -Since (Get-Date) -TimeoutSeconds 1 -PollSeconds 1 } |
            Should -Throw '*Timeout*'
    }

    It 'con -Since acepta el resultado de esta ejecución' {
        $since = (Get-Date).AddSeconds(-5)
        ('{"status":"ok","message":"recién hecho","finishedAt":"' + (Get-Date).ToString('o') + '"}') |
            Set-Content (Join-Path $script:dataDir 'publish-order.result.json') -Encoding UTF8
        (Wait-PublishResult -DataDir $script:dataDir -Since $since -TimeoutSeconds 5).message | Should -Be 'recién hecho'
    }
}

Describe 'Request-Publish' {
    BeforeEach {
        $script:dataDir = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_rp_" + [Guid]::NewGuid())
    }

    AfterEach {
        Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'escribe la orden, dispara la tarea y devuelve el resultado' {
        Mock -ModuleName PublishToIIS Start-PublishTask {
            param($TaskName, $DataDir)
            # La tarea real hace eco del runId de la orden: aquí, igual.
            $runId = (Get-Content (Join-Path $DataDir 'publish-order.json') -Raw | ConvertFrom-Json).runId
            "{`"status`":`"ok`",`"runId`":`"$runId`",`"environment`":`"devecoand1`",`"branch`":`"main_deploy-20260730`"}" |
                Set-Content (Join-Path $DataDir 'publish-order.result.json') -Encoding UTF8
        }

        $r = Request-Publish -Environment 'devecoand1' -Branch 'main_deploy-20260730' -Execute `
            -DataDir $script:dataDir -TimeoutSeconds 5
        $r.status | Should -Be 'ok'
        $r.branch | Should -Be 'main_deploy-20260730'
        Should -Invoke -ModuleName PublishToIIS Start-PublishTask -Times 1
    }

    It 'no devuelve el resultado de la ejecución anterior aunque siga en disco' {
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        '{"status":"error","message":"lo de ayer","runId":"de-ayer"}' |
            Set-Content (Join-Path $script:dataDir 'publish-order.result.json') -Encoding UTF8

        Mock -ModuleName PublishToIIS Start-PublishTask {
            param($TaskName, $DataDir)
            $runId = (Get-Content (Join-Path $DataDir 'publish-order.json') -Raw | ConvertFrom-Json).runId
            "{`"status`":`"ok`",`"message`":`"lo de ahora`",`"runId`":`"$runId`"}" |
                Set-Content (Join-Path $DataDir 'publish-order.result.json') -Encoding UTF8
        }

        (Request-Publish -Environment 'devecoand1' -Branch 'main' -DataDir $script:dataDir -TimeoutSeconds 10).message |
            Should -Be 'lo de ahora'
    }

    It 'con -NoWait no espera resultado y devuelve la orden escrita' {
        Mock -ModuleName PublishToIIS Start-PublishTask { }
        $r = Request-Publish -Environment 'devecoand1' -Branch 'main' -DataDir $script:dataDir -NoWait
        $r.status | Should -Be 'triggered'
        Test-Path (Join-Path $script:dataDir 'publish-order.json') | Should -BeTrue
    }

    It 'no dispara la tarea si la orden es inválida' {
        Mock -ModuleName PublishToIIS Start-PublishTask { }
        { Request-Publish -Environment 'devecoand1' -Branch 'bad;branch' -DataDir $script:dataDir } |
            Should -Throw '*formato inválido*'
        Should -Invoke -ModuleName PublishToIIS Start-PublishTask -Times 0
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
