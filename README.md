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
  trabajo con privilegios (checkout, restore de NuGet, MSBuild, parada del app pool y swap) lo hace
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

- Aprovisionamiento desde plantilla: si la entrada del entorno declara
  `templateSite` (un site IIS del mismo servidor), el primer publish crea lo que
  falte —carpeta, app pool y site llamados como el entorno, bindings 80/443 para
  el host de `siteUrl` con el certificado de la plantilla, `Web.config` y
  `connections.config` sembrados desde ella— y con `databaseMap`
  (`{"CCEspana": "CCEspana_esp3"}`) apunta las cadenas sembradas a su propia
  base de datos. Idempotente: en los siguientes publish no toca nada. Es
  `Initialize-IisSite`, la misma función que usa `tools\New-LocalIisSite.ps1`
  para los sites locales. Sin `templateSite`, un destino inexistente falla como
  siempre: aprovisionar es una decisión declarada, no un efecto de una ruta mal
  escrita.

- Actualizar el publicador de un servidor SIN RDP: `Request-RemoteUpdate -Server
  deployments-76`. Encola una orden `kind=update` en la misma cola que los
  despliegues (nunca coincide con un publish), la tarea elevada hace `git pull`
  + reinstalación y reinicia el listener; el cliente espera el resultado y
  enseña el salto de versión (`Get-RemoteDeployVersion` lo consulta a secas).
  La primera vez que un servidor recibe una versión con `/api/update` hay que
  actualizarlo por RDP con `Update-PublishToIIS`; a partir de ahí, ya no.

- Versionado por push: los push de este repo van por `tools\Push-Release.ps1`,
  que **sube el `ModuleVersion` en +1 el tercer dígito** (patch), commitea
  `chore(release): vX.Y.Z` y pushea en un paso. `-Minor`/`-Major` suben ese nivel
  reiniciando los de abajo; `-DryRun` solo muestra el salto. Commitea tu trabajo
  primero y luego lanza el helper (sube tu trabajo y el bump juntos).

- Alta de un entorno sin editar el JSON a mano: `tools\Add-PublishEnvironment.ps1`
  pregunta los campos por consola (Name obligatorio; Origin/Destination/AppPool/
  SiteUrl/ServerName/EndpointUrl opcionales), inserta la entrada preservando el
  formato del fichero y, al confirmar, **commitea y pushea** a origin para que el
  entorno quede disponible en todas las maquinas con un `git pull` /
  `Update-PublishToIIS`. Con `EndpointUrl` el entorno se publica en remoto por el
  endpoint; sin el, en local. Acepta los campos por parametro (`-NonInteractive`)
  para scripting, y `-NoPush` para solo modificar el fichero local.

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

## Refrescar la BD de un entorno de test

`Request-RemoteDbRefresh -Server deployments-76 -Environment devecoesp1 -TestEmail it@economitza.com`
(o `Request-DbRefresh` en la propia máquina) copia a la BD del entorno los datos
de la réplica de producción y la sanitiza: todo el correo de negocio pasa a
`-TestEmail` y las contraseñas a la de test. Sin `-Execute` es un **dry-run** que
inventaría réplica y destino (valida conexión y credenciales) y deja el plan de
tablas en el log; `-ShowLog` lo trae al terminar. Con `-Execute` lo aplica.

El publicador no refresca nada por sí mismo: orquesta el
`tools\db-refresh\Sync-TestDatabase.ps1` del propio repo del site, que es quien
sabe de esquema, exclusiones y sanitización (y se niega a refrescar sin ella).
Lo que resuelve el publicador (`Resolve-DbRefreshPlan`):

- **Destino**: la `centralcompresConnectionString` del `Web.config` del site
  publicado (siguiendo `configSource`). Nunca se escribe a mano.
- **Script**: el del checkout de origen del entorno (el que se publica).
- **Credenciales de la réplica**: `tools\db-refresh\replica.connection.json` del
  checkout o, si no está, `%ProgramData%\PublishToIIS\replica.connection.json`.
  Fuera de git: se copian una vez a mano en cada servidor.
- **Sites a parar**: el del entorno y cualquier otro del mismo servidor cuyo
  `Web.config` apunte a la misma BD, porque el refresco trunca tablas por debajo
  de todos ellos. Se vuelven a arrancar aunque el refresco falle, y se calientan.

