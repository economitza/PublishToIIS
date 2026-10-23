Import-Module -Name (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

Describe 'Parches del web.config por entorno y secretos del servidor' {
    BeforeAll {
        $script:dataDir = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_xdt_" + [Guid]::NewGuid())
        $script:repo = Join-Path $script:dataDir 'repo'
        New-Item -ItemType Directory -Path (Join-Path $script:repo 'tools\deploy\webconfig') -Force | Out-Null
        $script:hayXdt = $true
        try { Get-XdtAssemblyPath | Out-Null } catch { $script:hayXdt = $false }
        $script:secreto = 'valor-secreto-123&<"'
        $script:parche = Join-Path $script:repo 'tools\deploy\webconfig\devecoand1.xdt'
        Set-Content -Path $script:parche -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<!-- Un comentario que explica la sintaxis, {secreto:Nombre}, no pide ningún secreto. -->
<configuration xmlns:xdt="http://schemas.microsoft.com/XML-Document-Transform">
  <appSettings>
    <add key="RowsTraspasoEmisor" xdt:Transform="Remove" xdt:Locator="Match(key)" />
    <add key="RowsTraspasoEmisor" value="test" xdt:Transform="Insert" />
    <add key="RowsTraspasoSecreto" xdt:Transform="Remove" xdt:Locator="Match(key)" />
    <add key="RowsTraspasoSecreto" value="{secreto:RowsTraspasoSecreto}" xdt:Transform="Insert" />
  </appSettings>
</configuration>
'@
        function New-WebConfigDePrueba {
            $ruta = Join-Path $script:dataDir ("web_" + [Guid]::NewGuid() + '.config')
            Set-Content -Path $ruta -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="urlWeb" value="devecoand1.economitza.com" />
  </appSettings>
</configuration>
'@
            $ruta
        }
    }
    AfterAll { Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'guarda el secreto cifrado y de él solo dice el nombre' {
        $r = $script:secreto | Set-PublishSecret -Environment devecoand1 -Name RowsTraspasoSecreto -DataDir $script:dataDir
        $r.stored | Should -BeTrue
        $r.PSObject.Properties.Name | Should -Not -Contain 'value'
        (Get-Content (Join-Path $script:dataDir 'secretos\devecoand1.json') -Raw) | Should -Not -Match 'valor-secreto'
        Get-PublishSecretNames -Environment devecoand1 -DataDir $script:dataDir | Should -Be @('RowsTraspasoSecreto')
    }

    It 'no guarda secretos de producción ni de un entorno que no existe' {
        { 'x' | Set-PublishSecret -Environment prod -Name A -DataDir $script:dataDir } | Should -Throw '*no permitido*'
        { 'x' | Set-PublishSecret -Environment inventado -Name A -DataDir $script:dataDir } | Should -Throw '*no permitido*'
    }

    It 'aplica primero el parche del entorno y después el de la rama publicada, y ninguno si no los hay' {
        $config = Join-Path $script:dataDir 'config-webconfig'
        New-Item -ItemType Directory -Path $config -Force | Out-Null
        $delEntorno = Join-Path $config 'devecoand1.xdt'
        Copy-Item $script:parche $delEntorno
        Get-WebConfigPatch -RepoRoot $script:repo -Environment devecoand1 -ConfigDir $config | Should -Be @($delEntorno, $script:parche)
        Get-WebConfigPatch -RepoRoot $null -Environment devecoand1 -ConfigDir $config | Should -Be @($delEntorno)
        @(Get-WebConfigPatch -RepoRoot $script:repo -Environment devecoesp1 -ConfigDir $config).Count | Should -Be 0
        @(Get-WebConfigPatch -RepoRoot $script:repo -Environment '' -ConfigDir $config).Count | Should -Be 0
    }

    It 'aplica el parche con el secreto escapado, deja una sola clave al repetirlo y tapa el valor en lo que cuenta' {
        if (-not $script:hayXdt) { Set-ItResult -Skipped -Because 'sin Microsoft.Web.XmlTransform.dll en este equipo'; return }
        $web = New-WebConfigDePrueba
        $cambios = @(Invoke-WebConfigPatch -WebConfigPath $web -PatchPath $script:parche -Environment devecoand1 -DataDir $script:dataDir)
        $cambios -join "`n" | Should -Match '\+ <add key="RowsTraspasoEmisor" value="test" ?/>'
        $cambios -join "`n" | Should -Match '\+ <add key="RowsTraspasoSecreto" value="\*\*\*" ?/>'
        $cambios -join "`n" | Should -Not -Match 'valor-secreto'

        Invoke-WebConfigPatch -WebConfigPath $web -PatchPath $script:parche -Environment devecoand1 -DataDir $script:dataDir | Out-Null
        [xml]$x = Get-Content $web -Raw
        @($x.configuration.appSettings.add | Where-Object key -eq 'RowsTraspasoSecreto').Count | Should -Be 1
        ($x.configuration.appSettings.add | Where-Object key -eq 'RowsTraspasoSecreto').value | Should -Be $script:secreto
        ($x.configuration.appSettings.add | Where-Object key -eq 'urlWeb').value | Should -Be 'devecoand1.economitza.com'
    }

    It 'para si el parche pide un secreto que el entorno no tiene, sin tocar el web.config' {
        if (-not $script:hayXdt) { Set-ItResult -Skipped -Because 'sin Microsoft.Web.XmlTransform.dll en este equipo'; return }
        $web = New-WebConfigDePrueba
        $antes = Get-Content $web -Raw
        $otro = Join-Path $script:repo 'tools\deploy\webconfig\devecoesp1.xdt'
        Copy-Item $script:parche $otro
        { Invoke-WebConfigPatch -WebConfigPath $web -PatchPath $otro -Environment devecoesp1 -DataDir $script:dataDir } |
            Should -Throw '*Faltan secretos*RowsTraspasoSecreto*'
        Get-Content $web -Raw | Should -Be $antes
        Remove-Item $otro
    }

    It 'el endpoint guarda el secreto sin devolverlo, rechaza producción y lista solo los nombres' {
        $t = 'd' * 64
        $r = Invoke-DeployEndpointRequest -Method POST -Path '/api/secret' -Token $t -ExpectedToken $t -DataDir $script:dataDir `
            -Body '{"environment":"devecoand1","name":"OtroSecreto","value":"no-me-devuelvas"}'
        $r.status | Should -Be 200
        ($r.body | ConvertTo-Json -Compress) | Should -Not -Match 'no-me-devuelvas'
        (Invoke-DeployEndpointRequest -Method POST -Path '/api/secret' -Token $t -ExpectedToken $t -DataDir $script:dataDir `
            -Body '{"environment":"prod","name":"A","value":"b"}').status | Should -Be 400
        (Invoke-DeployEndpointRequest -Method POST -Path '/api/secret' -Token $t -ExpectedToken $t -DataDir $script:dataDir `
            -Body '{"environment":"devecoand1","name":"A"}').status | Should -Be 400
        $l = Invoke-DeployEndpointRequest -Method GET -Path '/api/secrets' -Query @{ environment = 'devecoand1' } -Token $t -ExpectedToken $t -DataDir $script:dataDir
        $l.status | Should -Be 200
        $l.body.names | Should -Contain 'OtroSecreto'
        (Invoke-DeployEndpointRequest -Method POST -Path '/api/secret' -Token 'malo' -ExpectedToken $t -DataDir $script:dataDir -Body '{}').status | Should -Be 401
    }
}
