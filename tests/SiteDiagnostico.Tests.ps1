Import-Module -Name (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

Describe 'Diagnóstico del site: configuración con los secretos tapados' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
    }
    AfterEach { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'tapa claves y contraseñas del Web.config y deja el resto' {
        $cfg = Join-Path $script:tmp 'Web.config'
        Set-Content $cfg -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="UrlApiEconomitza" value="https://devecoesp1api.economitza.com" />
    <add key="AWSAccessKey" value="AKIAEJEMPLO" />
    <add key="AWSSecretKey" value="secreto-aws" />
  </appSettings>
  <connectionStrings>
    <add name="Default" connectionString="Server=172.31.0.244;Database=CCEspana;User Id=ccapp;Password=clave-bd;" />
  </connectionStrings>
  <system.net><mailSettings><smtp><network host="smtp.x" password="clave-smtp" /></smtp></mailSettings></system.net>
  <system.web><machineKey validationKey="ABCDEF" decryptionKey="012345" /></system.web>
  <runtime><assemblyBinding><dependentAssembly><assemblyIdentity name="X" publicKeyToken="31bf3856ad364e35" /></dependentAssembly></assemblyBinding></runtime>
</configuration>
'@
        $t = InModuleScope PublishToIIS -Parameters @{ p = $cfg } { Get-ConfigTextoProtegido -Path $p }
        foreach ($secreto in 'AKIAEJEMPLO', 'secreto-aws', 'clave-bd', 'clave-smtp', 'ABCDEF', '012345') { $t | Should -Not -Match $secreto }
        $t | Should -Match 'https://devecoesp1api\.economitza\.com'
        $t | Should -Match 'key="AWSSecretKey"'
        $t | Should -Match 'Server=172\.31\.0\.244;Database=CCEspana;User Id=ccapp;Password=\*\*\*;'
        $t | Should -Match 'publicKeyToken="31bf3856ad364e35"'
    }

    It 'tapa también lo comentado y los <setting> de applicationSettings' {
        # Una cadena de conexión comentada en el Web.config de devecoesp-audit salió con su contraseña.
        $cfg = Join-Path $script:tmp 'Web.config'
        Set-Content $cfg -Encoding UTF8 -Value @'
<configuration>
  <connectionStrings>
    <!--<add name="Viejo" connectionString="Data Source=172.31.0.209;Initial Catalog=X; User ID=CCEspana ;Password=fuga-uno" />-->
    <!-- <add key="AWSSecretKey" value="fuga-dos" /> -->
    <!-- no es XML: password="fuga-tres" y Server=x;Pwd=fuga-cuatro; -->
  </connectionStrings>
  <applicationSettings><X.Properties.Settings>
    <setting name="SmtpPassword" serializeAs="String"><value>fuga-cinco</value></setting>
    <setting name="UrlApi" serializeAs="String"><value>https://api</value></setting>
  </X.Properties.Settings></applicationSettings>
</configuration>
'@
        $t = InModuleScope PublishToIIS -Parameters @{ p = $cfg } { Get-ConfigTextoProtegido -Path $p }
        $t | Should -Not -Match 'fuga'
        $t | Should -Match 'User ID=CCEspana ;Password=\*\*\*'
        $t | Should -Match '<value>https://api</value>'
        { [xml]$t } | Should -Not -Throw
    }

    It 'tapa propiedades secretas y contraseñas en cadenas de un appsettings.json' {
        $cfg = Join-Path $script:tmp 'appsettings.json'
        Set-Content $cfg -Encoding UTF8 -Value '{ "ConnectionStrings": { "Default": "Server=x;Database=CCEspana;Password=clave-bd;" }, "AWS": { "AccessKey": "AK", "SecretKey": "SK", "Region": "eu-west-3" }, "Jwt": { "Key": "firma" } }'
        $t = InModuleScope PublishToIIS -Parameters @{ p = $cfg } { Get-ConfigTextoProtegido -Path $p }
        foreach ($secreto in 'clave-bd', '"AK"', '"SK"', 'firma') { $t | Should -Not -Match $secreto }
        $t | Should -Match '"Region": "eu-west-3"'
        $t | Should -Match 'Database=CCEspana;Password=\*\*\*;'
    }
}

