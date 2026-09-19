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

Describe 'Restore-NuGetPackages' {
    It 'no hace nada si el proyecto no tiene packages.config' {
        $proj = Join-Path $TestDrive 'Sin\Sin.csproj'
        New-Item -ItemType Directory -Force -Path (Split-Path $proj) | Out-Null
        Set-Content -Path $proj -Value '<Project />'
        Mock -ModuleName PublishToIIS Get-NuGetExe { throw 'no debe buscar nuget' }
        { Restore-NuGetPackages -ProjectFile $proj } | Should -Not -Throw
    }

    It 'con packages.config y sin nuget.exe avisa y no lanza' {
        $proj = Join-Path $TestDrive 'Con\Con.csproj'
        New-Item -ItemType Directory -Force -Path (Split-Path $proj) | Out-Null
        Set-Content -Path $proj -Value '<Project />'
        Set-Content -Path (Join-Path (Split-Path $proj) 'packages.config') -Value '<packages />'
        Mock -ModuleName PublishToIIS Get-NuGetExe { $null }
        { Restore-NuGetPackages -ProjectFile $proj -WarningAction SilentlyContinue } | Should -Not -Throw
        Should -Invoke -ModuleName PublishToIIS Get-NuGetExe -Times 1 -Exactly
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
        # Sin -RequestedBy (publicación a mano) pide y ejecuta el mismo
        $json.requestedBy | Should -Be "$env:COMPUTERNAME\$env:USERNAME"
        $info.commit | Should -Be $json.commit
    }

    It 'anota en requestedBy quién pidió el deploy cuando viene de la orden' {
        $json = New-DeployInfo -ProjectPath $script:repoDir -OutputDir $script:outDir -Environment 'e' -RequestedBy 'PC-ANA\ana'
        $json.requestedBy | Should -Be 'PC-ANA\ana'
        (Get-Content (Join-Path $script:outDir 'deploy-info.json') -Raw | ConvertFrom-Json).requestedBy | Should -Be 'PC-ANA\ana'
        # publishedBy sigue siendo quien ejecuta: son dos hechos distintos
        $json.publishedBy | Should -Be "$env:USERNAME@$env:COMPUTERNAME"
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
        '{"environment":"dev-joaquim-local","branch":"main_deploy-20260720a","execute":true,"overrideWebconfig":false,"requestedBy":"PC-ANA\\ana"}' |
            Set-Content $script:orderPath -Encoding UTF8
        $order = Read-PublishOrder -Path $script:orderPath
        $order.environment | Should -Be 'dev-joaquim-local'
        $order.branch | Should -Be 'main_deploy-20260720a'
        $order.execute | Should -BeTrue
        $order.overrideWebconfig | Should -BeFalse
        $order.requestedBy | Should -Be 'PC-ANA\ana'
    }

    It 'execute es false (dry-run) si la orden no lo indica' {
        '{"environment":"dev-joaquim-local","branch":"main"}' | Set-Content $script:orderPath -Encoding UTF8
        (Read-PublishOrder -Path $script:orderPath).execute | Should -BeFalse
    }

    It 'requestedBy queda vacío si la orden no lo trae (orden de una versión anterior)' {
        '{"environment":"dev-joaquim-local","branch":"main"}' | Set-Content $script:orderPath -Encoding UTF8
        (Read-PublishOrder -Path $script:orderPath).requestedBy | Should -BeNullOrEmpty
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

    It 'conserva -RequestedBy en la orden; sin él anota EQUIPO\usuario del proceso' {
        $w = Write-PublishOrder -Environment 'devecoand1' -Branch 'main' -DataDir $script:dataDir -RequestedBy 'PC-ANA\ana'
        (Read-PublishOrder -Path $w.path).requestedBy | Should -Be 'PC-ANA\ana'
        $w = Write-PublishOrder -Environment 'devecoand1' -Branch 'main' -DataDir $script:dataDir
        (Read-PublishOrder -Path $w.path).requestedBy | Should -Be "$env:COMPUTERNAME\$env:USERNAME"
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

Describe 'Entornos ad hoc (worktrees efimeros)' {
    BeforeEach {
        $script:dataDir = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_adhoc_" + [Guid]::NewGuid())
        $script:envFile = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_env_" + [Guid]::NewGuid() + ".json")
        @{
            name        = 'wt-prueba-esp'
            origin      = 'C:\claude-worktrees\repo\wt\CentralCompres\'
            destination = 'C:\inetpub\wwwroot\economitza_espana'
            appPool     = 'economitza_espana'
            siteUrl     = 'https://esp.emkt.test'
        } | ConvertTo-Json | Set-Content $script:envFile -Encoding UTF8
    }

    AfterEach {
        Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $script:envFile -Force -ErrorAction SilentlyContinue
    }

    It 'Read-AdHocEnvironment lee una definición válida' {
        $def = Read-AdHocEnvironment -Path $script:envFile
        $def.name | Should -Be 'wt-prueba-esp'
        $def.origin | Should -Be 'C:\claude-worktrees\repo\wt\CentralCompres\'
    }

    It 'Read-AdHocEnvironment exige name, origin y destination' {
        '{"name":"x","origin":"C:\\a"}' | Set-Content $script:envFile -Encoding UTF8
        { Read-AdHocEnvironment -Path $script:envFile } | Should -Throw "*destination*"
    }

    It 'Read-AdHocEnvironment rechaza nombres que colisionan con la config central' {
        '{"name":"devecoand1","origin":"C:\\a","destination":"C:\\b"}' | Set-Content $script:envFile -Encoding UTF8
        { Read-AdHocEnvironment -Path $script:envFile } | Should -Throw '*colisiona*'
    }

    It 'Read-AdHocEnvironment rechaza prod/staging' {
        '{"name":"prod","origin":"C:\\a","destination":"C:\\b"}' | Set-Content $script:envFile -Encoding UTF8
        { Read-AdHocEnvironment -Path $script:envFile } | Should -Throw '*no permitido*'
    }

    It 'la orden lleva environmentDef y sobrevive al roundtrip con Read-PublishOrder' {
        $w = Write-PublishOrder -EnvironmentFile $script:envFile -Branch 'main_rebranding' -Execute -DataDir $script:dataDir
        $order = Read-PublishOrder -Path $w.path
        $order.environment | Should -Be 'wt-prueba-esp'
        $order.environmentDef.origin | Should -Be 'C:\claude-worktrees\repo\wt\CentralCompres\'
        $order.environmentDef.destination | Should -Be 'C:\inetpub\wwwroot\economitza_espana'
    }

    It 'Write-PublishOrder rechaza -Environment que no coincide con el name del fichero' {
        { Write-PublishOrder -Environment 'otro' -EnvironmentFile $script:envFile -Branch 'main' -DataDir $script:dataDir } |
            Should -Throw '*no coincide*'
    }

    It 'Write-PublishOrder sin -Environment ni -EnvironmentFile falla con mensaje claro' {
        { Write-PublishOrder -Branch 'main' -DataDir $script:dataDir } | Should -Throw '*-EnvironmentFile*'
    }

    It 'Read-PublishOrder rechaza environmentDef incompleto o incoherente' {
        $orderPath = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_order_" + [Guid]::NewGuid() + ".json")
        try {
            '{"environment":"x","branch":"main","environmentDef":{"name":"x","origin":"C:\\a"}}' | Set-Content $orderPath -Encoding UTF8
            { Read-PublishOrder -Path $orderPath } | Should -Throw "*destination*"
            '{"environment":"x","branch":"main","environmentDef":{"name":"y","origin":"C:\\a","destination":"C:\\b"}}' | Set-Content $orderPath -Encoding UTF8
            { Read-PublishOrder -Path $orderPath } | Should -Throw '*incoherente*'
        } finally { Remove-Item $orderPath -Force -ErrorAction SilentlyContinue }
    }

    It 'Invoke-DeployOrder (dry-run) resuelve el plan desde la definición ad hoc' {
        $def = Read-AdHocEnvironment -Path $script:envFile
        $plan = Invoke-DeployOrder -Environment 'wt-prueba-esp' -Branch 'main_rebranding' -EnvironmentDef $def
        $plan.origin | Should -Be 'C:\claude-worktrees\repo\wt\CentralCompres\'
        $plan.destination | Should -Be 'C:\inetpub\wwwroot\economitza_espana'
        $plan.mode | Should -Be 'DRY-RUN'
    }

    It 'Invoke-DeployOrder rechaza una definición ad hoc que colisiona con la config central' {
        $def = [pscustomobject]@{ name = 'devecoand1'; origin = 'C:\a'; destination = 'C:\b' }
        { Invoke-DeployOrder -Environment 'devecoand1' -Branch 'main' -EnvironmentDef $def } | Should -Throw '*colisiona*'
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

        It 'POST /api/publish conserva requestedBy en la orden encolada, saneado a texto plano' {
            $body = '{"environment":"devecoesp1","branch":"main","execute":true,"requestedBy":"PC-ANA\\ana<script>"}'
            $r = Invoke-DeployEndpointRequest -Method POST -Path '/api/publish' -Body $body `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 202
            (Get-DeployQueue -DataDir $script:dataDir)[0].requestedBy | Should -Be 'PC-ANA\anascript'
        }

        It 'POST /api/publish sin requestedBy encola con la cuenta del proceso' {
            $body = '{"environment":"devecoesp1","branch":"main","execute":true}'
            Invoke-DeployEndpointRequest -Method POST -Path '/api/publish' -Body $body `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir | Out-Null
            (Get-DeployQueue -DataDir $script:dataDir)[0].requestedBy | Should -Be "$env:COMPUTERNAME\$env:USERNAME"
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

        It 'Drain pasa el requestedBy de la orden a Request-Publish y lo deja en el resultado' {
            Mock -ModuleName PublishToIIS Request-Publish { [pscustomobject]@{ status = 'ok'; message = 'mock' } }
            $id = (Add-DeployQueueItem -Environment 'devecoesp1' -Branch 'main' -Execute -RequestedBy 'PC-ANA\ana' -DataDir $script:dataDir).runId
            Invoke-DeployQueueDrain -DataDir $script:dataDir | Out-Null
            Should -Invoke -ModuleName PublishToIIS Request-Publish -Times 1 -ParameterFilter { $RequestedBy -eq 'PC-ANA\ana' }
            (Get-DeployResult -RunId $id -DataDir $script:dataDir).requestedBy | Should -Be 'PC-ANA\ana'
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

Describe 'Request-RemotePublish' {
    It 'manda requestedBy en la orden: el indicado, o EQUIPO\usuario del proceso' {
        Mock -ModuleName PublishToIIS Invoke-RestMethod { [pscustomobject]@{ runId = 'r1'; position = 1 } }
        Request-RemotePublish -Url 'http://ep.test' -Token 't' -Environment 'devecoesp1' -Branch 'main' -NoWait -RequestedBy 'PC-ANA\ana' | Out-Null
        Should -Invoke -ModuleName PublishToIIS Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'Post' -and ([Text.Encoding]::UTF8.GetString($Body) -like '*"requestedBy":"PC-ANA\\ana"*')
        }
        Request-RemotePublish -Url 'http://ep.test' -Token 't' -Environment 'devecoesp1' -Branch 'main' -NoWait | Out-Null
        $propio = "$env:COMPUTERNAME\\$env:USERNAME"
        Should -Invoke -ModuleName PublishToIIS Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'Post' -and ([Text.Encoding]::UTF8.GetString($Body) -like "*`"requestedBy`":`"$propio`"*")
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

Describe 'Publish preserva connections.config como el web.config' {
    It 'Protect-ProductionWebConfig sirve para connections.config: preserva el del site sobre el del build' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_conn_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $tmp 'site') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tmp 'rel') -Force | Out-Null
        try {
            'SITE' | Set-Content (Join-Path $tmp 'site\connections.config')
            'BUILD' | Set-Content (Join-Path $tmp 'rel\connections.config')
            $r = Protect-ProductionWebConfig -TargetWebConfig (Join-Path $tmp 'site\connections.config') -ReleasingWebConfig (Join-Path $tmp 'rel\connections.config')
            $r | Should -Be 'preserved'
            (Get-Content (Join-Path $tmp 'rel\connections.config') -Raw).Trim() | Should -Be 'SITE'
            # y si el build no trae el fichero (gitignored en el repo), el del site igualmente viaja
            Remove-Item (Join-Path $tmp 'rel\connections.config')
            Protect-ProductionWebConfig -TargetWebConfig (Join-Path $tmp 'site\connections.config') -ReleasingWebConfig (Join-Path $tmp 'rel\connections.config') | Should -Be 'preserved'
            Test-Path (Join-Path $tmp 'rel\connections.config') | Should -BeTrue
        }
        finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Aprovisionamiento de sites (Initialize-IisSite y piezas)' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_prov_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
    }
    AfterEach { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'Test-CertCoversHost acepta el nombre exacto y el wildcard de un nivel, y rechaza el resto' {
        InModuleScope PublishToIIS {
            (Test-CertCoversHost -DnsNames @('*.economitza.com') -Target 'devecoesp3.economitza.com') | Should -BeTrue
            (Test-CertCoversHost -DnsNames @('devecoesp3.economitza.com') -Target 'devecoesp3.economitza.com') | Should -BeTrue
            (Test-CertCoversHost -DnsNames @('*.economitza.com') -Target 'a.b.economitza.com') | Should -BeFalse
            (Test-CertCoversHost -DnsNames @('*.emkt.test') -Target 'devecoesp3.economitza.com') | Should -BeFalse
        }
    }

    Context 'Set-ConnectionStringCatalog' {
        It 'cambia el catálogo en el connections.config al que apunta el Web.config por configSource' {
            $web = Join-Path $script:tmp 'Web.config'
            $conn = Join-Path $script:tmp 'connections.config'
            '<configuration><connectionStrings configSource="connections.config"/></configuration>' | Set-Content $web -Encoding UTF8
            @'
<connectionStrings>
  <add name="cc" connectionString="Data Source=localhost;Initial Catalog=CCEspana;Integrated Security=True" providerName="System.Data.SqlClient" />
  <add name="otra" connectionString="Data Source=MBM\SQL2014;Initial Catalog=CCGenericos;User ID=u;Password=p" providerName="System.Data.SqlClient" />
</connectionStrings>
'@ | Set-Content $conn -Encoding UTF8

            $n = Set-ConnectionStringCatalog -WebConfigPath $web -DatabaseMap @{ CCEspana = 'CCEspana_esp3' }
            $n | Should -Be 1
            $txt = Get-Content $conn -Raw
            $txt | Should -Match 'Initial Catalog=CCEspana_esp3;Integrated'
            $txt | Should -Match 'Initial Catalog=CCGenericos;'
        }

        It 'cambia el catálogo en un Web.config con las cadenas inline (Database= también) y no toca el resto' {
            $web = Join-Path $script:tmp 'Web.config'
            @'
<configuration>
  <connectionStrings>
    <add name="a" connectionString="Server=.;Database=CCAndorra;Trusted_Connection=True" />
    <add name="b" connectionString="Server=.;Database=Logs;Trusted_Connection=True" />
  </connectionStrings>
</configuration>
'@ | Set-Content $web -Encoding UTF8
            (Set-ConnectionStringCatalog -WebConfigPath $web -DatabaseMap @{ ccandorra = 'CCAndorra_and3' }) | Should -Be 1
            $txt = Get-Content $web -Raw
            $txt | Should -Match 'Database=CCAndorra_and3;'
            $txt | Should -Match 'Database=Logs;'
        }

        It 'devuelve 0 si el mapa no casa con ninguna cadena o no hay fichero' {
            $web = Join-Path $script:tmp 'Web.config'
            '<configuration><connectionStrings><add name="a" connectionString="Server=.;Database=X" /></connectionStrings></configuration>' | Set-Content $web -Encoding UTF8
            (Set-ConnectionStringCatalog -WebConfigPath $web -DatabaseMap @{ Y = 'Z' }) | Should -Be 0
            (Set-ConnectionStringCatalog -WebConfigPath (Join-Path $script:tmp 'no.config') -DatabaseMap @{ Y = 'Z' }) | Should -Be 0
        }
    }

    It 'Get-LocalIntegratedSqlServers sigue el configSource y solo devuelve instancias locales con Integrated Security' {
        $web = Join-Path $script:tmp 'Web.config'
        $conn = Join-Path $script:tmp 'connections.config'
        '<configuration><connectionStrings configSource="connections.config"/></configuration>' | Set-Content $web -Encoding UTF8
        @'
<connectionStrings>
  <add name="local" connectionString="Data Source=localhost;Initial Catalog=CCEspana;Integrated Security=True" />
  <add name="remota" connectionString="Data Source=MBM\SQL2014;Initial Catalog=CCGenericos;User ID=u;Password=p" />
  <add name="localsql" connectionString="Data Source=.\SQLEXPRESS;Initial Catalog=X;User ID=u;Password=p" />
</connectionStrings>
'@ | Set-Content $conn -Encoding UTF8
        InModuleScope PublishToIIS -Parameters @{ web = $web } {
            $srv = Get-LocalIntegratedSqlServers -WebConfigPath $web
            @($srv) | Should -Be @('localhost')
        }
    }

    It 'ConvertTo-DatabaseMap acepta hashtable y PSCustomObject (del JSON) y devuelve null si está vacío' {
        InModuleScope PublishToIIS {
            $h = ConvertTo-DatabaseMap ([pscustomobject]@{ CCEspana = 'CCEspana_esp3' })
            $h | Should -BeOfType [hashtable]
            $h['CCEspana'] | Should -Be 'CCEspana_esp3'
            (ConvertTo-DatabaseMap @{ a = 'b' })['a'] | Should -Be 'b'
            ConvertTo-DatabaseMap $null | Should -BeNullOrEmpty
            ConvertTo-DatabaseMap ([pscustomobject]@{}) | Should -BeNullOrEmpty
        }
    }

    It 'Initialize-IisSite exige administrador (o IIS): sin elevación lanza antes de tocar nada' {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) { Set-ItResult -Skipped -Because 'la sesión de tests está elevada' ; return }
        { Initialize-IisSite -Name 'p2iis-test' -Destination (Join-Path $script:tmp 'site') -HostName 'p2iis.test' } |
            Should -Throw '*administrador*'
        Test-Path (Join-Path $script:tmp 'site') | Should -BeFalse
    }

    It 'Invoke-DeployOrder (dry-run) con entorno ad hoc que declara templateSite lo refleja en el plan sin tocar IIS' {
        $def = [pscustomobject]@{
            name = 'p2iis-adhoc-prov'; origin = 'C:\x\repo\Proj'; destination = 'C:\x\www\site'
            siteUrl = 'https://p2iis-adhoc.test'; templateSite = 'devecoesp1'; databaseMap = [pscustomobject]@{ CCEspana = 'CCEspana_x' }
        }
        $plan = Invoke-DeployOrder -Environment 'p2iis-adhoc-prov' -Branch 'main' -EnvironmentDef $def 6>$null
        $plan.provision | Should -Match "plantilla 'devecoesp1'"
        $plan.mode | Should -Be 'DRY-RUN'
    }

    It 'Invoke-DeployOrder (dry-run) sin templateSite deja provision en "-"' {
        $plan = Invoke-DeployOrder -Environment 'devecoesp1' -Branch 'main' 6>$null
        $plan.provision | Should -Be '-'
    }
}

Describe 'Órdenes de actualización del módulo (kind=update)' {
    BeforeEach {
        $script:dataDir = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_upd_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        $script:token = 'b' * 64
    }
    AfterEach { Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue }

    Context 'orden local' {
        It 'Write-UpdateOrder escribe kind=update con runId y requestedBy, y Read-PublishOrder la lee sin exigir entorno ni rama' {
            $o = Write-UpdateOrder -DataDir $script:dataDir -RequestedBy 'PC-ANA\ana'
            $o.runId | Should -Not -BeNullOrEmpty
            $raw = Get-Content $o.path -Raw | ConvertFrom-Json
            $raw.kind | Should -Be 'update'
            $raw.requestedBy | Should -Be 'PC-ANA\ana'

            $leida = Read-PublishOrder -Path $o.path
            $leida.kind | Should -Be 'update'
            $leida.runId | Should -Be $o.runId
            $leida.execute | Should -BeTrue
            $leida.environment | Should -BeNullOrEmpty
        }

        It 'Read-PublishOrder sigue exigiendo entorno y rama en las órdenes de publicación y rechaza tipos desconocidos' {
            $p = Join-Path $script:dataDir 'publish-order.json'
            '{"kind":"publish","runId":"r"}' | Set-Content $p -Encoding UTF8
            { Read-PublishOrder -Path $p } | Should -Throw "*'environment'*"
            '{"kind":"reboot","runId":"r"}' | Set-Content $p -Encoding UTF8
            { Read-PublishOrder -Path $p } | Should -Throw '*desconocido*'
            '{"environment":"devecoesp1","branch":"main","runId":"r"}' | Set-Content $p -Encoding UTF8
            (Read-PublishOrder -Path $p).kind | Should -Be 'publish'
        }

        It 'Request-ModuleUpdate deja la orden, dispara la tarea y devuelve el resultado con su runId' {
            Mock -ModuleName PublishToIIS Start-PublishTask {
                # simula la tarea elevada: consume la orden y deja el resultado
                $orden = Get-Content (Join-Path $DataDir 'publish-order.json') -Raw | ConvertFrom-Json
                [pscustomobject]@{ status = 'ok'; message = 'Módulo actualizado: 0.4.7 -> 0.5.0'; runId = $orden.runId; kind = $orden.kind } |
                    ConvertTo-Json | Set-Content (Join-Path $DataDir 'publish-order.result.json') -Encoding UTF8
            }
            $res = Request-ModuleUpdate -DataDir $script:dataDir -TimeoutSeconds 10 -Quiet 6>$null
            $res.status | Should -Be 'ok'
            $res.kind | Should -Be 'update'
            Should -Invoke -ModuleName PublishToIIS Start-PublishTask -Times 1 -ParameterFilter { $TaskName -eq 'Publish Local' }
        }
    }

    Context 'cola y drenador' {
        It 'Add-DeployQueueItem -Kind update encola sin entorno ni rama y la cola lo muestra' {
            $item = Add-DeployQueueItem -Kind update -RequestedBy 'PC-ANA\ana' -DataDir $script:dataDir
            $q = @(Get-DeployQueue -DataDir $script:dataDir)
            $q.Count | Should -Be 1
            $q[0].kind | Should -Be 'update'
            $q[0].runId | Should -Be $item.runId
            (Get-DeployResult -RunId $item.runId -DataDir $script:dataDir).kind | Should -Be 'update'
        }

        It 'una orden de publicación sin entorno o rama sigue rechazándose' {
            { Add-DeployQueueItem -Environment 'devecoesp1' -DataDir $script:dataDir } | Should -Throw "*'environment' y 'branch'*"
        }

        It 'Drain ejecuta la actualización con Request-ModuleUpdate y las publicaciones con Request-Publish, en orden de llegada' {
            Mock -ModuleName PublishToIIS Request-Publish { [pscustomobject]@{ status = 'ok'; message = 'pub' } }
            Mock -ModuleName PublishToIIS Request-ModuleUpdate { [pscustomobject]@{ status = 'ok'; message = 'upd' } }
            $pub = (Add-DeployQueueItem -Environment 'devecoesp1' -Branch 'main' -Execute -DataDir $script:dataDir).runId
            $upd = (Add-DeployQueueItem -Kind update -DataDir $script:dataDir).runId
            $n = Invoke-DeployQueueDrain -DataDir $script:dataDir
            $n | Should -Be 2
            Should -Invoke -ModuleName PublishToIIS Request-Publish -Times 1
            Should -Invoke -ModuleName PublishToIIS Request-ModuleUpdate -Times 1
            $r = Get-DeployResult -RunId $upd -DataDir $script:dataDir
            $r.status | Should -Be 'ok'
            $r.kind | Should -Be 'update'
            $r.message | Should -Be 'upd'
            (Get-DeployResult -RunId $pub -DataDir $script:dataDir).kind | Should -Be 'publish'
        }
    }

    Context 'endpoint' {
        It 'POST /api/update encola (202) con kind update, la versión actual y sin necesitar cuerpo' {
            $r = Invoke-DeployEndpointRequest -Method POST -Path '/api/update' `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 202
            $r.body.status | Should -Be 'queued'
            $r.body.kind | Should -Be 'update'
            $r.body.runId | Should -Not -BeNullOrEmpty
            $r.body.current.version | Should -Match '^\d+\.\d+\.\d+$'
            @(Get-DeployQueue -DataDir $script:dataDir)[0].kind | Should -Be 'update'
        }

        It 'POST /api/update conserva requestedBy saneado' {
            $r = Invoke-DeployEndpointRequest -Method POST -Path '/api/update' -Body '{"requestedBy":"PC-ANA\\ana <x>"}' `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 202
            @(Get-DeployQueue -DataDir $script:dataDir)[0].requestedBy | Should -Be 'PC-ANA\ana x'
        }

        It 'GET /api/version devuelve la versión del manifiesto y exige token' {
            $sin = Invoke-DeployEndpointRequest -Method GET -Path '/api/version' -DataDir $script:dataDir
            $sin.status | Should -Be 401
            $r = Invoke-DeployEndpointRequest -Method GET -Path '/api/version' `
                -Token $script:token -ExpectedToken $script:token -DataDir $script:dataDir
            $r.status | Should -Be 200
            $esperada = [regex]::Match((Get-Content (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Raw), "ModuleVersion\s*=\s*'([^']+)'").Groups[1].Value
            $r.body.version | Should -Be $esperada
            $r.body.host | Should -Be $env:COMPUTERNAME
        }
    }

    Context 'cliente remoto' {
        It 'Request-RemoteUpdate hace POST a /api/update con requestedBy y con -NoWait devuelve el 202' {
            Mock -ModuleName PublishToIIS Invoke-RestMethod {
                [pscustomobject]@{ runId = 'u1'; position = 1; kind = 'update'; current = [pscustomobject]@{ version = '0.4.7'; commit = 'abc' } }
            }
            $r = Request-RemoteUpdate -Url 'http://ep.test' -Token 't' -NoWait -RequestedBy 'PC-ANA\ana' 6>$null
            $r.runId | Should -Be 'u1'
            Should -Invoke -ModuleName PublishToIIS Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'Post' -and $Uri -eq 'http://ep.test/api/update' -and
                ([Text.Encoding]::UTF8.GetString($Body) -like '*"requestedBy":"PC-ANA\\ana"*')
            }
        }

        It 'Get-RemoteDeployVersion consulta /api/version con el token' {
            Mock -ModuleName PublishToIIS Invoke-RestMethod { [pscustomobject]@{ version = '0.5.0' } }
            (Get-RemoteDeployVersion -Url 'http://ep.test/' -Token 't').version | Should -Be '0.5.0'
            Should -Invoke -ModuleName PublishToIIS Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'http://ep.test/api/version' -and $Headers['X-Api-Token'] -eq 't'
            }
        }
    }
}

Describe 'Get-SiteDeployInfo' {
    It 'devuelve null si el site no tiene sello' {
        Get-SiteDeployInfo -Destination $TestDrive | Should -BeNullOrEmpty
    }

    It 'lee el sello aunque venga con BOM (lo escribe Set-Content -Encoding UTF8 en 5.1)' {
        $site = Join-Path $TestDrive 'site-bom'
        New-Item -ItemType Directory -Force -Path $site | Out-Null
        [pscustomobject]@{ branch = 'main_SI-1'; commitFull = 'abc123' } |
            ConvertTo-Json | Set-Content (Join-Path $site 'deploy-info.json') -Encoding UTF8

        $info = Get-SiteDeployInfo -Destination $site
        $info.branch | Should -Be 'main_SI-1'
        $info.commitFull | Should -Be 'abc123'
    }

    It 'devuelve null si el sello esta corrupto, sin lanzar' {
        $site = Join-Path $TestDrive 'site-roto'
        New-Item -ItemType Directory -Force -Path $site | Out-Null
        Set-Content (Join-Path $site 'deploy-info.json') -Value '{ esto no es json' -Encoding UTF8
        Get-SiteDeployInfo -Destination $site | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-HotfixPlan' {
    It 'una vista se copia y no recicla el AppDomain' {
        $plan = Resolve-HotfixPlan -Path @('CentralCompres/Views/Home/Index.cshtml') -ProjectPrefix 'CentralCompres'
        $plan.copy | Should -Be 'Views/Home/Index.cshtml'
        $plan.needsBuild | Should -BeFalse
        $plan.recycles | Should -BeFalse
    }

    It 'un .cs exige compilar y recicla' {
        $plan = Resolve-HotfixPlan -Path @('CentralCompres/Controllers/HomeController.cs') -ProjectPrefix 'CentralCompres'
        $plan.build | Should -Be 'Controllers/HomeController.cs'
        $plan.copy | Should -BeNullOrEmpty
        $plan.needsBuild | Should -BeTrue
        $plan.recycles | Should -BeTrue
    }

    It 'la configuracion del entorno queda excluida, nunca viaja en un hotfix' {
        $plan = Resolve-HotfixPlan -ProjectPrefix 'CentralCompres' -Path @(
            'CentralCompres/Web.config', 'CentralCompres/connections.config', 'CentralCompres/log4net.config')
        $plan.config.Count | Should -Be 3
        $plan.copy | Should -BeNullOrEmpty
        $plan.build | Should -BeNullOrEmpty
    }

    It 'el Web.config de Views SI viaja: es routing MVC, no configuracion de entorno' {
        $plan = Resolve-HotfixPlan -Path @('CentralCompres/Views/Web.config') -ProjectPrefix 'CentralCompres'
        $plan.copy | Should -Be 'Views/Web.config'
        $plan.config | Should -BeNullOrEmpty
    }

    It 'lo que queda fuera del proyecto web no va al site' {
        $plan = Resolve-HotfixPlan -ProjectPrefix 'CentralCompres' -Path @(
            'tests/e2e/tests/favoritos.spec.ts', 'docs/70-development/checkpoint-revision.md')
        $plan.outside.Count | Should -Be 2
        $plan.copy | Should -BeNullOrEmpty
        $plan.unknown | Should -BeNullOrEmpty
    }

    It 'lo que vive en el proyecto pero no tiene destino en el site se lista y no bloquea' {
        $plan = Resolve-HotfixPlan -ProjectPrefix 'CentralCompres' -Path @(
            'CentralCompres/CHANGELOG.md', 'CentralCompres/Scheduling/tools/carga.py',
            'CentralCompres/scripts/alta-tabla.sql')
        @($plan.ignored).Count | Should -Be 3
        $plan.unknown | Should -BeNullOrEmpty
        $plan.copy | Should -BeNullOrEmpty
    }

    It 'un .dbml genera codigo: lo que llega al site es el ensamblado' {
        $plan = Resolve-HotfixPlan -Path @('CentralCompres/Models/Model/DCModel.dbml') -ProjectPrefix 'CentralCompres'
        $plan.build | Should -Be 'Models/Model/DCModel.dbml'
        $plan.unknown | Should -BeNullOrEmpty
    }

    It 'un .resx de App_GlobalResources se compila Y se copia: el site sirve los dos' {
        $plan = Resolve-HotfixPlan -ProjectPrefix 'CentralCompres' -Path @(
            'CentralCompres/App_GlobalResources/Featured_Partner/Res.es-ES.resx')
        $plan.build | Should -Be 'App_GlobalResources/Featured_Partner/Res.es-ES.resx'
        $plan.copy | Should -Be 'App_GlobalResources/Featured_Partner/Res.es-ES.resx'
    }

    It 'el Designer.cs de App_GlobalResources no se copia: es codigo fuente' {
        $plan = Resolve-HotfixPlan -ProjectPrefix 'CentralCompres' -Path @(
            'CentralCompres/App_GlobalResources/Featured_Partner/Res.Designer.cs')
        $plan.build | Should -Be 'App_GlobalResources/Featured_Partner/Res.Designer.cs'
        $plan.copy | Should -BeNullOrEmpty
    }

    It 'un .resx normal solo se compila' {
        $plan = Resolve-HotfixPlan -Path @('CentralCompres/Resources/Model.resx') -ProjectPrefix 'CentralCompres'
        $plan.build | Should -Be 'Resources/Model.resx'
        $plan.copy | Should -BeNullOrEmpty
    }

    It 'un fichero sin regla conocida cae en unknown y no se da por aplicado' {
        $plan = Resolve-HotfixPlan -Path @('CentralCompres/Datos/tarifas.dat') -ProjectPrefix 'CentralCompres'
        $plan.unknown | Should -Be 'Datos/tarifas.dat'
        $plan.copy | Should -BeNullOrEmpty
    }

    It 'bin y Global.asax se copian pero avisan de que reciclan' {
        $plan = Resolve-HotfixPlan -Path @('CentralCompres/Global.asax') -ProjectPrefix 'CentralCompres'
        $plan.copy | Should -Be 'Global.asax'
        $plan.needsBuild | Should -BeFalse
        $plan.recycles | Should -BeTrue
    }

    It 'un borrado copiable va a removed; uno compilable lo resuelve el build' {
        $plan = Resolve-HotfixPlan -ProjectPrefix 'CentralCompres' -Removed @(
            'CentralCompres/Views/Viejo.cshtml', 'CentralCompres/Models/Viejo.cs')
        $plan.removed | Should -Be 'Views/Viejo.cshtml'
        $plan.build | Should -Be 'Models/Viejo.cs'
        $plan.copy | Should -BeNullOrEmpty
    }

    It 'packages.config exige build (es el restore de NuGet)' {
        $plan = Resolve-HotfixPlan -Path @('CentralCompres/packages.config') -ProjectPrefix 'CentralCompres'
        $plan.build | Should -Be 'packages.config'
    }

    It 'acepta separadores de Windows y no repite ficheros' {
        $plan = Resolve-HotfixPlan -ProjectPrefix 'CentralCompres' -Path @(
            'CentralCompres\Scripts\ec-search-select.js', 'CentralCompres/Scripts/ec-search-select.js')
        @($plan.copy).Count | Should -Be 1
        $plan.copy | Should -Be 'Scripts/ec-search-select.js'
    }

    It 'sin prefijo el proyecto es la raiz del repo' {
        $plan = Resolve-HotfixPlan -Path @('Views/Home/Index.cshtml')
        $plan.copy | Should -Be 'Views/Home/Index.cshtml'
    }

    It 'un delta vacio no exige nada ni recicla' {
        $plan = Resolve-HotfixPlan -Path @() -ProjectPrefix 'CentralCompres'
        $plan.copy | Should -BeNullOrEmpty
        $plan.needsBuild | Should -BeFalse
        $plan.recycles | Should -BeFalse
    }
}

Describe 'Get-HotfixDelta' {
    BeforeAll {
        function New-RepoDePrueba {
            param([string]$Path)
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
            & git -C $Path init -q
            & git -C $Path config user.email 'test@economitza.com'
            & git -C $Path config user.name 'Test'
            New-Item -ItemType Directory -Force -Path (Join-Path $Path 'Web\Views') | Out-Null
            Set-Content (Join-Path $Path 'Web\Views\Index.cshtml') -Value 'v1'
            Set-Content (Join-Path $Path 'Web\Prog.cs') -Value 'class A {}'
            & git -C $Path add -A
            & git -C $Path commit -q -m 'base'
            ("$(& git -C $Path rev-parse HEAD)").Trim()
        }
    }

    It 've los cambios sin commitear: es lo que permite iterar sin commits de prueba' {
        $repo = Join-Path $TestDrive 'repo-sucio'
        $base = New-RepoDePrueba -Path $repo
        Set-Content (Join-Path $repo 'Web\Views\Index.cshtml') -Value 'v2'

        $delta = Get-HotfixDelta -Repo $repo -BaseCommit $base
        $delta.changed | Should -Contain 'Web/Views/Index.cshtml'
        $delta.dirty | Should -BeTrue
        $delta.baseIsAncestor | Should -BeTrue
    }

    It 'incluye los ficheros nuevos sin trackear' {
        $repo = Join-Path $TestDrive 'repo-nuevo'
        $base = New-RepoDePrueba -Path $repo
        Set-Content (Join-Path $repo 'Web\Views\Nuevo.cshtml') -Value 'nuevo'

        (Get-HotfixDelta -Repo $repo -BaseCommit $base).changed | Should -Contain 'Web/Views/Nuevo.cshtml'
    }

    It 'separa los borrados de los cambios' {
        $repo = Join-Path $TestDrive 'repo-borrado'
        $base = New-RepoDePrueba -Path $repo
        Remove-Item (Join-Path $repo 'Web\Views\Index.cshtml')

        $delta = Get-HotfixDelta -Repo $repo -BaseCommit $base
        $delta.removed | Should -Contain 'Web/Views/Index.cshtml'
        $delta.changed | Should -Not -Contain 'Web/Views/Index.cshtml'
    }

    It 'con -Committed ignora lo que no esta commiteado' {
        $repo = Join-Path $TestDrive 'repo-committed'
        $base = New-RepoDePrueba -Path $repo
        Set-Content (Join-Path $repo 'Web\Views\Index.cshtml') -Value 'v2'

        (Get-HotfixDelta -Repo $repo -BaseCommit $base -Committed).changed | Should -BeNullOrEmpty
    }

    It 'sin cambios devuelve un delta vacio' {
        $repo = Join-Path $TestDrive 'repo-limpio'
        $base = New-RepoDePrueba -Path $repo

        $delta = Get-HotfixDelta -Repo $repo -BaseCommit $base
        $delta.changed | Should -BeNullOrEmpty
        $delta.removed | Should -BeNullOrEmpty
        $delta.dirty | Should -BeFalse
    }

    It 'si el commit publicado no existe en el repo, lo dice en vez de calcular un delta falso' {
        $repo = Join-Path $TestDrive 'repo-sinbase'
        New-RepoDePrueba -Path $repo | Out-Null
        { Get-HotfixDelta -Repo $repo -BaseCommit '0123456789abcdef0123456789abcdef01234567' } |
            Should -Throw '*no existe*'
    }

    It 'detecta que el origen ha divergido del commit publicado' {
        $repo = Join-Path $TestDrive 'repo-divergido'
        $base = New-RepoDePrueba -Path $repo
        Set-Content (Join-Path $repo 'Web\Views\Index.cshtml') -Value 'v2'
        & git -C $repo add -A
        & git -C $repo commit -q -m 'v2'
        & git -C $repo checkout -q -B otra $base
        Set-Content (Join-Path $repo 'Web\Views\Index.cshtml') -Value 'v3'
        & git -C $repo add -A
        & git -C $repo commit -q -m 'v3'
        $otro = ("$(& git -C $repo rev-parse HEAD)").Trim()
        & git -C $repo checkout -q -B tercera $base
        & git -C $repo commit -q --allow-empty -m 'tercera'

        (Get-HotfixDelta -Repo $repo -BaseCommit $otro).baseIsAncestor | Should -BeFalse
    }
}

BeforeAll {
    function New-EntornoHotfix {
        <#  Monta un repo con un proyecto web, un site "publicado" a partir de el y el
            fichero de entorno ad hoc que los une. #>
        param([string]$Raiz)

        $repo = Join-Path $Raiz 'repo'
        $proyecto = Join-Path $repo 'Web'
        $site = Join-Path $Raiz 'site'
        New-Item -ItemType Directory -Force -Path (Join-Path $proyecto 'Views') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $proyecto 'Scripts') | Out-Null
        Set-Content (Join-Path $proyecto 'Views\Index.cshtml') -Value 'v1'
        Set-Content (Join-Path $proyecto 'Scripts\app.js') -Value 'js1'
        Set-Content (Join-Path $proyecto 'Controllers.cs') -Value 'class A {}'
        Set-Content (Join-Path $proyecto 'Web.config') -Value '<configuration />'
        Set-Content (Join-Path $repo '.gitignore') -Value "bin/`nobj/"

        & git -C $repo init -q
        & git -C $repo config user.email 'test@economitza.com'
        & git -C $repo config user.name 'Test'
        & git -C $repo add -A
        & git -C $repo commit -q -m 'base'
        $base = ("$(& git -C $repo rev-parse HEAD)").Trim()
        $rama = ("$(& git -C $repo rev-parse --abbrev-ref HEAD)").Trim()

        # El "site publicado": el arbol del proyecto mas su sello
        New-Item -ItemType Directory -Force -Path $site | Out-Null
        Copy-Item (Join-Path $proyecto '*') $site -Recurse -Force
        [pscustomobject]@{
            branch = $rama; commit = $base.Substring(0, 9); commitFull = $base
            publishDate = (Get-Date).ToString('o'); environment = 'wt-hotfix-test'
        } | ConvertTo-Json | Set-Content (Join-Path $site 'deploy-info.json') -Encoding UTF8

        $envFile = Join-Path $Raiz '.publish-env.json'
        [pscustomobject]@{ name = 'wt-hotfix-test'; origin = $proyecto; destination = $site } |
            ConvertTo-Json | Set-Content $envFile -Encoding UTF8

        [pscustomobject]@{ repo = $repo; project = $proyecto; site = $site; envFile = $envFile; base = $base; branch = $rama }
    }
}

Describe 'Update-DeployInfoHotfix' {
    BeforeEach {
        $script:site = Join-Path $TestDrive ('sello-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:site | Out-Null
        [pscustomobject]@{ branch = 'main_SI-1'; commit = 'abc123456'; commitFull = 'abc123456def' } |
            ConvertTo-Json | Set-Content (Join-Path $script:site 'deploy-info.json') -Encoding UTF8
    }

    It 'marca el site como sucio y guarda lo aplicado' {
        Update-DeployInfoHotfix -Destination $script:site -Entry ([pscustomobject]@{ files = @('Views/A.cshtml'); views = 1 }) | Out-Null

        $info = Get-SiteDeployInfo -Destination $script:site
        $info.dirty | Should -BeTrue
        @($info.hotfix).Count | Should -Be 1
        $info.hotfix[0].files | Should -Be 'Views/A.cshtml'
    }

    It 'no toca branch ni commit: el sello no miente sobre lo que publico el swap' {
        Update-DeployInfoHotfix -Destination $script:site -Entry ([pscustomobject]@{ files = @('Views/A.cshtml') }) | Out-Null

        $info = Get-SiteDeployInfo -Destination $script:site
        $info.branch | Should -Be 'main_SI-1'
        $info.commitFull | Should -Be 'abc123456def'
    }

    It 'acumula hotfixes sucesivos' {
        Update-DeployInfoHotfix -Destination $script:site -Entry ([pscustomobject]@{ files = @('a') }) | Out-Null
        Update-DeployInfoHotfix -Destination $script:site -Entry ([pscustomobject]@{ files = @('b') }) | Out-Null

        @((Get-SiteDeployInfo -Destination $script:site).hotfix).Count | Should -Be 2
    }

    It 'al quitar el ultimo hotfix el site deja de estar sucio' {
        Update-DeployInfoHotfix -Destination $script:site -Entry ([pscustomobject]@{ files = @('a') }) | Out-Null
        Update-DeployInfoHotfix -Destination $script:site -RemoveLast | Out-Null

        $info = Get-SiteDeployInfo -Destination $script:site
        $info.dirty | Should -BeFalse
        @($info.hotfix).Count | Should -Be 0
    }
}

Describe 'Restore-HotfixFiles' {
    It 'repone lo sustituido y borra lo que el hotfix anadio' {
        $site = Join-Path $TestDrive 'site-restore'
        $backup = Join-Path $TestDrive 'backup-restore'
        New-Item -ItemType Directory -Force -Path (Join-Path $site 'Views') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $backup 'Views') | Out-Null
        Set-Content (Join-Path $backup 'Views\Vieja.cshtml') -Value 'original'
        Set-Content (Join-Path $site 'Views\Vieja.cshtml') -Value 'parcheada'
        Set-Content (Join-Path $site 'Views\Nueva.cshtml') -Value 'anadida'

        $n = Restore-HotfixFiles -Destination $site -BackupDir $backup -Files @(
            [pscustomobject]@{ rel = 'Views/Vieja.cshtml'; existed = $true },
            [pscustomobject]@{ rel = 'Views/Nueva.cshtml'; existed = $false })

        $n | Should -Be 2
        (Get-Content (Join-Path $site 'Views\Vieja.cshtml') -Raw).Trim() | Should -Be 'original'
        Test-Path (Join-Path $site 'Views\Nueva.cshtml') | Should -BeFalse
    }
}

Describe 'Invoke-Hotfix' {
    BeforeEach {
        $script:e = New-EntornoHotfix -Raiz (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
    }

    It 'en dry-run ensena el plan y no toca el site' {
        Set-Content (Join-Path $script:e.project 'Views\Index.cshtml') -Value 'v2'

        $r = Invoke-Hotfix -EnvironmentFile $script:e.envFile

        $r.status | Should -Be 'plan'
        $r.toCopy | Should -Be 'Views/Index.cshtml'
        (Get-Content (Join-Path $script:e.site 'Views\Index.cshtml') -Raw).Trim() | Should -Be 'v1'
    }

    It 'aplica la vista al site vivo y guarda copia de lo sustituido' {
        Set-Content (Join-Path $script:e.project 'Views\Index.cshtml') -Value 'v2'

        $r = Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup

        $r.status | Should -Be 'ok'
        (Get-Content (Join-Path $script:e.site 'Views\Index.cshtml') -Raw).Trim() | Should -Be 'v2'
        (Get-Content (Join-Path $r.backup 'Views\Index.cshtml') -Raw).Trim() | Should -Be 'v1'
        Test-Path (Join-Path $r.backup 'hotfix-manifest.json') | Should -BeTrue
    }

    It 'una vista sola no recicla el AppDomain' {
        Set-Content (Join-Path $script:e.project 'Views\Index.cshtml') -Value 'v2'
        (Invoke-Hotfix -EnvironmentFile $script:e.envFile).recycles | Should -BeFalse
    }

    It 'deja el sello marcado como sucio, con el parche declarado' {
        Set-Content (Join-Path $script:e.project 'Scripts\app.js') -Value 'js2'
        Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup | Out-Null

        $info = Get-SiteDeployInfo -Destination $script:e.site
        $info.dirty | Should -BeTrue
        $info.hotfix[0].files | Should -Be 'Scripts/app.js'
        $info.commitFull | Should -Be $script:e.base
    }

    It 'un cambio que exige compilar bloquea en vez de dejar el site a medias' {
        Set-Content (Join-Path $script:e.project 'Controllers.cs') -Value 'class A { int x; }'

        $r = Invoke-Hotfix -EnvironmentFile $script:e.envFile
        $r.status | Should -Be 'blocked'
        $r.blocked -join ' ' | Should -BeLike '*compilados*'
        { Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute } | Should -Throw '*no puede aplicarse entero*'
    }

    It 'la configuracion del entorno no viaja aunque haya cambiado' {
        Set-Content (Join-Path $script:e.project 'Web.config') -Value '<configuration><!-- otra --></configuration>'

        $r = Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup
        $r.status | Should -Be 'nochange'
        (Get-Content (Join-Path $script:e.site 'Web.config') -Raw) | Should -Not -BeLike '*otra*'
    }

    It 'si no hay nada distinto lo dice y no recicla nada' {
        (Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup).status | Should -Be 'nochange'
    }

    It 'descarta los ficheros identicos aunque git los de por cambiados' {
        # Tocar y devolver al contenido original: git lo ve modificado, el site no.
        Set-Content (Join-Path $script:e.project 'Views\Index.cshtml') -Value 'v2'
        & git -C $script:e.repo add -A
        & git -C $script:e.repo commit -q -m 'v2'
        Copy-Item (Join-Path $script:e.project 'Views\Index.cshtml') (Join-Path $script:e.site 'Views\Index.cshtml') -Force

        $r = Invoke-Hotfix -EnvironmentFile $script:e.envFile
        $r.unchanged | Should -Be 'Views/Index.cshtml'
        $r.toCopy | Should -BeNullOrEmpty
    }

    It 'no borra del site por defecto; con -IncludeRemovals si' {
        Remove-Item (Join-Path $script:e.project 'Scripts\app.js')

        $r = Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup
        Test-Path (Join-Path $script:e.site 'Scripts\app.js') | Should -BeTrue

        $r2 = Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup -IncludeRemovals
        $r2.removed | Should -Be 'Scripts/app.js'
        Test-Path (Join-Path $script:e.site 'Scripts\app.js') | Should -BeFalse
    }

    It 'se niega a parchear un site que sirve otra rama' {
        Set-Content (Join-Path $script:e.project 'Views\Index.cshtml') -Value 'v2'
        $info = Get-SiteDeployInfo -Destination $script:e.site
        $info.branch = 'main_OTRA'
        $info | ConvertTo-Json | Set-Content (Join-Path $script:e.site 'deploy-info.json') -Encoding UTF8

        { Invoke-Hotfix -EnvironmentFile $script:e.envFile } | Should -Throw '*no cambia de rama*'
    }

    It 'sin sello no hay hotfix: no se puede saber contra que calcular el delta' {
        Remove-Item (Join-Path $script:e.site 'deploy-info.json')
        { Invoke-Hotfix -EnvironmentFile $script:e.envFile } | Should -Throw '*no tiene sello*'
    }

    It 'dos hotfixes seguidos parten siempre del commit publicado' {
        Set-Content (Join-Path $script:e.project 'Views\Index.cshtml') -Value 'v2'
        Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup | Out-Null
        Set-Content (Join-Path $script:e.project 'Scripts\app.js') -Value 'js2'
        $r = Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup

        # La vista del primer hotfix ya esta identica en el site: se descarta sola.
        $r.applied | Should -Be 'Scripts/app.js'
        $r.unchanged | Should -Be 'Views/Index.cshtml'
        @((Get-SiteDeployInfo -Destination $script:e.site).hotfix).Count | Should -Be 2
    }
}

Describe 'Undo-Hotfix' {
    BeforeEach {
        $script:e = New-EntornoHotfix -Raiz (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
    }

    It 'repone el contenido anterior y limpia el sello' {
        Set-Content (Join-Path $script:e.project 'Views\Index.cshtml') -Value 'v2'
        Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup | Out-Null

        $r = Undo-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup

        $r.status | Should -Be 'ok'
        (Get-Content (Join-Path $script:e.site 'Views\Index.cshtml') -Raw).Trim() | Should -Be 'v1'
        (Get-SiteDeployInfo -Destination $script:e.site).dirty | Should -BeFalse
    }

    It 'borra del site los ficheros que el hotfix habia anadido' {
        Set-Content (Join-Path $script:e.project 'Views\Nueva.cshtml') -Value 'nueva'
        Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup | Out-Null
        Test-Path (Join-Path $script:e.site 'Views\Nueva.cshtml') | Should -BeTrue

        Undo-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup | Out-Null
        Test-Path (Join-Path $script:e.site 'Views\Nueva.cshtml') | Should -BeFalse
    }

    It 'en dry-run no toca nada' {
        Set-Content (Join-Path $script:e.project 'Views\Index.cshtml') -Value 'v2'
        Invoke-Hotfix -EnvironmentFile $script:e.envFile -Execute -SkipWarmup | Out-Null

        (Undo-Hotfix -EnvironmentFile $script:e.envFile).status | Should -Be 'plan'
        (Get-Content (Join-Path $script:e.site 'Views\Index.cshtml') -Raw).Trim() | Should -Be 'v2'
    }

    It 'sin hotfixes previos avisa en vez de fingir que ha hecho algo' {
        { Undo-Hotfix -EnvironmentFile $script:e.envFile -Execute } | Should -Throw '*No hay hotfixes*'
    }
}

Describe 'Get-HotfixBinDelta' {
    It 'trae solo los ensamblados distintos o nuevos' {
        $proj = Join-Path $TestDrive 'bd-proj'
        $site = Join-Path $TestDrive 'bd-site'
        New-Item -ItemType Directory -Force -Path (Join-Path $proj 'bin') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $site 'bin') | Out-Null
        Set-Content (Join-Path $proj 'bin\Igual.dll') -Value 'x'
        Set-Content (Join-Path $site 'bin\Igual.dll') -Value 'x'
        Set-Content (Join-Path $proj 'bin\Cambia.dll') -Value 'compilado'
        Set-Content (Join-Path $site 'bin\Cambia.dll') -Value 'viejo'
        Set-Content (Join-Path $proj 'bin\Nueva.dll') -Value 'nueva'
        Set-Content (Join-Path $proj 'bin\notas.txt') -Value 'no es un ensamblado'

        $d = Get-HotfixBinDelta -ProjectPath $proj -Destination $site

        @($d).Count | Should -Be 2
        @($d.rel) | Should -Contain 'bin/Cambia.dll'
        @($d.rel) | Should -Contain 'bin/Nueva.dll'
    }

    It 'conserva la ruta de los ensamblados satelite' {
        $proj = Join-Path $TestDrive 'bd-sat-proj'
        $site = Join-Path $TestDrive 'bd-sat-site'
        New-Item -ItemType Directory -Force -Path (Join-Path $proj 'bin\ca') | Out-Null
        New-Item -ItemType Directory -Force -Path $site | Out-Null
        Set-Content (Join-Path $proj 'bin\ca\Recursos.resources.dll') -Value 'ca'

        (Get-HotfixBinDelta -ProjectPath $proj -Destination $site).rel | Should -Be 'bin/ca/Recursos.resources.dll'
    }

    It 'sin bin en el proyecto no hay nada que llevar' {
        $proj = Join-Path $TestDrive 'bd-sinbin'
        New-Item -ItemType Directory -Force -Path $proj | Out-Null
        @(Get-HotfixBinDelta -ProjectPath $proj -Destination $TestDrive).Count | Should -Be 0
    }
}

Describe 'Invoke-Hotfix con -IncludeBuild' {
    BeforeEach {
        $script:e = New-EntornoHotfix -Raiz (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
    }

    It 'un cambio de codigo deja de bloquear' {
        Set-Content (Join-Path $script:e.project 'Controllers.cs') -Value 'class A { int x; }'

        $r = Invoke-Hotfix -EnvironmentFile $script:e.envFile -IncludeBuild
        $r.status | Should -Be 'plan'
        $r.blocked | Should -BeNullOrEmpty
    }

    It 'lleva al site los ensamblados que cambian y avisa del reciclado' {
        Set-Content (Join-Path $script:e.project 'Controllers.cs') -Value 'class A { int x; }'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:e.site 'bin') | Out-Null
        Set-Content (Join-Path $script:e.site 'bin\App.dll') -Value 'dll-viejo'
        Mock -ModuleName PublishToIIS Invoke-HotfixBuild {
            New-Item -ItemType Directory -Force -Path (Join-Path $ProjectPath 'bin') | Out-Null
            Set-Content (Join-Path $ProjectPath 'bin\App.dll') -Value 'dll-nuevo'
            [pscustomobject]@{ project = 'App.csproj'; elapsedMs = 1 }
        }

        $r = Invoke-Hotfix -EnvironmentFile $script:e.envFile -IncludeBuild -Execute -SkipWarmup

        $r.status | Should -Be 'ok'
        $r.recycles | Should -BeTrue
        $r.applied | Should -Contain 'bin/App.dll'
        (Get-Content (Join-Path $script:e.site 'bin\App.dll') -Raw).Trim() | Should -Be 'dll-nuevo'
        (Get-Content (Join-Path $r.backup 'bin\App.dll') -Raw).Trim() | Should -Be 'dll-viejo'
    }

    It 'si la compilacion falla el site se queda intacto' {
        Set-Content (Join-Path $script:e.project 'Views\Index.cshtml') -Value 'v2'
        Set-Content (Join-Path $script:e.project 'Controllers.cs') -Value 'class A { int x; }'
        Mock -ModuleName PublishToIIS Invoke-HotfixBuild { throw 'MSBuild fallo con codigo 1' }

        { Invoke-Hotfix -EnvironmentFile $script:e.envFile -IncludeBuild -Execute } | Should -Throw '*MSBuild*'
        (Get-Content (Join-Path $script:e.site 'Views\Index.cshtml') -Raw).Trim() | Should -Be 'v1'
        (Get-SiteDeployInfo -Destination $script:e.site).dirty | Should -BeNullOrEmpty
    }

    It 'compilar sin que cambie ningun ensamblado no toca el site' {
        Set-Content (Join-Path $script:e.project 'Controllers.cs') -Value 'class A { int x; }'
        Mock -ModuleName PublishToIIS Invoke-HotfixBuild { [pscustomobject]@{ project = 'x'; elapsedMs = 1 } }

        (Invoke-Hotfix -EnvironmentFile $script:e.envFile -IncludeBuild -Execute -SkipWarmup).status |
            Should -Be 'nochange'
    }

    It 'no paga el restore de NuGet si no cambia packages.config' {
        Set-Content (Join-Path $script:e.project 'Controllers.cs') -Value 'class A { int x; }'
        Mock -ModuleName PublishToIIS Invoke-HotfixBuild { [pscustomobject]@{ project = 'x'; elapsedMs = 1 } }

        Invoke-Hotfix -EnvironmentFile $script:e.envFile -IncludeBuild -Execute -SkipWarmup | Out-Null
        Should -Invoke -ModuleName PublishToIIS Invoke-HotfixBuild -Times 1 -Exactly -ParameterFilter { -not $Restore }
    }

    It 'restaura paquetes cuando el delta toca packages.config' {
        Set-Content (Join-Path $script:e.project 'packages.config') -Value '<packages />'
        Mock -ModuleName PublishToIIS Invoke-HotfixBuild { [pscustomobject]@{ project = 'x'; elapsedMs = 1 } }

        Invoke-Hotfix -EnvironmentFile $script:e.envFile -IncludeBuild -Execute -SkipWarmup | Out-Null
        Should -Invoke -ModuleName PublishToIIS Invoke-HotfixBuild -Times 1 -Exactly -ParameterFilter { $Restore }
    }
}

Describe 'Invoke-SiteWarmup' {
    It 'sin url no hay nada que calentar' {
        Invoke-SiteWarmup -Url '' | Should -BeNullOrEmpty
    }

    It 'una respuesta normal cuenta como calentado' {
        Mock -ModuleName PublishToIIS Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        $w = Invoke-SiteWarmup -Url 'https://esp.emkt.test'
        $w.status | Should -Be 'ok'
        $w.url | Should -Be 'https://esp.emkt.test'
    }

    It 'si el HTTPS se cae a nivel de conexion, reintenta por http' {
        # esp.emkt.test renegocia la conexion TLS y HttpWebRequest no lo soporta;
        # para levantar el AppDomain el esquema da igual.
        Mock -ModuleName PublishToIIS Invoke-WebRequest {
            if ($Uri -like 'https:*') { throw 'The underlying connection was closed.' }
            [pscustomobject]@{ StatusCode = 200 }
        }
        $w = Invoke-SiteWarmup -Url 'https://esp.emkt.test'
        $w.status | Should -Be 'ok'
        $w.url | Should -Be 'http://esp.emkt.test'
    }

    It 'si no responde por ninguna via lo dice, con el motivo' {
        Mock -ModuleName PublishToIIS Invoke-WebRequest { throw 'No such host is known' }
        $w = Invoke-SiteWarmup -Url 'https://no-existe.test'
        $w.status | Should -Be 'sin respuesta'
        $w.detail | Should -BeLike '*No such host*'
    }
}