**Dos carriles.** El refresco tiene su propia cola (`dbqueue\`), su drenador
(«Publish DbRefresh Drainer») y su tarea elevada («Publish DbRefresh», con dos horas
de límite): un refresco no frena ningún deploy, y los refrescos van de uno en uno
entre ellos. **El dry-run no pasa por ninguna cola**: no para pools ni escribe en la
BD, así que se ejecuta al momento (en remoto, en un proceso aparte que lanza el
endpoint; su log en `/api/log?runId=...`). `Install.ps1` registra esas dos tareas
con la misma identidad que sus parejas del carril de publicación, así que llegan con
cualquier `Update-PublishToIIS`; mientras no existan, los refrescos siguen yendo por
la cola de las publicaciones. `Get-DeployQueue` enseña los dos carriles y
`/api/log?lane=dbrefresh` el transcript del refresco.

Lo que coordina los dos carriles:

- **Candado por BD** (`%ProgramData%\PublishToIIS\dbrefresh-locks\`, vigente mientras
  viva el PID del refresco): no entran dos refrescos de la misma BD, y una publicación
  de un site cuya BD se está refrescando hace el swap pero **deja el pool parado**; lo
  arranca el refresco al terminar, que quita el candado antes de arrancar los pools.
- **Copia fija de las herramientas**: el refresco no ejecuta el checkout compartido
  (una publicación puede cambiarlo de rama a mitad), sino `tools\db-refresh` y los
  `.sql` de su `config.json` extraídos del commit de HEAD con `git archive`. Si ese
  commit no trae la sanitización, no hay refresco.
- **Fallar rápido**: si la tarea no recoge la orden en un minuto (schtasks ignora el
  disparo de una tarea que aún está en marcha), se vuelve a disparar una vez y, si
  tampoco, la orden termina en error en vez de esperar al timeout.

Solo entornos de la lista blanca (nunca `prod`/`staging` ni ad hoc) y,
además, las guardas del script: servidor de destino en `allowedTargetServers` y
jamás la propia réplica. `-TestEmail` es obligatorio salvo que el entorno
declare `testEmail` en `environments.json`.

## Hotfix en caliente (iterar sin republicar)

`Publish` reconstruye el site entero y lo activa con un swap de carpetas: es lo
correcto para una entrega, pero cuesta minutos y una parada del app pool por cada
vuelta. Para afinar una vista, un js o un cálculo en un entorno de test está
`Invoke-Hotfix`, que aplica sobre el site VIVO solo lo que ha cambiado:

    Invoke-Hotfix -Environment dev-joaquim-local              # plan (dry-run)
    Invoke-Hotfix -Environment dev-joaquim-local -Execute     # aplicar
    Undo-Hotfix   -Environment dev-joaquim-local -Execute     # deshacer

El delta se calcula contra el commit que el site declara en su `deploy-info.json`
y, por defecto, contra el **árbol de trabajo** del origen: no hace falta commitear
cada prueba. Con `-Committed` se compara solo hasta HEAD.

Qué cuesta cada clase de fichero:

| Qué cambia | Qué pasa en IIS |
|---|---|
| `Content`, `Scripts`, imágenes | nada: la siguiente petición ya lo sirve |
| `Views\**\*.cshtml` | Razor recompila esa vista a demanda |
| `bin\*.dll`, `Global.asax` | ASP.NET **recicla el AppDomain** |

El reciclado no para el pool ni reinicia IIS, pero pierde el `sessionState`
InProc y la primera petición paga el JIT: por eso el nivel que exige compilar es
opt-in y hay un warm-up que se come ese arranque y lo mide.

    Invoke-Hotfix -Environment dev-joaquim-local -IncludeBuild -Execute

`-IncludeBuild` compila con `msbuild /t:Build` (incremental, sobre el `bin` del
proyecto), restaura paquetes solo si el delta toca `packages.config` y lleva al
site únicamente los ensamblados cuyo contenido difiere. La compilación va antes
de tocar el site: si MSBuild falla, el site se queda como estaba.

Cuenta con que `numRecompilesBeforeAppRestart` vale 15: a la decimosexta vista
recompilada sin republicar, ASP.NET recicla igualmente. El hotfix lleva la cuenta
y avisa al acercarse.

Lo que el hotfix **no** hace, a propósito:

- no toca la configuración del entorno (`Web.config`, `connections.config`,
  `log4net.config`), igual que `Publish`;
- no borra del site lo que desaparece del origen salvo con `-IncludeRemovals`;
- no toca el árbol de trabajo del origen: ni checkout, ni fetch, ni pull;
- no eleva: escribe con la cuenta actual, y lo comprueba antes de empezar;
- no aplica nada si hay ficheros que no sabe clasificar, en vez de dar por
  aplicado un parche incompleto.

Cada aplicación deja copia de lo sustituido en `<site>_hotfixes\<sello>\` con su
manifiesto, y si algo falla a mitad repone lo ya copiado. El sello del site queda
marcado `dirty` con la lista de ficheros: `branch` y `commit` siguen diciendo qué
dejó el último swap, así que **un site parcheado se reconoce leyendo
`deploy-info.json`**. El siguiente `Publish` barre el parche, porque activa una
carpeta nueva.

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

## Notas para agentes

- The "publicador" (PowerShell module to publish .NET apps to IIS with safe swap, used on test environments and similar) lives at `C:\Users\joaquimms\Documents\git\PublishToIIS`. You maintain it occasionally on request: Pester tests in `tests/`, work on branch `claude-mantaining`, commit-push directly. Key behavior: by default it PRESERVES the server's web.config; `-OverrideWebconfig` publishes the repo's one (server copy kept as `web.config.previous`). **Gotcha: `Import-Module PublishToIIS` carga una copia VIEJA (mayo, v0.0, sin `-EnvironmentFile`) que hay en `Documents\PowerShell\Modules\PublishToIIS`; importar SIEMPRE el del repo por ruta: `Import-Module C:\Users\joaquimms\Documents\git\PublishToIIS\PublishToIIS.psd1 -Force` (la tarea «Publish Local» ya ejecuta el del repo vía `tools\Run-PublishOrder.ps1`). Y `deploy-info.json` llega con BOM: `Invoke-RestMethod` lo parsea a vacío; leer `Content` y `TrimStart([char]0xFEFF)` antes de `ConvertFrom-Json`. El entorno `dev-joaquim-local` (esp.emkt.test) tiene como `origin` el WORKTREE BASE de Joaquim y hace `git checkout <rama>` ahí: NUNCA publicar con él una rama que no sea la suya — para publicar una rama propia en esp.emkt.test se usa un entorno ad hoc con el mismo `destination`/`appPool`/`siteUrl` y `origin` = el worktree efímero (hecho el 03/09 con `rebranding-experimental-esp`).** **Entornos ad hoc para worktrees efímeros (v0.4.7): los worktrees efímeros NO se dan de alta en `config\environments.json`** (la config central es solo para entornos estables) — se publica con `Request-Publish -EnvironmentFile <worktree>\.publish-env.json -Branch X -Execute`, donde el json tiene la forma de una entrada de environments.json más su `name` y vive en la raíz del worktree; la definición viaja dentro de la orden y la tarea elevada la valida (sin colisión con la config central, nunca prod/staging). **v0.5.0 (03/09, diseño acordado con Joaquim): (a) aprovisionamiento desde plantilla** — una entrada de `environments.json` con `templateSite` (site IIS del mismo servidor) hace que el primer `Publish` cree carpeta, app pool y site (llamados como el entorno), bindings 80/443 para el host de `siteUrl` con el certificado de la plantilla, y siembre `Web.config` + `connections.config` desde ella; `databaseMap` (`{"CCEspana":"CCEspana_esp3"}`) apunta las cadenas sembradas a su BD. Sin `templateSite`, un destino inexistente falla como siempre (aprovisionar es intención declarada, no efecto de una ruta mal escrita). Es `Initialize-IisSite`, la misma función que usa `tools\New-LocalIisSite.ps1`. **(b) `connections.config` del site se preserva en el swap** como el web.config (está gitignored en central-de-compres: antes cada publish arrastraba el del origen del 76 a todos los deveco → misma BD para todos). **(c) update remoto**: `Request-RemoteUpdate -Server deployments-76` (`POST /api/update`, orden `kind=update` por la misma cola FIFO que los publish; la tarea elevada hace `Update-PublishToIIS` y reinicia «Publish Endpoint»; `GET /api/version` / `Get-RemoteDeployVersion` dicen qué versión corre). **Gotcha de arranque: el 76 aún corre una versión sin `/api/update` — la primera actualización a 0.5.0 es por RDP** (`Update-PublishToIIS` + reiniciar la tarea «Publish Endpoint»); desde entonces, sin RDP. **Pendiente para devecoesp3** (entrada ya en environments.json con `templateSite: devecoesp1`): confirmar que el site IIS de devecoesp1 en el 76 se llama así (si no, corregir el campo), decidir su BD (sin `databaseMap` hereda la de devecoesp1) y el DNS lo crea Joaquim en AWS. `Import-PowerShellDataFile` NO existe en el PS 5.1 de esta máquina: la versión del manifiesto se lee por regex. **v0.7.0: `Request-Publish` ENCOLA en la cola FIFO en vez de escribir `publish-order.json`**, que era una ranura ÚNICA donde dos sesiones publicando a la vez se pisaban la orden — una se perdía en silencio y su llamador se quedaba esperando el resultado de la otra (pasó publicando `si-2558-esp1` mientras otra sesión publicaba en `economitza_espana`). Se invoca igual que siempre: **en local NO hace falta HTTP**, la cola es un directorio y el endpoint (`127.0.0.1:8770`) queda como la puerta para quien llama desde fuera. `-Direct` conserva el camino viejo y es el que usa el drenador (que YA es la cola) y el respaldo si la máquina no tiene la tarea drenadora. Los entornos ad hoc de worktree efímero viajan ya por las tres vías (`Add-DeployQueueItem -EnvironmentFile/-EnvironmentDef`, `environmentDef` en `POST /api/publish`, `Request-RemotePublish -EnvironmentFile`). **Gotcha al actualizar el módulo**: «Publish Local» y el drenador lo importan en cada ejecución y se enteran solos, pero «Publish Endpoint» es un proceso largo y hay que **reiniciar su tarea** para que la puerta HTTP cargue el código nuevo.
- **Refrescar la BD de un deveco* (PublishToIIS 0.8.0, 28/09/2026)**:
  `Request-RemoteDbRefresh -Server deployments-76 -Environment <env> -TestEmail it@economitza.com`
  es el dry-run (valida réplica y destino, `-ShowLog` trae el plan de tablas); `-Execute` lo aplica.
  El destino sale del `Web.config` del site y la lógica es la de `tools\db-refresh` del repo:
  el publicador solo la orquesta. **Desde la 0.9.0 el refresco tiene carril propio** (cola
  `dbqueue\`, tareas «Publish DbRefresh» y su drenador, registradas por `Install.ps1`): no
  bloquea deploys; el dry-run no pasa por ninguna cola; un candado por BD deja parado el pool
  de un site que se publique mientras se refresca su BD; y una orden que la tarea no recoge
  falla al minuto en vez de bloquear la cola (lo que pasó el 28/09: dos horas). **Medido el 28/09**: los `devecoesp*` NO tienen BD propia —
  `devecoesp1`, `devecoesp`, `devecoesp2` y `devecoesp4` apuntan todos a `CCEspana` en
  `172.31.0.244`, así que refrescar uno refresca los cuatro (los de Marc y Joan incluidos) y el
  refresco los para a todos. Ese servidor no está en `allowedTargetServers` del `config.json` de
  `db-refresh`: declararlo servidor de test es decisión de Joaquim, no se añade por iniciativa propia.
- **Hotfix en caliente (PublishToIIS 0.6.0, 19/09/2026)**: para ITERAR en un entorno de
  test no se republica — `Invoke-Hotfix -Environment <env> [-Execute]` copia sobre el site
  vivo solo el delta contra el commit de su `deploy-info.json` (dry-run por defecto; el
  delta sale del ÁRBOL DE TRABAJO, así que no obliga a commitear cada prueba). Vistas,
  CSS y JS no reciclan nada y tardan segundos; `-IncludeBuild` lleva también lo que exige
  compilar y eso SÍ recicla el AppDomain (sesiones InProc perdidas + warm-up, que el
  propio hotfix paga y mide). `Undo-Hotfix` repone la copia de `<site>_hotfixes\`.
  **Gotchas medidos el 19/09**: (a) el sello queda `dirty` con la lista de ficheros —
  antes de diagnosticar nada raro en un deveco, mirar si está parcheado; (b) un publish
  concurrente se lleva el parche por delante (el swap activa una carpeta nueva) y eso es
  lo correcto, no un fallo; (c) el warm-up de `esp.emkt.test` entra por **http**: ese site
  renegocia la conexión TLS y `HttpWebRequest` no lo soporta aunque `curl` sí.
- **Versión por push (para módulos versionados; estrenada en PublishToIIS):** cada push **incrementa en 1 el tercer dígito** (patch) de la versión — la versión es, de facto, un contador de push. Con salto de `-Minor`/`-Major` se sube ese nivel y se reinician los de abajo, y a partir de ahí se sigue sumando patch por push. En PublishToIIS lo hace `tools\Push-Release.ps1` (sube el `ModuleVersion` del `.psd1`, commitea `chore(release): vX.Y.Z` y pushea en un paso; `-Minor`/`-Major`/`-DryRun`): **los push de ese repo van por ese helper**. La versión vigente la dice el `ModuleVersion` del `.psd1` (0.4.6 el 02/09/2026). Gotcha tras un pull/push del módulo: «Publish Endpoint» (listener) y «Publish Dashboard» (pythonw) son procesos largos y siguen con el código viejo hasta reiniciar sus tareas (`Stop-/Start-ScheduledTask`); el drenador y «Publish Local» importan el módulo en cada ejecución y se actualizan solos. Lo mismo aplica al servidor 76 tras el pull.