Describe 'Protect-ProductionWebConfig: los tipos MIME del build llegan al web.config conservado' {
    # SI-2695: la app acepta fotos .webp y el Web.config del repo declara su tipo, pero el del servidor
    # se conserva al publicar y sin ese tipo IIS respondía 404 al pedirlas.
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
        $script:servidor = Join-Path $script:tmp 'target_web.config'
        $script:build = Join-Path $script:tmp 'releasing_web.config'
        Set-Content $script:build -Encoding UTF8 -Value '<configuration><appSettings><add key="UrlApiEconomitza" value="https://repo" /></appSettings><system.webServer><staticContent><remove fileExtension=".webp" /><mimeMap fileExtension=".webp" mimeType="image/webp" /><mimeMap fileExtension=".json" mimeType="application/json" /></staticContent></system.webServer></configuration>'
    }
    AfterEach { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'añade los que le faltan al servidor y conserva lo suyo' {
        Set-Content $script:servidor -Encoding UTF8 -Value '<configuration><appSettings><add key="UrlApiEconomitza" value="https://servidor" /></appSettings><system.webServer><staticContent><clientCache cacheControlMode="UseMaxAge" /><mimeMap fileExtension=".json" mimeType="text/json" /></staticContent></system.webServer></configuration>'
        Protect-ProductionWebConfig -TargetWebConfig $script:servidor -ReleasingWebConfig $script:build | Should -Be 'preserved'
        $x = [xml](Get-Content $script:build -Raw)
        $x.SelectSingleNode("//appSettings/add[@key='UrlApiEconomitza']").value | Should -Be 'https://servidor'
        $x.SelectSingleNode("//staticContent/mimeMap[@fileExtension='.webp']").mimeType | Should -Be 'image/webp'
        $x.SelectSingleNode("//staticContent/remove[@fileExtension='.webp']") | Should -Not -BeNullOrEmpty
        @($x.SelectNodes("//staticContent/mimeMap[@fileExtension='.json']")).Count | Should -Be 1
        $x.SelectSingleNode("//staticContent/mimeMap[@fileExtension='.json']").mimeType | Should -Be 'text/json'
        $x.SelectSingleNode('//staticContent/clientCache') | Should -Not -BeNullOrEmpty
    }

    It 'crea system.webServer y staticContent si el servidor no los tiene' {
        Set-Content $script:servidor -Encoding UTF8 -Value '<configuration><appSettings /></configuration>'
        Protect-ProductionWebConfig -TargetWebConfig $script:servidor -ReleasingWebConfig $script:build | Should -Be 'preserved'
        ([xml](Get-Content $script:build -Raw)).SelectSingleNode("/configuration/system.webServer/staticContent/mimeMap[@fileExtension='.webp']") | Should -Not -BeNullOrEmpty
    }
}

