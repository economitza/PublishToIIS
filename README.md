# PublishToIIS

Pequeño módulo PowerShell para publicar proyectos .NET a IIS con un swap seguro y carga de configuración centralizada por entorno.

Uso rápido:

- Cargar el módulo (desde la raíz del repo):

  Import-Module .\PublishToIIS.psd1

- Obtener configuración para el entorno activo:

  $cfg = Get-PublishConfig -Environment 'dev'

- Publicar (uso simple):

  Publish -ProjectPath $cfg.origin -Destination $cfg.destination -Configuration Release

- web.config: por defecto se PRESERVA el del servidor (el del repo se descarta).
  Para publicar el web.config del repo (p. ej. cuando la release incluye cambios
  de configuracion como customErrors):

  Publish ... -OverrideWebconfig

  Con -OverrideWebconfig el web.config del servidor queda guardado al lado como
  `web.config.previous` para poder comparar o restaurar.

- Sello de versión: cada Publish escribe `deploy-info.json` (rama, commit, fechas,
  entorno, quién publica) en la raíz del site — consultable en `GET /deploy-info.json`.
  También invocable a mano: `New-DeployInfo -ProjectPath <workingCopy> -OutputDir <dir> -Environment <env>`

- Publish sin privilegios (tarea 'Publish Local'). El único paso que necesita
  elevación es registrar la tarea, UNA vez por máquina:

      Register-PublishTask              # equipo de desarrollo
      Register-PublishTask -Unattended  # servidor

  (`Register-PublishTask` es el envoltorio del script `tools\Register-PublishLocalTask.ps1`;
  localiza el repo solo, sin que haya que saber la ruta.)

  `-Unattended` registra la tarea con LogonType **S4U**: se ejecuta aunque nadie
  tenga sesión iniciada (imprescindible si la llamada llega de fuera) y sin
  guardar contraseña. Sin él, la tarea solo corre con la sesión del usuario
  abierta, que es lo que interesa en un portátil.

  A partir de ahí, cada publicación se pide desde una consola **normal**:

      Request-Publish -Environment devecoand1 -Branch main_deploy-20260730 -Execute

  `Request-Publish` es exactamente la llamada que hará el job de CI o el
  dashboard: escribe la orden, dispara la tarea y espera el resultado. Todo el
  trabajo con privilegios (checkout, MSBuild, parada del app pool y swap) lo hace
  la tarea. Opciones: `-NoWait` (dispara y vuelve), `-TimeoutSeconds`,
  `-OverrideWebconfig`, `-TaskName`.

  Mientras publica, `Request-Publish` va volcando el log de la tarea en tu
  consola (prefijado con `|`): la tarea corre en su propio proceso y su salida va
  al transcript, no a tu terminal, asi que sin esto la consola se queda muda
  durante todo el MSBuild y parece colgada. Con `-Quiet` se calla y solo devuelve
  el resultado.

- Disparo REMOTO (por HTTP, desde otra maquina). Un endpoint que corre en el
  servidor destino, escucha solo en loopback y se expone por un site de IIS con
  reverse proxy (hostname + TLS). Es la misma mitad sin privilegios del flujo:
  escribe la orden y dispara 'Publish Local'. Montaje completo del servidor en
  `docs/deploy-endpoint.md`. Alta (elevado, una vez):

      .\tools\Register-DeployEndpointTask.ps1 -Port 8770

  y desde el cliente:

      $env:PUBLISHTOIIS_API_TOKEN = '<token del servidor>'
      Request-RemotePublish -Url https://deployments-76.economitza.com `
          -Environment devecoesp1 -Branch main_deploy-20260901 -Execute

  Piezas sueltas, por si se quiere disparar a mano o desde otro lenguaje:
  `Write-PublishOrder` deja `%ProgramData%\PublishToIIS\publish-order.json`
  (`{"environment":"...","branch":"...","execute":true}`), `schtasks /run /tn
  "Publish Local"` la dispara y `Wait-PublishResult` espera el desenlace. La
  tarea deja `publish-order.log` (transcript) y `publish-order.result.json`
  (`status` ok/error, mensaje, tiempos); la orden se consume (se renombra a
  `.consumed`) para que un /run accidental no re-publique. Sin `execute:true` la
  orden es dry-run.

  *Gotcha:* el `result.json` lo escribe la tarea **elevada** y, con la ACL por
  defecto de `%ProgramData%`, quien la dispara sin privilegios no puede borrarlo
  — se comía el resultado de la ejecución anterior. Por eso cada orden lleva un
  `runId` que la tarea devuelve en el resultado y `Wait-PublishResult` exige que
  coincida (`-RunId`). El registro además da permiso de Modify sobre la carpeta.

- Nada de rutas: `Get-PublishToIISRepo` localiza la copia de trabajo git por
  `-RepoPath`, por la variable `PUBLISHTOIIS_REPO` que deja `Install.ps1` o, si el
  módulo se importó desde el propio repo, por su carpeta. `Update-PublishToIIS` y
  `Register-PublishTask` la usan. *Ojo al arranque en una máquina nueva:* hasta
  que no se ejecuta `Install.ps1` UNA vez desde el repo, `PUBLISHTOIIS_REPO` no
  existe y un `Import-Module PublishToIIS` a secas carga la copia instalada, que
  puede ser vieja — comprobable con `(Get-Module PublishToIIS).Path`.

- **Encoding: los `.ps1`/`.psm1` con acentos van en UTF-8 CON BOM.** Windows
  PowerShell 5.1 lee un fichero sin BOM como ANSI y los acentos salen como
  mojibake, tanto en pantalla como en cualquier texto que el script componga; y
  5.1 es quien ejecuta `Install.ps1` y el registro de la tarea. Hay dos pruebas
  en `tests/` que fallan si aparece un fichero sin BOM o con mojibake ya escrito.

Estructura relevante:

- `src/` : implementación del módulo
- `tools/` : runner y registrador de la tarea elevada 'Publish Local'
- `config/environments.json` : fichero central con `origin` y `destination` por entorno
- `config/config.ps1` : loader `Get-PublishConfig`
- `tests/` : pruebas Pester
- `build/pack.ps1` : empaquetador simple

Integración en solución .NET Framework:

- Opción simple: añadir la carpeta del repo (o `src`/`config`) como `Existing Item` en la solución y marcar scripts a copiar al output (`Copy to Output Directory`).
- Opción escalable: generar un `.nupkg` y referenciarlo desde la solución CI/CD.
