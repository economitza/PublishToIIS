Import-Module -Name (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

Describe 'Encoding de los scripts' {
    # Windows PowerShell 5.1 lee un .ps1 UTF-8 SIN BOM como ANSI: los acentos
    # salen como mojibake (la a con tilde se convierte en dos caracteres raros)
    # en pantalla y en cualquier texto que el script componga. Como el registro
    # de la tarea y el Install los ejecuta
    # powershell.exe (5.1), todo fichero con acentos tiene que llevar BOM.
    It 'todo .ps1/.psm1/.psd1 con caracteres no ASCII lleva BOM UTF-8' {
        $root = Split-Path $PSScriptRoot -Parent
        $sinBom = Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1, *.psd1 -File |
            Where-Object { $_.FullName -notmatch '\\\.git\\' } |
            Where-Object {
                $bytes = [IO.File]::ReadAllBytes($_.FullName)
                $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
                $noAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
                $noAscii -and -not $bom
            } |
            ForEach-Object { $_.FullName.Replace("$root\", '') }

        $sinBom -join ', ' | Should -BeNullOrEmpty
    }

    It 'ningún script arrastra mojibake ya escrito' {
        $root = Split-Path $PSScriptRoot -Parent
        # El patrón se compone por código: escrito literal, este fichero se
        # detectaría a sí mismo.
        $mojibake = "$([char]0xC3).|$([char]0xE2)$([char]0x82)|$([char]0xE2)$([char]0x80)"
        $malos = Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1, *.psd1 -File |
            Where-Object { $_.FullName -notmatch '\\\.git\\' } |
            Where-Object { (Get-Content $_.FullName -Raw) -match $mojibake } |
            ForEach-Object { $_.FullName.Replace("$root\", '') }

        $malos -join ', ' | Should -BeNullOrEmpty
    }
}

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

    It 'vuelca solo lo nuevo del log, no lo que ya estaba' {
        $log = Join-Path $script:dataDir 'publish-order.log'
        'RESTOS DE AYER' | Set-Content $log -Encoding UTF8

        $salida = InModuleScope PublishToIIS -Parameters @{ log = $log } {
            param($log)
            # tal como arranca Wait-PublishResult: posición y marca del log actual
            $pos = (Get-Item $log).Length
            $st = (Get-Item $log).CreationTimeUtc
            Add-Content $log 'LINEA DE ESTA EJECUCION' -Encoding UTF8
            (Write-PublishLogTail -Path $log -Position $pos -Stamp ([ref]$st) 6>&1) | Out-String
        }
        $salida | Should -Match 'LINEA DE ESTA EJECUCION'
        $salida | Should -Not -Match 'RESTOS DE AYER'
    }

    It 'si la tarea recrea el transcript, lo lee desde el principio' {
        $log = Join-Path $script:dataDir 'publish-order.log'
        'RESTOS DE AYER, un log largo que ocupa mucho mas que el nuevo' | Set-Content $log -Encoding UTF8

        $salida = InModuleScope PublishToIIS -Parameters @{ log = $log } {
            param($log)
            $pos = (Get-Item $log).Length
            $st = (Get-Item $log).CreationTimeUtc
            'NUEVO' | Set-Content $log -Encoding UTF8   # transcript recreado, mas corto
            (Write-PublishLogTail -Path $log -Position $pos -Stamp ([ref]$st) 6>&1) | Out-String
        }
        $salida | Should -Match 'NUEVO'
    }

    It 'con -Quiet no vuelca el log' {
        'no deberia verse' | Set-Content (Join-Path $script:dataDir 'publish-order.log') -Encoding UTF8
        '{"status":"ok","runId":"dddd"}' |
            Set-Content (Join-Path $script:dataDir 'publish-order.result.json') -Encoding UTF8

        $salida = Wait-PublishResult -DataDir $script:dataDir -RunId 'dddd' -TimeoutSeconds 5 -Quiet 6>&1
        ($salida | Out-String) | Should -Not -Match 'no deberia verse'
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

Describe 'Endpoint de despliegue' {
    BeforeEach {
        $script:dataDir = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_ep_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        $script:token = 'a' * 64
    }

    AfterEach {
        Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'token' {
        It 'genera un token de 64 hex y lo persiste' {
            $t = New-DeployEndpointToken -DataDir $script:dataDir
            $t | Should -Match '^[0-9a-f]{64}$'
            (Get-DeployEndpointToken -DataDir $script:dataDir) | Should -Be $t
        }

        It 'no sobrescribe un token existente sin -Force' {
            New-DeployEndpointToken -DataDir $script:dataDir | Out-Null
            { New-DeployEndpointToken -DataDir $script:dataDir } | Should -Throw '*Ya existe*'
        }

        It 'con -Force rota el token' {
            $a = New-DeployEndpointToken -DataDir $script:dataDir
            $b = New-DeployEndpointToken -DataDir $script:dataDir -Force
            $a | Should -Not -Be $b
        }

        It 'valida el token correcto y rechaza el incorrecto (y el vacío)' {
            InModuleScope PublishToIIS {
                (Test-DeployEndpointToken -Presented 'secreto' -Expected 'secreto') | Should -BeTrue
                (Test-DeployEndpointToken -Presented 'malo' -Expected 'secreto') | Should -BeFalse
                (Test-DeployEndpointToken -Presented '' -Expected 'secreto') | Should -BeFalse
            }
        }
    }

    Context 'Invoke-DeployEndpointRequest' {
        It '/health responde 200 sin token' {
            $r = Invoke-DeployEndpointRequest -Method GET -Path '/health' -DataDir $script:dataDir
            $r.status | Should -Be 200
            $r.body.ok | Should -BeTrue
        }

        It 'rechaza con 401 cualquier ruta protegida sin token válido' {
            $r = Invoke-DeployEndpointRequest -Method GET -Path '/api/environments' `
                -Token 'malo' -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 401
        }

        It 'lista los entornos permitidos con token válido' {
            $r = Invoke-DeployEndpointRequest -Method GET -Path '/api/environments' `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 200
            $r.body.environments | Should -Contain 'devecoesp1'
            $r.body.environments | Should -Not -Contain 'prod'
        }

        It 'POST /api/publish encola, devuelve 202 queued con runId y posición 1' {
            $body = '{"environment":"devecoesp1","branch":"main_deploy-20260901","execute":true}'
            $r = Invoke-DeployEndpointRequest -Method POST -Path '/api/publish' -Body $body `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 202
            $r.body.status | Should -Be 'queued'
            $r.body.runId | Should -Not -BeNullOrEmpty
            $r.body.position | Should -Be 1
            $r.body.execute | Should -BeTrue
            @(Get-DeployQueue -DataDir $script:dataDir).Count | Should -Be 1
        }

        It 'un execute que no es booleano degrada a dry-run' {
            $body = '{"environment":"devecoesp1","branch":"main","execute":"true"}'
            $r = Invoke-DeployEndpointRequest -Method POST -Path '/api/publish' -Body $body `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.body.execute | Should -BeFalse
            (Get-DeployQueue -DataDir $script:dataDir)[0].execute | Should -BeFalse
        }

        It 'rechaza con 400 una rama con formato inválido, sin encolar nada' {
            $body = '{"environment":"devecoesp1","branch":"main;otra"}'
            $r = Invoke-DeployEndpointRequest -Method POST -Path '/api/publish' -Body $body `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 400
            @(Get-DeployQueue -DataDir $script:dataDir).Count | Should -Be 0
        }

        It 'rechaza con 400 un entorno fuera de la lista blanca (prod), sin encolar' {
            $body = '{"environment":"prod","branch":"main"}'
            $r = Invoke-DeployEndpointRequest -Method POST -Path '/api/publish' -Body $body `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 400
            @(Get-DeployQueue -DataDir $script:dataDir).Count | Should -Be 0
        }

        It 'una segunda orden NO se rechaza: se encola en posición 2' {
            $body = '{"environment":"devecoesp1","branch":"main"}'
            Invoke-DeployEndpointRequest -Method POST -Path '/api/publish' -Body $body `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir | Out-Null
            $r = Invoke-DeployEndpointRequest -Method POST -Path '/api/publish' -Body $body `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 202
            $r.body.position | Should -Be 2
            @(Get-DeployQueue -DataDir $script:dataDir).Count | Should -Be 2
        }

        It '/api/queue lista la cola pendiente en orden' {
            Add-DeployQueueItem -Environment 'devecoesp1' -Branch 'rama-a' -DataDir $script:dataDir | Out-Null
            Add-DeployQueueItem -Environment 'devecoand1' -Branch 'rama-b' -DataDir $script:dataDir | Out-Null
            $r = Invoke-DeployEndpointRequest -Method GET -Path '/api/queue' `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 200
            $r.body.queue[0].branch | Should -Be 'rama-a'
            $r.body.queue[1].branch | Should -Be 'rama-b'
        }

        It '/api/result devuelve el resultado terminado por runId' {
            New-Item -ItemType Directory -Path (Join-Path $script:dataDir 'results') -Force | Out-Null
            '{"status":"ok","runId":"xyz","message":"hecho"}' |
                Set-Content (Join-Path $script:dataDir 'results\xyz.json') -Encoding UTF8
            $r = Invoke-DeployEndpointRequest -Method GET -Path '/api/result' -Query @{ runId = 'xyz' } `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 200
            $r.body.message | Should -Be 'hecho'
        }

        It '/api/result devuelve queued si la orden sigue en la cola' {
            $item = Add-DeployQueueItem -Environment 'devecoesp1' -Branch 'main' -DataDir $script:dataDir
            $r = Invoke-DeployEndpointRequest -Method GET -Path '/api/result' -Query @{ runId = $item.runId } `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 200
            $r.body.status | Should -Be 'queued'
            $r.body.position | Should -Be 1
        }

        It '/api/result devuelve 404 para un runId desconocido' {
            $r = Invoke-DeployEndpointRequest -Method GET -Path '/api/result' -Query @{ runId = 'nada' } `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 404
        }

        It 'una ruta desconocida devuelve 404' {
            $r = Invoke-DeployEndpointRequest -Method GET -Path '/api/loquesea' `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 404
        }
    }

    Context 'cola FIFO (Add / Get / Drain)' {
        It 'Add valida entorno y rama antes de encolar' {
            { Add-DeployQueueItem -Environment 'prod' -Branch 'main' -DataDir $script:dataDir } | Should -Throw '*no permitido*'
            { Add-DeployQueueItem -Environment 'devecoesp1' -Branch 'main;otra' -DataDir $script:dataDir } | Should -Throw '*inválido*'
            @(Get-DeployQueue -DataDir $script:dataDir).Count | Should -Be 0
        }

        It 'conserva el orden de llegada (FIFO) aunque se encolen seguidas' {
            foreach ($b in 'a', 'b', 'c', 'd', 'e') {
                Add-DeployQueueItem -Environment 'devecoesp1' -Branch $b -DataDir $script:dataDir | Out-Null
            }
            (Get-DeployQueue -DataDir $script:dataDir).branch | Should -Be @('a', 'b', 'c', 'd', 'e')
        }

        It 'Drain procesa la cola de una en una, escribe resultados y la vacía' {
            Mock -ModuleName PublishToIIS Request-Publish { [pscustomobject]@{ status = 'ok'; message = 'mock' } }
            $ids = @()
            foreach ($b in 'uno', 'dos', 'tres') {
                $ids += (Add-DeployQueueItem -Environment 'devecoesp1' -Branch $b -Execute -DataDir $script:dataDir).runId
            }
            $n = Invoke-DeployQueueDrain -DataDir $script:dataDir
            $n | Should -Be 3
            @(Get-DeployQueue -DataDir $script:dataDir).Count | Should -Be 0
            Should -Invoke -ModuleName PublishToIIS Request-Publish -Times 3
            foreach ($id in $ids) {
                (Get-DeployResult -RunId $id -DataDir $script:dataDir).status | Should -Be 'ok'
            }
        }

        It 'Drain marca error el runId si la publicación lanza, y sigue con el resto' {
            Mock -ModuleName PublishToIIS Request-Publish { throw 'boom' }
            $id = (Add-DeployQueueItem -Environment 'devecoesp1' -Branch 'x' -Execute -DataDir $script:dataDir).runId
            Invoke-DeployQueueDrain -DataDir $script:dataDir | Out-Null
            $res = Get-DeployResult -RunId $id -DataDir $script:dataDir
            $res.status | Should -Be 'error'
            $res.message | Should -Be 'boom'
            @(Get-DeployQueue -DataDir $script:dataDir).Count | Should -Be 0
        }

        It 'Drain aparta una orden ilegible a .bad sin atascarse' {
            Mock -ModuleName PublishToIIS Request-Publish { [pscustomobject]@{ status = 'ok'; message = 'mock' } }
            $qdir = Join-Path $script:dataDir 'queue'
            New-Item -ItemType Directory -Path $qdir -Force | Out-Null
            'esto no es json' | Set-Content (Join-Path $qdir '000000000001-corrupta.json') -Encoding UTF8
            $good = (Add-DeployQueueItem -Environment 'devecoesp1' -Branch 'buena' -Execute -DataDir $script:dataDir).runId
            Invoke-DeployQueueDrain -DataDir $script:dataDir | Out-Null
            (Get-ChildItem $qdir -Filter '*.bad').Count | Should -Be 1
            (Get-DeployResult -RunId $good -DataDir $script:dataDir).status | Should -Be 'ok'
        }
    }
}

Describe 'Get-PublishToIISRepo' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_repo_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:tmp '.git') -Force | Out-Null
        $script:prevEnv = $env:PUBLISHTOIIS_REPO
    }

    AfterEach {
        $env:PUBLISHTOIIS_REPO = $script:prevEnv
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'usa -RepoPath cuando se le pasa' {
        Get-PublishToIISRepo -RepoPath $script:tmp | Should -Be (Resolve-Path $script:tmp).Path
    }

    It 'usa PUBLISHTOIIS_REPO si no se le pasa ruta' {
        $env:PUBLISHTOIIS_REPO = $script:tmp
        Get-PublishToIISRepo | Should -Be (Resolve-Path $script:tmp).Path
    }

    It 'cae en el propio repo del módulo si no hay variable' {
        $env:PUBLISHTOIIS_REPO = $null
        # Los tests corren sobre la copia de trabajo, así que debe resolverla
        Get-PublishToIISRepo | Should -Match 'PublishToIIS$'
    }

    It 'rechaza una ruta que no es copia de trabajo git' {
        $noRepo = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_norepo_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $noRepo | Out-Null
        try {
            # Sin .git no la acepta: cae al siguiente candidato, nunca la devuelve
            Get-PublishToIISRepo -RepoPath $noRepo | Should -Not -Be $noRepo
        }
        finally { Remove-Item $noRepo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Register-PublishTask' {
    It 'falla con mensaje accionable si no encuentra el repo' {
        Mock -ModuleName PublishToIIS Get-PublishToIISRepo { throw 'No se encontró la copia de trabajo git del módulo.' }
        { Register-PublishTask } | Should -Throw '*copia de trabajo git*'
    }
}

Describe 'Register-DeployEndpoint' {
    It 'localiza el repo y ejecuta el script de registro del endpoint' {
        $fakeRepo = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_ep_reg_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'tools') -Force | Out-Null
        # Un script sonda que solo escribe que lo llamaron (no eleva ni registra nada).
        $marker = Join-Path $fakeRepo 'called.txt'
        Set-Content (Join-Path $fakeRepo 'tools\Register-DeployEndpointTask.ps1') `
            "param([int]`$Port,[string]`$TaskName,[string]`$DrainerTaskName,[string]`$PublishTaskName) 'called ' + `$Port | Set-Content '$marker'"
        try {
            Mock -ModuleName PublishToIIS Get-PublishToIISRepo { $fakeRepo }
            Register-DeployEndpoint -Port 8799
            Test-Path $marker | Should -BeTrue
            (Get-Content $marker -Raw).Trim() | Should -Be 'called 8799'
        }
        finally { Remove-Item $fakeRepo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'falla con mensaje accionable si el repo no trae las tools del endpoint' {
        $bareRepo = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_ep_bare_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $bareRepo -Force | Out-Null
        try {
            Mock -ModuleName PublishToIIS Get-PublishToIISRepo { $bareRepo }
            { Register-DeployEndpoint } | Should -Throw '*Update-PublishToIIS*'
        }
        finally { Remove-Item $bareRepo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Register-DeployProxySite' {
    It 'localiza el repo y ejecuta el script del site pasando el hostname' {
        $fakeRepo = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_ps_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'tools') -Force | Out-Null
        $marker = Join-Path $fakeRepo 'called.txt'
        Set-Content (Join-Path $fakeRepo 'tools\Register-DeployProxySite.ps1') `
            "param([string]`$HostName,[int]`$Port,[string]`$SiteName,[string]`$RestrictToIp,[string]`$CertThumbprint,[string]`$FromSite,[switch]`$DryRun,[switch]`$NonInteractive) `$HostName + '|' + `$Port | Set-Content '$marker'"
        try {
            Mock -ModuleName PublishToIIS Get-PublishToIISRepo { $fakeRepo }
            Register-DeployProxySite -HostName 'deployments-76.economitza.com' -DryRun
            (Get-Content $marker -Raw).Trim() | Should -Be 'deployments-76.economitza.com|8770'
        }
        finally { Remove-Item $fakeRepo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'falla con mensaje accionable si el repo no trae el script del site' {
        $bareRepo = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_ps_bare_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $bareRepo -Force | Out-Null
        try {
            Mock -ModuleName PublishToIIS Get-PublishToIISRepo { $bareRepo }
            { Register-DeployProxySite -HostName 'x.economitza.com' } | Should -Throw '*Update-PublishToIIS*'
        }
        finally { Remove-Item $bareRepo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Tokens por servidor y Get-DeployServerUrl' {
    BeforeEach {
        $script:dataDir = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_tok_" + [Guid]::NewGuid())
    }
    AfterEach { Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'Set/Get-DeployToken guarda y lee cada token por nombre de servidor' {
        Set-DeployToken -Server 'srvA' -Token 'tok-A' -DataDir $script:dataDir
        Set-DeployToken -Server 'srvB' -Token 'tok-B' -DataDir $script:dataDir
        Get-DeployToken -Server 'srvA' -DataDir $script:dataDir | Should -Be 'tok-A'
        Get-DeployToken -Server 'srvB' -DataDir $script:dataDir | Should -Be 'tok-B'
    }

    It 'Get-DeployToken sin registro y sin variable devuelve null' {
        $prev = $env:PUBLISHTOIIS_API_TOKEN
        $env:PUBLISHTOIIS_API_TOKEN = $null
        try { Get-DeployToken -Server 'noexiste' -DataDir $script:dataDir | Should -BeNullOrEmpty }
        finally { $env:PUBLISHTOIIS_API_TOKEN = $prev }
    }

    It 'Get-DeployServerUrl resuelve el endpointUrl del config' {
        Get-DeployServerUrl -Server 'deployments-76' | Should -Be 'https://deployments-76.economitza.com'
        Get-DeployServerUrl -Server 'portatil' | Should -Be 'http://127.0.0.1:8770'
    }

    It 'Get-DeployServerUrl falla si el servidor no existe en el config' {
        { Get-DeployServerUrl -Server 'inventado' } | Should -Throw '*no está en la sección*'
    }
}

Describe 'Register-Dashboard' {
    It 'localiza el repo y ejecuta el script de registro del dashboard' {
        $fakeRepo = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_dash_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'tools') -Force | Out-Null
        $marker = Join-Path $fakeRepo 'called.txt'
        Set-Content (Join-Path $fakeRepo 'tools\Register-DashboardTask.ps1') `
            "param([int]`$Port,[string]`$TaskName,[string]`$PythonExe) 'called ' + `$Port | Set-Content '$marker'"
        try {
            Mock -ModuleName PublishToIIS Get-PublishToIISRepo { $fakeRepo }
            Register-Dashboard -Port 8799
            (Get-Content $marker -Raw).Trim() | Should -Be 'called 8799'
        }
        finally { Remove-Item $fakeRepo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'falla con mensaje accionable si el repo no trae el script del dashboard' {
        $bareRepo = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_dash_bare_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $bareRepo -Force | Out-Null
        try {
            Mock -ModuleName PublishToIIS Get-PublishToIISRepo { $bareRepo }
            { Register-Dashboard } | Should -Throw '*Update-PublishToIIS*'
        }
        finally { Remove-Item $bareRepo -Recurse -Force -ErrorAction SilentlyContinue }
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
