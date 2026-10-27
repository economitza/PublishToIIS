Import-Module -Name (Join-Path $PSScriptRoot '..\PublishToIIS.psd1') -Force

# El swap del Publish con carpetas de verdad. Windows no deja renombrar una carpeta con un fichero
# abierto dentro (aunque se comparta para borrar), así que un handle abierto en Logs\ reproduce lo
# que hace el agente de CloudWatch en las API de test del 76.
Describe 'Swap del site (Invoke-SiteSwap)' {
    BeforeAll {
        function New-Fichero([string]$Ruta, [string]$Texto) {
            New-Item -ItemType Directory -Path (Split-Path $Ruta -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($Ruta, $Texto)
        }
        function Read-Fichero([string]$Ruta) { [IO.File]::ReadAllText($Ruta) }

        # Un site aspnetcore publicado y la release nueva al lado, como los deja Publish antes del swap.
        function New-Escenario {
            $root = Join-Path ([IO.Path]::GetTempPath()) ("p2iis_swap_" + [Guid]::NewGuid())
            $e = [pscustomobject]@{
                Root      = $root
                Site      = Join-Path $root 'wwwrootApi'
                Releasing = Join-Path $root 'wwwrootApi_releasing'
                Previous  = Join-Path $root 'wwwrootApi_previous'
            }
            New-Fichero (Join-Path $e.Site 'web.config') '<site-viejo/>'
            New-Fichero (Join-Path $e.Site 'appsettings.json') 'site-viejo'
            New-Fichero (Join-Path $e.Site 'appsettings.Production.json') 'site-viejo-prod'
            New-Fichero (Join-Path $e.Site 'bin\app.dll') 'dll-vieja'
            New-Fichero (Join-Path $e.Site 'solo-en-la-vieja.txt') 'sobra'
            New-Fichero (Join-Path $e.Site 'Logs\central-de-compres-integracio20261027.log') 'log de ayer'
            New-Fichero (Join-Path $e.Site 'Upload\pdf\pedido.pdf') 'pdf'
            # _releasing: el build con la configuración del site ya fusionada (Protect-SiteSettings).
            New-Fichero (Join-Path $e.Releasing 'web.config') '<final processPath="nuevo.exe"/>'
            New-Fichero (Join-Path $e.Releasing 'appsettings.json') 'final'
            New-Fichero (Join-Path $e.Releasing 'appsettings.Production.json') 'final-prod'
            New-Fichero (Join-Path $e.Releasing 'bin\app.dll') 'dll-nueva'
            New-Fichero (Join-Path $e.Releasing 'solo-en-la-nueva.txt') 'nuevo'
            New-Fichero (Join-Path $e.Releasing 'Views\web.config') '<vistas/>'
            New-Fichero (Join-Path $e.Releasing 'deploy-info.json') '{"commit":"abc"}'
            # Mismo tamaño y misma fecha de escritura que la vieja, contenido distinto: para robocopy es
            # «modificada» (cambia la fecha de cambio) y no la copia sin /IM.
            (Get-Item (Join-Path $e.Releasing 'bin\app.dll')).LastWriteTimeUtc = (Get-Item (Join-Path $e.Site 'bin\app.dll')).LastWriteTimeUtc
            $e
        }

        # Ficheros del site con su contenido, fuera de las carpetas de ejecución.
        function Get-Codigo([string]$Dir) {
            $base = (Get-Item -LiteralPath $Dir).FullName.TrimEnd('\')
            $h = [ordered]@{}
            Get-ChildItem -LiteralPath $base -Recurse -File | Sort-Object FullName | ForEach-Object {
                $rel = $_.FullName.Substring($base.Length + 1)
                if ($rel -notmatch '^(Logs|Upload)\\') { $h[$rel.ToLowerInvariant()] = [IO.File]::ReadAllText($_.FullName) }
            }
            ($h.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '|'
        }

        function Open-Bloqueo([string]$Ruta, [IO.FileShare]$Share) {
            [IO.File]::Open($Ruta, [IO.FileMode]::Open, [IO.FileAccess]::Read, $Share)
        }

        $script:rapido = @{ Kind = 'aspnetcore'; RenameDelaySeconds = 0; RobocopyRetries = 0; RobocopyWaitSeconds = 0 }
    }

    AfterEach {
        if ($script:e) { Remove-Item $script:e.Root -Recurse -Force -ErrorAction SilentlyContinue }
        $script:e = $null
    }

    It 'sin nada que lo retenga, renombra a la primera' {
        $script:e = New-Escenario
        $esperado = Get-Codigo $script:e.Releasing
        $r = InModuleScope PublishToIIS -Parameters @{ e = $script:e; p = $script:rapido } {
            Invoke-SiteSwap -Destination $e.Site -ReleasingDir $e.Releasing -PreviousDir $e.Previous @p 6>$null
        }
        $r.Mode | Should -Be 'rename'
        $r.Attempts | Should -Be 1
        Get-Codigo $script:e.Site | Should -Be $esperado
        Read-Fichero (Join-Path $script:e.Previous 'bin\app.dll') | Should -Be 'dll-vieja'
        Test-Path $script:e.Releasing | Should -BeFalse
    }

    It 'si renombrar el site falla por acceso denegado y luego se libera, renombra al reintentar' {
        $script:e = New-Escenario
        $esperado = Get-Codigo $script:e.Releasing
        $script:fallos = 0
        $site = $script:e.Site
        Mock -ModuleName PublishToIIS Rename-Item -ParameterFilter { $LiteralPath -eq $site } -MockWith {
            $script:fallos++
            if ($script:fallos -le 2) { throw [System.IO.IOException]::new("Access to the path '$LiteralPath' is denied.") }
            Microsoft.PowerShell.Management\Rename-Item -LiteralPath $LiteralPath -NewName $NewName -ErrorAction Stop
        }
        $r = InModuleScope PublishToIIS -Parameters @{ e = $script:e; p = $script:rapido } {
            Invoke-SiteSwap -Destination $e.Site -ReleasingDir $e.Releasing -PreviousDir $e.Previous -RenameAttempts 4 @p 6>$null
        }
        $r.Mode | Should -Be 'rename'
        $r.Attempts | Should -Be 3
        Get-Codigo $script:e.Site | Should -Be $esperado
        Read-Fichero (Join-Path $script:e.Previous 'Logs\central-de-compres-integracio20261027.log') | Should -Be 'log de ayer'
        Test-Path $script:e.Releasing | Should -BeFalse
    }

    It 'un error que no es de fichero en uso no se reintenta' {
        $script:e = New-Escenario
        $site = $script:e.Site
        Mock -ModuleName PublishToIIS Rename-Item -ParameterFilter { $LiteralPath -eq $site } -MockWith {
            throw [System.Management.Automation.ItemNotFoundException]::new("No existe '$LiteralPath'.")
        }
        {
            InModuleScope PublishToIIS -Parameters @{ e = $script:e; p = $script:rapido } {
                Invoke-SiteSwap -Destination $e.Site -ReleasingDir $e.Releasing -PreviousDir $e.Previous -RenameAttempts 4 @p 6>$null
            }
        } | Should -Throw '*No existe*'
        Should -Invoke -ModuleName PublishToIIS Rename-Item -ParameterFilter { $LiteralPath -eq $site } -Times 1 -Exactly
        Read-Fichero (Join-Path $script:e.Site 'bin\app.dll') | Should -Be 'dll-vieja'
    }

    It 'con un log abierto en Logs\ (el agente de CloudWatch), cambiazo por espejo: queda lo mismo que con el rename, con la configuración y Logs intactos' {
        # Referencia: el mismo escenario por rename.
        $script:e = New-Escenario
        InModuleScope PublishToIIS -Parameters @{ e = $script:e; p = $script:rapido } {
            [void](Invoke-SiteSwap -Destination $e.Site -ReleasingDir $e.Releasing -PreviousDir $e.Previous @p 6>$null)
        }
        $porRename = Get-Codigo $script:e.Site
        Remove-Item $script:e.Root -Recurse -Force

        $script:e = New-Escenario
        $log = Join-Path $script:e.Site 'Logs\central-de-compres-integracio20261027.log'
        $h = Open-Bloqueo $log ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            $r = InModuleScope PublishToIIS -Parameters @{ e = $script:e; p = $script:rapido } {
                Invoke-SiteSwap -Destination $e.Site -ReleasingDir $e.Releasing -PreviousDir $e.Previous -RenameAttempts 2 @p 6>$null
            }
        }
        finally { $h.Dispose() }

        $r.Mode | Should -Be 'espejo'
        $r.Attempts | Should -Be 2
        $r.Reason | Should -Not -BeNullOrEmpty
        # El site, idéntico al del rename: lo publicado con la configuración final de _releasing.
        Get-Codigo $script:e.Site | Should -Be $porRename
        Read-Fichero (Join-Path $script:e.Site 'web.config') | Should -Be '<final processPath="nuevo.exe"/>'
        Read-Fichero (Join-Path $script:e.Site 'appsettings.Production.json') | Should -Be 'final-prod'
        Read-Fichero (Join-Path $script:e.Site 'Views\web.config') | Should -Be '<vistas/>'
        Read-Fichero (Join-Path $script:e.Site 'bin\app.dll') | Should -Be 'dll-nueva'
        Test-Path (Join-Path $script:e.Site 'solo-en-la-vieja.txt') | Should -BeFalse
        # Las carpetas de ejecución, intactas.
        Read-Fichero $log | Should -Be 'log de ayer'
        Read-Fichero (Join-Path $script:e.Site 'Upload\pdf\pedido.pdf') | Should -Be 'pdf'
        # La versión anterior, copiada sin las carpetas de ejecución; _releasing, borrada.
        Read-Fichero (Join-Path $script:e.Previous 'bin\app.dll') | Should -Be 'dll-vieja'
        Read-Fichero (Join-Path $script:e.Previous 'web.config') | Should -Be '<site-viejo/>'
        Test-Path (Join-Path $script:e.Previous 'Logs') | Should -BeFalse
        Test-Path $script:e.Releasing | Should -BeFalse
    }

    It 'en el espejo, lo que el build trae dentro de una carpeta de ejecución llega sin borrar lo que había' {
        $script:e = New-Escenario
        New-Fichero (Join-Path $script:e.Releasing 'Upload\pdf\plantilla.txt') 'del build'
        $log = Join-Path $script:e.Site 'Logs\central-de-compres-integracio20261027.log'
        $h = Open-Bloqueo $log ([IO.FileShare]::ReadWrite)
        try {
            $r = InModuleScope PublishToIIS -Parameters @{ e = $script:e; p = $script:rapido } {
                Invoke-SiteSwap -Destination $e.Site -ReleasingDir $e.Releasing -PreviousDir $e.Previous -RenameAttempts 1 @p 6>$null
            }
        }
        finally { $h.Dispose() }
        $r.Mode | Should -Be 'espejo'
        Read-Fichero (Join-Path $script:e.Site 'Upload\pdf\plantilla.txt') | Should -Be 'del build'
        Read-Fichero (Join-Path $script:e.Site 'Upload\pdf\pedido.pdf') | Should -Be 'pdf'
    }

    It 'rollback del rename: si la carpeta nueva no se deja activar, la anterior vuelve a su sitio' {
        $script:e = New-Escenario
        $antes = Get-Codigo $script:e.Site
        $rel = $script:e.Releasing
        Mock -ModuleName PublishToIIS Rename-Item -ParameterFilter { $LiteralPath -eq $rel } -MockWith {
            throw [System.IO.IOException]::new("The process cannot access the file '$LiteralPath' because it is being used by another process.")
        }
        {
            InModuleScope PublishToIIS -Parameters @{ e = $script:e; p = $script:rapido } {
                Invoke-SiteSwap -Destination $e.Site -ReleasingDir $e.Releasing -PreviousDir $e.Previous -RenameAttempts 2 @p 6>$null
            }
        } | Should -Throw '*No se puede activar*'
        Get-Codigo $script:e.Site | Should -Be $antes
        Read-Fichero (Join-Path $script:e.Site 'Logs\central-de-compres-integracio20261027.log') | Should -Be 'log de ayer'
        Test-Path $script:e.Previous | Should -BeFalse
        Test-Path $script:e.Releasing | Should -BeTrue
    }

    It 'rollback del espejo: si el espejo no puede escribir un fichero retenido, el site vuelve entero a la versión anterior' {
        $script:e = New-Escenario
        $antes = Get-Codigo $script:e.Site
        $log = Join-Path $script:e.Site 'Logs\central-de-compres-integracio20261027.log'
        $hLog = Open-Bloqueo $log ([IO.FileShare]::ReadWrite)
        # Una DLL que el w3wp aún tiene cargada: se puede leer (la copia de previous) pero no sobrescribir.
        $hDll = Open-Bloqueo (Join-Path $script:e.Site 'bin\app.dll') ([IO.FileShare]::Read)
        try {
            {
                InModuleScope PublishToIIS -Parameters @{ e = $script:e; p = $script:rapido } {
                    Invoke-SiteSwap -Destination $e.Site -ReleasingDir $e.Releasing -PreviousDir $e.Previous -RenameAttempts 1 @p 6>$null
                }
            } | Should -Throw '*robocopy (espejo de la versión nueva)*'
        }
        finally { $hDll.Dispose(); $hLog.Dispose() }

        Get-Codigo $script:e.Site | Should -Be $antes
        Read-Fichero (Join-Path $script:e.Site 'web.config') | Should -Be '<site-viejo/>'
        Test-Path (Join-Path $script:e.Site 'solo-en-la-nueva.txt') | Should -BeFalse
        Read-Fichero $log | Should -Be 'log de ayer'
        Read-Fichero (Join-Path $script:e.Site 'Upload\pdf\pedido.pdf') | Should -Be 'pdf'
        Test-Path $script:e.Releasing | Should -BeTrue
    }

    It 'si no se puede guardar la versión actual, para antes de tocar el site' {
        $script:e = New-Escenario
        $antes = Get-Codigo $script:e.Site
        $log = Join-Path $script:e.Site 'Logs\central-de-compres-integracio20261027.log'
        $hLog = Open-Bloqueo $log ([IO.FileShare]::ReadWrite)
        # Un fichero que nadie más puede ni leer.
        $hDll = [IO.File]::Open((Join-Path $script:e.Site 'bin\app.dll'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            {
                InModuleScope PublishToIIS -Parameters @{ e = $script:e; p = $script:rapido } {
                    Invoke-SiteSwap -Destination $e.Site -ReleasingDir $e.Releasing -PreviousDir $e.Previous -RenameAttempts 1 @p 6>$null
                }
            } | Should -Throw '*el site no se ha tocado*'
        }
        finally { $hDll.Dispose(); $hLog.Dispose() }
        Get-Codigo $script:e.Site | Should -Be $antes
        Test-Path $script:e.Previous | Should -BeFalse
        Test-Path $script:e.Releasing | Should -BeTrue
    }

    It 'Invoke-Robocopy: de 0 a 7 es éxito y 8 o más lanza' {
        $script:e = New-Escenario
        InModuleScope PublishToIIS -Parameters @{ e = $script:e } {
            $destino = Join-Path $e.Root 'copia'
            Invoke-Robocopy -Source $e.Releasing -Destination $destino -What 'prueba' -Options @('/E', '/R:0', '/W:0') 6>$null | Should -Be 1
            Invoke-Robocopy -Source $e.Releasing -Destination $destino -What 'prueba' -Options @('/E', '/R:0', '/W:0') 6>$null | Should -Be 0
            { Invoke-Robocopy -Source (Join-Path $e.Root 'no-existe') -Destination $destino -What 'prueba' -Options @('/R:0', '/W:0') 6>$null } |
                Should -Throw '*robocopy (prueba) devolvió el código 16*'
        }
    }

    It 'Get-RobocopyRootExclusions: rutas completas de la raíz, en el origen y en el destino' {
        InModuleScope PublishToIIS {
            $o = Get-RobocopyRootExclusions -Roots @('E:\rel\', 'E:\site') -Files @('web.config') -Folders @('Logs')
            $o | Should -Be @('/XF', 'E:\rel\web.config', 'E:\site\web.config', '/XD', 'E:\rel\Logs', 'E:\site\Logs')
            Get-RobocopyRootExclusions -Roots @('E:\site') | Should -BeNullOrEmpty
            Get-SwapRuntimeFolders -Kind aspnetcore | Should -Be @('Logs', 'Upload')
            Get-SwapRuntimeFolders -Kind mvc | Should -Be @('Upload')
        }
    }

    It 'Get-RobocopyIncludeAll: /IM solo si el robocopy de la máquina lo conoce' {
        InModuleScope PublishToIIS {
            $antes = $script:RobocopyHasIM
            try {
                $script:RobocopyHasIM = $null
                $esperado = if (((& robocopy /?) -join "`n") -match '(?m)^\s*/IM\s+::') { @('/IS', '/IT', '/IM') } else { @('/IS', '/IT') }
                Get-RobocopyIncludeAll | Should -Be $esperado
                $script:RobocopyHasIM = $false
                Get-RobocopyIncludeAll | Should -Be @('/IS', '/IT')
            }
            finally { $script:RobocopyHasIM = $antes }
        }
    }
}