Describe 'Diagnóstico del site: rutas, ficheros y manifiesto' {
    BeforeEach {
        $script:site = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_site_" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:site 'bin'), (Join-Path $script:site 'Logs') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:site 'bin\a.dll'), 'binario')
        [IO.File]::WriteAllText((Join-Path $script:site 'Logs\x.log'), 'log')
        [IO.File]::WriteAllText((Join-Path $script:site 'deploy-info.json'), '{"commit":"abc1234"}')
        Set-Content (Join-Path $script:site 'Web.config') -Encoding UTF8 -Value '<configuration><appSettings><add key="UrlApiEconomitza" value="https://api" /><add key="AWSSecretKey" value="sk" /></appSettings></configuration>'
    }
    AfterEach { Remove-Item $script:site -Recurse -Force -ErrorAction SilentlyContinue }

    It 'no deja salir de la carpeta del site' {
        InModuleScope PublishToIIS -Parameters @{ s = $script:site } {
            { Resolve-SiteFile -Root $s -Relative '..\fuera.txt' } | Should -Throw '*no permitida*'
            { Resolve-SiteFile -Root $s -Relative 'bin/../../fuera.txt' } | Should -Throw '*no permitida*'
            { Resolve-SiteFile -Root $s -Relative 'C:\Windows\win.ini' } | Should -Throw '*no permitida*'
            Resolve-SiteFile -Root $s -Relative 'bin/a.dll' | Should -Be (Join-Path $s 'bin\a.dll')
        }
    }

    It 'lista los ficheros con su sha256 y deja fuera los logs y los sellos salvo con -Todo' {
        $esperado = (Get-FileHash (Join-Path $script:site 'bin\a.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
        $f = @(Get-SiteFileManifest -Root $script:site)
        $f.path | Should -Be @('bin/a.dll', 'Web.config')
        ($f | Where-Object path -eq 'bin/a.dll').sha256 | Should -Be $esperado
        @(Get-SiteFileManifest -Root $script:site -Todo).path | Should -Contain 'Logs/x.log'
        @(Get-SiteFileManifest -Root $script:site -Sub 'bin' -NoHash)[0].sha256 | Should -BeNullOrEmpty
    }

    It 'sella deploy-manifest.json sin incluirse a sí mismo' {
        New-DeployManifest -Dir $script:site | Should -Be 2
        $m = Get-Content (Join-Path $script:site 'deploy-manifest.json') -Raw | ConvertFrom-Json
        $m.count | Should -Be 2
        $m.files.path | Should -Not -Contain 'deploy-manifest.json'
        (New-DeployManifest -Dir $script:site) | Should -Be 2
    }

    Context 'rutas del endpoint' {
        BeforeEach {
            $script:dataDir = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_data_" + [Guid]::NewGuid())
            New-Item -ItemType Directory -Path $script:dataDir | Out-Null
            $global:p2iisSitePrueba = $script:site
            Mock -ModuleName PublishToIIS Get-AllowedEnvironments { 'devecoesp-audit' }
            Mock -ModuleName PublishToIIS Get-PublishConfig { [pscustomobject]@{ destination = $global:p2iisSitePrueba } }
            $script:llamar = {
                param($ruta, $query)
                Invoke-DeployEndpointRequest -Method GET -Path $ruta -Query $query -Token 't' -ExpectedToken 't' -DataDir $script:dataDir
            }
        }
        AfterEach {
            Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Variable p2iisSitePrueba -Scope Global -ErrorAction SilentlyContinue
        }

        It '/api/config da los appSettings con los secretos tapados y el deploy-info' {
            $r = & $script:llamar '/api/config' @{ environment = 'devecoesp-audit' }
            $r.status | Should -Be 200
            $r.body.appSettings['UrlApiEconomitza'] | Should -Be 'https://api'
            $r.body.appSettings['AWSSecretKey'] | Should -Be '***'
            $r.body.deployInfo.commit | Should -Be 'abc1234'
        }

        It '/api/config resume el Web.config efectivo (configSource incluido), no un Web_local.config de al lado' {
            Set-Content (Join-Path $script:site 'Web.config') -Encoding UTF8 -Value '<configuration><appSettings><add key="UrlApiEconomitza" value="https://devecoesp1api" /></appSettings><connectionStrings configSource="connections.config" /></configuration>'
            Set-Content (Join-Path $script:site 'connections.config') -Encoding UTF8 -Value '<connectionStrings><add name="Default" connectionString="Server=172.31.0.244;Database=CCEspana;Password=fuga;" /></connectionStrings>'
            Set-Content (Join-Path $script:site 'Web_local.config') -Encoding UTF8 -Value '<configuration><appSettings><add key="UrlApiEconomitza" value="https://otra" /></appSettings><connectionStrings><add name="Default" connectionString="Server=DESKTOP;Database=Vieja" /></connectionStrings></configuration>'
            $r = & $script:llamar '/api/config' @{ environment = 'devecoesp-audit' }
            $r.body.appSettings['UrlApiEconomitza'] | Should -Be 'https://devecoesp1api'
            $r.body.connectionStrings['Default'] | Should -Be 'Server=172.31.0.244;Database=CCEspana;Password=***;'
            $r.body.files.path | Should -Contain 'Web_local.config'
            ($r.body.files | ForEach-Object { $_.text }) -join '' | Should -Not -Match 'fuga'
        }

        It '/api/files lista y /api/file sirve un binario en base64 y la configuración tapada' {
            $r = & $script:llamar '/api/files' @{ environment = 'devecoesp-audit'; path = 'bin' }
            $r.status | Should -Be 200
            $r.body.files.path | Should -Be 'bin/a.dll'
            $b = & $script:llamar '/api/file' @{ environment = 'devecoesp-audit'; path = 'bin/a.dll' }
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b.body.base64)) | Should -Be 'binario'
            $c = & $script:llamar '/api/file' @{ environment = 'devecoesp-audit'; path = 'Web.config' }
            $c.body.masked | Should -BeTrue
            $c.body.text | Should -Not -Match '"sk"'
        }

        It 'rechaza un entorno no permitido, una ruta fuera del site y un fichero que no existe' {
            (& $script:llamar '/api/files' @{ environment = 'prod' }).status | Should -Be 400
            (& $script:llamar '/api/file' @{ environment = 'devecoesp-audit'; path = '..\x' }).status | Should -Be 400
            (& $script:llamar '/api/file' @{ environment = 'devecoesp-audit'; path = 'bin/no.dll' }).status | Should -Be 404
        }
    }
}
