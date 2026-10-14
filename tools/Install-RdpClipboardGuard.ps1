<#
.SYNOPSIS
    Evita que el portapapeles compartido del escritorio remoto se quede muerto en el servidor.

.DESCRIPTION
    El portapapeles entre el equipo local y la sesión de escritorio remoto lo mueve rdpclip.exe
    dentro de la sesión del servidor. Cuando se cuelga (típico tras una reconexión), copiar en un
    lado y pegar en el otro deja de funcionar sin ningún aviso. Se arregla reiniciándolo.

    Se lanza UNA vez por servidor, en una consola elevada. Deja:
      1) C:\ProgramData\RdpClipboardGuard\reiniciar.vbs: mata el rdpclip de la sesión de quien lo
         ejecuta y lo vuelve a arrancar, sin abrir ninguna ventana.
      2) La tarea «RDP - Reiniciar portapapeles»: lo ejecuta en la sesión de cada usuario al iniciar
         sesión y en cada reconexión remota, que es cuando suele romperse.
      3) Un acceso directo «Reiniciar portapapeles» en el escritorio de todos los usuarios, con el
         atajo Ctrl+Alt+V, para cuando se rompa a media sesión.
    Idempotente: relanzarlo reescribe las tres piezas.

.EXAMPLE
    .\tools\Install-RdpClipboardGuard.ps1
#>
[CmdletBinding()]
param(
    [string]$Dir = (Join-Path $env:ProgramData 'RdpClipboardGuard'),
    [string]$TaskName = 'RDP - Reiniciar portapapeles',
    [string]$Hotkey = 'CTRL+ALT+V'
)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Lánzalo en una consola elevada: registra una tarea para todos los usuarios y escribe en el escritorio público.' }

# 1) El reinicio, en VBScript para que no abra ninguna consola. Sin elevar, taskkill solo
#    alcanza los procesos del propio usuario: no toca el portapapeles de otras sesiones.
New-Item -ItemType Directory -Path $Dir -Force | Out-Null
$vbs = Join-Path $Dir 'reiniciar.vbs'
$contenido = @'
' Reinicia rdpclip.exe en la sesion de quien lo ejecuta (lo instala Install-RdpClipboardGuard.ps1).
Set sh = CreateObject("WScript.Shell")
sh.Run "taskkill.exe /f /im rdpclip.exe", 0, True
WScript.Sleep 500
sh.Run "rdpclip.exe", 0, False
'@
[IO.File]::WriteAllText($vbs, $contenido, [Text.Encoding]::ASCII)
Write-Host "[1/3] $vbs" -ForegroundColor Green

# 2) Tarea en la sesión de cada usuario: al iniciar sesión y en cada reconexión remota
$accion = New-ScheduledTaskAction -Execute "$env:windir\System32\wscript.exe" -Argument "//B //Nologo `"$vbs`""
$alIniciar = New-ScheduledTaskTrigger -AtLogOn
$alIniciar.Delay = 'PT10S'
$claseSesion = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger'
$alReconectar = New-CimInstance -CimClass $claseSesion -ClientOnly
$alReconectar.StateChange = 3   # TASK_SESSION_STATE_CHANGE_TYPE: RemoteConnect
$alReconectar.Delay = 'PT5S'
$alReconectar.Enabled = $true
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited   # BUILTIN\Users, en su propia sesión
$ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $accion -Trigger @($alIniciar, $alReconectar) `
    -Principal $principal -Settings $ajustes -Force | Out-Null
Write-Host "[2/3] Tarea '$TaskName' (al iniciar sesión y en cada reconexión remota)" -ForegroundColor Green

# 3) Acceso directo con atajo en el escritorio público
$lnk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Reiniciar portapapeles.lnk'
$ws = New-Object -ComObject WScript.Shell
$acceso = $ws.CreateShortcut($lnk)
$acceso.TargetPath = "$env:windir\System32\wscript.exe"
$acceso.Arguments = "//B //Nologo `"$vbs`""
$acceso.IconLocation = "$env:windir\System32\shell32.dll,238"
$acceso.Hotkey = $Hotkey
$acceso.Description = 'Reinicia el portapapeles compartido del escritorio remoto'
$acceso.Save()
Write-Host "[3/3] Acceso directo '$lnk' (atajo $Hotkey)" -ForegroundColor Green

# Y ahora mismo, por la tarea: sin elevar, para que solo toque el rdpclip de esta sesión
Start-ScheduledTask -TaskName $TaskName
Write-Host 'Portapapeles reiniciado en esta sesión. Prueba a copiar en tu equipo y pegar aquí.' -ForegroundColor Cyan
