# Changelog

Novedades reseñables de PublishToIIS. Formato basado en
[Keep a Changelog 1.0.0](https://keepachangelog.com/es-ES/1.0.0/); versionado
[SemVer](https://semver.org/lang/es/). Desde 0.4.0 la versión funciona como
**contador de push**: cada push sube el tercer dígito (patch) vía
`tools\Push-Release.ps1` (`-Minor`/`-Major` suben ese nivel y reinician los de abajo).

## [0.13.9] - 2026-10-21

### Added
- **`apiUrl` por entorno**: un e-market declara en `config\environments.json` la API que llama y cada
  publicación la fija en `UrlApiEconomitza` del web.config conservado. `devecoesp-audit` pasa a
  `devecoesp1api`; hasta ahora heredaba de su plantilla una API anterior a la 2.1.0.

## [0.13.2] - 2026-10-16

### Added
- **Entorno `deveco-experimental-and`** en `config\environments.json` (Andorra, plantilla
  `devecoand1`): la rama experimental de favoritos por centro deja de publicarse con un
  entorno ad hoc.

### Fixed
- **Publicar por rama no pierde commits locales**: si la rama local del origen lleva commits
  que origin no tiene (un worktree de trabajo sin pushear), antes de reponerla con
  `checkout -B` se guardan en `refs/publish-backup/<rama>/<fecha>` y se avisa de cómo
  recuperarlos. Antes se quedaban solo en el reflog y el árbol cambiaba a mitad de trabajo.

## [0.13.1] - 2026-10-16

### Fixed
- **El refresco de BD remoto completa la fase de IDENTITY**: la copia fija de las
  herramientas lleva también `CentralCompres/Models` (el `.dbml` y las entidades que
  `Repair-IdentityColumns.ps1` lee para saber qué claves genera la BD). Sin él el refresco
  terminaba con código 1 al final, tras cargar y sanear (visto en devecoesp1 el 16/10).

## [0.13.0] - 2026-10-16

### Added
- **Publicar un commit sin rama**: `Request-RemotePublish`/`Request-Publish -Commit <sha>`
  (o el SHA, de 7 a 40 caracteres hexadecimales, en `-Branch` o en el dashboard) hace
  checkout con HEAD desacoplado; basta con que el commit esté en alguna rama de origin. El
  `deploy-info.json` lleva `detached`; si el commit no es la punta de ninguna rama de
  origin, `branch` va vacía y `containedIn` dice la rama más cercana y la distancia
  (`main~312`).
- **El resultado de una build fallida trae sus errores**: hasta cinco líneas `error` de
  MSBuild o dotnet en el mensaje, en vez de «MSBuild failed with exit code 1» a secas, y
  la salida de la build queda en el transcript (`GET /api/log`).

### Fixed
- **Publicar un commit viejo después de main en el clon compartido del servidor**: el
  IncrementalClean de MSBuild borraba de `bin\` las DLL que ese commit lleva versionadas
  (MvcCheckBoxList.dll) porque las había escrito la build anterior, y las vistas no
  compilaban. Antes de compilar se borra la lista de esa build
  (`obj\*\*.FileListAbsolute.txt`), y el checkout repone los ficheros versionados que falten.

## [0.12.6] - 2026-10-14

### Added
- **Los entornos aspnetcore sirven `/deploy-info.json` desde IIS**: el publish añade al
  `web.config` una `<location>` que deja ese fichero al `StaticFileModule`. Antes solo lo
  enseñaban las ramas de la API que ya traen su `DeployInfoController` (el de `main`), y
  una rama más antigua daba 404 aunque el sello estuviera en el site.
- `Install-AspNetCorePrereqs.ps1` clona por HTTPS con el token de GitLab (cabecera en la
  config de ese clon, protegida) y lo lee del portapapeles; `Install-RdpClipboardGuard.ps1 -Diagnose`.

## [0.12.1] - 2026-10-14

### Added
- `tools\Install-RdpClipboardGuard.ps1`: el portapapeles compartido del escritorio remoto
  deja de quedarse muerto en el servidor. Reinicia `rdpclip.exe` en la sesión de cada
  usuario al iniciar sesión y en cada reconexión remota, y deja en el escritorio un
  acceso directo «Reiniciar portapapeles» (Ctrl+Alt+V) para cuando falle a media sesión.

## [0.12.0] - 2026-10-14

### Added
- **Entornos `kind: aspnetcore` (la API)**: el mismo publicador, la misma cola y la
  misma puerta remota publican también proyectos ASP.NET Core. Compila con
  `dotnet publish`; en el swap se conservan `web.config` y los `appsettings*.json`
  del site (del `<aspNetCore>`, `processPath`, `arguments` y `hostingModel` vienen
  del build) y `Logs\` pasa de una publicación a la siguiente. Al aprovisionar desde
  `templateSite` se siembran el `web.config` y los `appsettings*.json` de la
  plantilla, `databaseMap` se aplica a sus `ConnectionStrings` y `seedAppSettings`
  se fusiona en el `appsettings.<ASPNETCORE_ENVIRONMENT>.json`. El pool queda en
  AlwaysRunning y sin apagado por inactividad, y el site con precarga. Primer
  entorno: `deveco-api-marc`.
- `templateSite` acepta también el host que sirve la plantilla
  (`devecoesp1api.economitza.com`), además del nombre del site en IIS.
- `tools\Install-AspNetCorePrereqs.ps1`: prepara un servidor una vez (SDK de .NET,
  clon de la API y `NuGet.Config` con el registro de GitLab donde está EconomitzaDB).

### Changed
- `Invoke-Hotfix` rechaza los entornos que no son `mvc`: copia vistas y `bin` del
  e-market y no sabe nada de una API.

## [0.11.0] - 2026-10-14

### Added
- **Cliente remoto desde Linux** (pwsh 7): `Request-RemotePublish`,
  `Request-RemoteDbRefresh`, `Request-RemoteUpdate` y `Get-RemoteDeployVersion`
  funcionan desde un equipo Linux. Sin `ProgramData`, el registro de tokens va a
  `$XDG_DATA_HOME/PublishToIIS` (o `~/.local/share/PublishToIIS`), y sin
  `COMPUTERNAME`/`USERNAME` el `requestedBy` sale de la máquina y el usuario del
  proceso. Publicar en local sigue siendo solo Windows.

## [0.10.0] - 2026-10-07

### Fixed
- **El web.config preservado lleva el `<runtime>` del build**: las redirecciones de
  ensamblados y los ensamblados de compilacion de las vistas dependen de las DLL que
  se publican, no del entorno. Conservarlas del servidor dejaba el site con un
  `FileLoadException` (System.Memory 4.0.1.1 al exportar a Excel) en cuanto el build
  subia de version una DLL. El resto del web.config del servidor se sigue conservando.

## [0.9.0] - 2026-09-28

### Added
- **Carril propio para los refrescos de BD**: cola `dbqueue\`, drenador «Publish
  DbRefresh Drainer» y tarea elevada «Publish DbRefresh» (dos horas de límite), que
  `Install.ps1` registra con la identidad de sus parejas del carril de publicación. Un
  refresco ya no bloquea ningún deploy.
- **El dry-run de un refresco no espera turno**: no pasa por ninguna cola ni tarea
  elevada; en remoto lo lanza el endpoint en un proceso aparte (`/api/log?runId=`).
- **Candado por BD**: no entran dos refrescos de la misma BD, y una publicación de un
  site cuya BD se está refrescando deja su pool parado para que lo arranque el refresco.
- **Copia fija de las herramientas de refresco** sacada del commit con `git archive`:
  una publicación que cambie de rama el checkout a mitad ya no puede cambiarle la
  sanitización.

### Fixed
- **Una orden que la tarea no recoge ya no bloquea la cola hasta el timeout**: al minuto
  se vuelve a disparar la tarea y, si tampoco la recoge, la orden termina en error. El
  28/09 un refresco quedó así dos horas con la cola del 76 bloqueada detrás.

## [0.8.0] - 2026-09-28

### Added
- **Refresco de la BD de un entorno de test desde el publicador** (`kind=dbrefresh`):
  `Request-RemoteDbRefresh` / `Request-DbRefresh` (dry-run por defecto, `-Execute`
  para aplicar) llaman al `tools\db-refresh\Sync-TestDatabase.ps1` del checkout del
  entorno contra la BD que leen del `Web.config` del site: sincroniza desde la
  réplica y sanitiza correos y contraseñas. Va por la misma cola FIFO que las
  publicaciones y por `POST /api/dbrefresh`, y para durante el refresco los app
  pools de todos los sites del servidor que comparten esa BD.

### Changed
- La espera de una orden encolada (`Wait-DeployQueueItem`) y la de una orden
  remota (`Wait-RemoteResult`) salen a funciones propias, compartidas por
  publicaciones y refrescos.

## [0.7.0] - 2026-09-20

### Changed
- **`Request-Publish` encola en la cola FIFO en vez de escribir la ranura única.**
  Hasta ahora dejaba la orden en `publish-order.json`, que es **un solo fichero**:
  dos llamadas casi a la vez en la misma máquina —dos sesiones publicando en
  sitios distintos— se pisaban, la primera orden no llegaba a ejecutarse y quien
  la lanzó se quedaba esperando un resultado que era de la otra (visto el
  20/09/2026 publicando `si-2558-esp1` mientras otra sesión publicaba en
  `economitza_espana`). Ahora la orden va a la misma cola que alimenta el
  endpoint HTTP y la despacha el drenador, que procesa de una en una.

  **En local no hace falta HTTP**: la cola es un directorio, así que se escribe
  en ella directamente y el endpoint queda como lo que es, la puerta para quien
  llama desde fuera. Quien publica sigue llamando a `Request-Publish` igual.

  `-Direct` mantiene el camino de siempre y lo usa el drenador, que YA es la
  cola (sin eso se encolaría a sí mismo). Si la máquina no tiene registrada la
  tarea drenadora, `Request-Publish` cae solo al camino directo.

### Added
- **Entornos ad hoc (worktrees efímeros) por la cola y por HTTP.** Hasta ahora
  su definición solo viajaba por el camino local: `Add-DeployQueueItem` acepta
  `-EnvironmentFile`/`-EnvironmentDef` y la guarda en el item,
  `POST /api/publish` admite `environmentDef` en el cuerpo y
  `Request-RemotePublish` estrena `-EnvironmentFile`. Así un worktree
  efímero se publica por cualquiera de las tres vías sin darlo de alta en
  `environments.json`, que es justo lo que la regla pide no hacer.
- `Read-AdHocEnvironment -Definition` valida una definición ya leída, sin
  fichero: las guardas (`name`/`origin`/`destination` obligatorios, nunca
  prod/staging, sin colisionar con la config central) se escriben una vez y
  valen igual para la puerta HTTP.
## [0.6.0] - 2026-09-19

### Added
- **Hotfix en caliente (`Invoke-Hotfix`).** Alternativa a `Publish` para iterar
  en un entorno de test: en vez de reconstruir el site entero y activarlo con el
  swap, calcula qué ha cambiado desde el commit que el site declara en su
  `deploy-info.json` y copia encima solo eso. Sin MSBuild completo, sin carpeta
  de publicación nueva, sin parar el app pool y sin swap. Dry-run por defecto,
  como `Invoke-DeployOrder`; `-Execute` aplica.

  Lo que cuesta cada clase de fichero, que es lo que decide si compensa:
  estáticos y vistas los sirve la siguiente petición sin más; tocar `bin\` o
  `Global.asax` hace que ASP.NET **recicle el AppDomain** —no se para el pool ni
  se reinicia IIS, pero el `sessionState` InProc se pierde y la primera petición
  paga el JIT—, y por eso el nivel que exige compilar es opt-in (`-IncludeBuild`)
  y hay un warm-up que se come ese arranque y lo mide.

  Garantías: copia de seguridad con manifiesto en `<site>_hotfixes\<sello>\` y
  reposición automática si algo falla a mitad; el sello queda marcado `dirty`
  con la lista de ficheros aplicados (`branch`/`commit` siguen diciendo qué dejó
  el swap: el sello no miente sobre lo publicado, declara el parche);
  comprobación de escritura antes de tocar nada; se niega si el site sirve otra
  rama o si el origen ha divergido; los ficheros idénticos se descartan
  comparando contenido, porque copiar un DLL igual reciclaría el AppDomain para
  nada; y no toca el árbol de trabajo del origen —ni checkout ni fetch—, así que
  es seguro contra el worktree base. Lo que no sabe clasificar bloquea, en vez
  de dar por aplicado un parche incompleto.

  El siguiente `Publish` normal barre el parche, porque el swap activa una
  carpeta nueva.
- **`-IncludeBuild`**: sube al hotfix los cambios que solo llegan compilados. Usa
  `msbuild /t:Build` (incremental, sobre el `bin` del propio proyecto) en vez del
  `DeployOnBuild` + `PublishUrl` de `Publish`, hace `nuget restore` solo si el
  delta toca `packages.config`, y lleva al site únicamente los ensamblados cuyo
  contenido difiere. La compilación va antes de tocar el site: un MSBuild fallido
  lo deja exactamente como estaba.
- **`Undo-Hotfix`**: repone la copia de seguridad (borrando lo que el hotfix
  añadió) y limpia la entrada del sello.
- Funciones nuevas exportadas: `Invoke-Hotfix`, `Undo-Hotfix`, `Invoke-HotfixBuild`,
  `Get-HotfixBinDelta`, `Get-HotfixDelta`, `Resolve-HotfixPlan`,
  `Get-SiteDeployInfo`, `Get-HotfixTarget`, `Update-DeployInfoHotfix`,
  `Restore-HotfixFiles`, `Invoke-SiteWarmup`, `Test-HotfixWritable`,
  `Test-SameFileContent`.

- El **warm-up reintenta por http** si el HTTPS se cae a nivel de conexion: el site
  local renegocia la conexion TLS y `HttpWebRequest` no lo soporta (curl si), asi
  que sin el reintento un site sano se reportaba como caido. Medido contra
  esp.emkt.test: 32,5 s de arranque en frio que, sin warm-up, paga el primero que entra.

### Fixed
- `Invoke-GitCommand` centraliza las llamadas a git: escribe avisos rutinarios
  por stderr ("CRLF will be replaced by LF") y con `$ErrorActionPreference =
  'Stop'` PowerShell 5.1 los convierte en error **terminante** aunque se
  redirijan a `$null`. Se decide por el código de salida, que es el contrato de
  git.
- `Test-SameFileContent` compara ficheros con .NET en vez de `Get-FileHash`: una
  sesión 5.1 lanzada desde un `pwsh` 7 hereda su `PSModulePath`, carga los
  módulos de PS7 y se queda **sin ese cmdlet**.

## [0.5.0] - 2026-09-03

### Added
- **Aprovisionamiento de sites desde una plantilla.** Una entrada de
  `environments.json` puede declarar `templateSite` (nombre de un site IIS del
  mismo servidor): el primer `Publish` en ese entorno crea lo que falte —carpeta,
  app pool y site llamados como el entorno, bindings 80/443 para el host de
  `siteUrl` (o `hostName`) con el certificado de la plantilla si lo cubre, y
  siembra de `Web.config` + `connections.config` desde la carpeta de la
  plantilla— y en los siguientes no toca nada. Con `databaseMap`
  (`{"CCEspana": "CCEspana_esp3"}`) las cadenas de conexión sembradas se apuntan
  a SU base de datos. Sin `templateSite` el comportamiento es el de siempre: un
  destino inexistente falla. Nueva función exportada `Initialize-IisSite` (los
  pasos 1-6 de `tools\New-LocalIisSite.ps1`, que ahora delega en ella) y
  `Set-ConnectionStringCatalog`. `Add-PublishEnvironment.ps1` acepta
  `-TemplateSite`. El plan de `Invoke-DeployOrder` muestra `provision`.
- **Actualización remota del publicador.** `Request-RemoteUpdate -Server
  deployments-76` hace `POST /api/update`: el servidor encola una orden
  `kind=update` en la MISMA cola FIFO que los despliegues (nunca se actualiza el
  módulo a mitad de un publish), la tarea elevada hace `Update-PublishToIIS`
  (git pull --ff-only + reinstalar) y reinicia la tarea 'Publish Endpoint' para
  que el listener cargue el código nuevo; el cliente sondea el resultado
  tolerando el corte del reinicio y termina con `GET /api/version` para enseñar
  el salto. Nuevas: `GET /api/version`, `Get-RemoteDeployVersion`,
  `Request-ModuleUpdate` (mitad local), `Write-UpdateOrder`,
  `Get-PublishToIISVersionInfo`. Requisito: la primera vez que un servidor
  recibe esta versión hay que actualizarlo por RDP; desde entonces, sin RDP.

### Changed
- `Publish` **preserva también `connections.config`** del site en el swap, con
  la misma política que `web.config` (`-OverrideWebconfig` publica el del build
  y guarda el del site como `.previous`). Antes, al estar gitignored en el repo,
  cada publish arrastraba el del ORIGEN del servidor a todos los sites
  construidos desde él: misma base de datos para todos.
- `Publish` lee la entrada del entorno aunque reciba rutas explícitas (para
  resolver `templateSite`/`hostName`/`databaseMap`) y tolera un entorno ad hoc
  que no está en la config central.
- La versión del manifiesto se lee por regex (como `Push-Release.ps1`), no con
  `Import-PowerShellDataFile`, que no existe en todas las instalaciones de 5.1.

## [0.4.7] - 2026-09-02

### Added
- Entornos **ad hoc** para worktrees efímeros: `Request-Publish -EnvironmentFile
  <ruta.json>` acepta un fichero con la misma forma que una entrada de
  `environments.json` más su `name` (convención: `.publish-env.json` en la raíz
  del worktree). La definición viaja DENTRO de la orden (`environmentDef`), la
  tarea elevada la usa en lugar de la config central y `Publish` recibe las rutas
  explícitas — la config central queda solo para los entornos estables. Guardas:
  `name`/`origin`/`destination` obligatorios, sin colisión con entornos centrales
  y nunca `prod`/`staging`. Nueva función exportada `Read-AdHocEnvironment`.

## [0.4.6] - 2026-09-02

### Added
- `requestedBy` (`EQUIPO\usuario` de quien pide el deploy) viaja con la orden por
  toda la cadena —`Request-RemotePublish` → endpoint → cola → drenador →
  `Request-Publish` → orden → `Invoke-DeployOrder` → `Publish`— hasta el
  `deploy-info.json` del site, junto a `publishedBy` (la cuenta que ejecutó el
  swap). El dashboard lo muestra en el sello de cada entorno. Es atribución, no
  autenticación: el nombre lo declara el cliente.

### Fixed
- El botón Publish del dashboard hace la petición HTTP al endpoint directamente
  desde Python (encola y sondea `/api/result`), en vez de lanzar un `powershell`
  hijo que abría una ventana de consola en el escritorio en cada clic.

## [0.4.5] - 2026-09-01

### Fixed
- `Start-DeployEndpoint.ps1` (el script de la tarea) no aceptaba `-DrainerTaskName`,
  que la tarea sí le pasaba desde 0.4.4: el proceso salía con código 1 y el endpoint
  no arrancaba (task en Ready, puerto rechazado). Ahora lo declara y lo reenvía.

## [0.4.4] - 2026-09-01

### Added
- Registro de tokens **por servidor** (`Set-DeployToken` / `Get-DeployToken`) y
  sección `servers` en `environments.json`: cada entorno referencia su servidor de
  publicación por nombre, y `endpointUrl` + token se resuelven por servidor. Sirve
  para N servidores sin repetir datos ni tener un token único.
- `Register-Dashboard`: el dashboard como tarea `Publish Dashboard` **sin
  privilegios**, headless (pythonw, sin consola) y arrancando con Windows. Deja de
  depender de una ventana de PowerShell abierta.

### Changed
- El dashboard publica **siempre por endpoint** (cliente puro, sin elevación): los
  entornos locales van al endpoint del propio equipo (servidor `portatil`,
  `http://127.0.0.1:8770`). Se retira el camino de publish local elevado del dashboard.
- Drenador de la cola **bajo demanda**: lo dispara el endpoint al encolar, procesa
  y termina, en vez de un proceso sondeando. En reposo solo corre el listener del
  endpoint (bloqueado en GetContext) → consumo imperceptible.

## [0.4.3] - 2026-09-01

### Fixed
- El listener del endpoint ya no muere tras la primera petición: la auditoría
  quedaba fuera del try/finally y leía `RemoteEndPoint` sobre un contexto ya
  cerrado (lanzaba con `ErrorActionPreference=Stop` y tumbaba el bucle, dejando la
  tarea en Ready y el puerto sin nadie → 502). Ahora cada petición y la auditoría
  van en su try/catch y el listener se relanza si cae.

## [0.4.2] - 2026-09-01

### Added
- `Register-DeployProxySite`: crea el site IIS reverse-proxy del endpoint en una
  llamada (ARR + web.config con la regla de reescritura + binding http:80) y
  **reusa el certificado** que ya cubra el host (el wildcard `*.economitza.com`)
  para el https:443, sin sacar uno nuevo; `-FromSite`/`-CertThumbprint`/`-RestrictToIp`/`-DryRun`.

### Fixed
- docs: aclarado que el DNS del endpoint va en AWS Route 53, no en Webempresa.

## [0.4.1] - 2026-09-01

### Added
- One-liners de módulo para preparar el servidor sin ejecutar scripts desde una
  carpeta concreta: `Register-DeployEndpoint` (levanta las tareas del endpoint y
  el drenador y saca el token) y `Test-DeployEndpoint` (comprueba `/health`).
- Este CHANGELOG.md.

## [0.4.0] - 2026-09-01

### Added
- Endpoint HTTP de despliegue remoto (`Start-DeployEndpoint`), que escucha solo
  en loopback tras un IIS con reverse proxy y token, y **encola** cada orden.
- Cola FIFO serializada por un drenador (`Invoke-DeployQueueDrain`) que reutiliza
  la tarea elevada `Publish Local`: nunca hay dos publicando a la vez y ninguna
  orden se pierde. Estado por `runId` (queued/running/ok/error).
- Cliente `Request-RemotePublish` y disparo remoto desde el botón Publish del
  dashboard para entornos con `endpointUrl`.
- `Add-PublishEnvironment.ps1`: alta interactiva de entornos con commit-push.
- `Push-Release.ps1`: versionado por push (+1 patch), commit y push en un paso.

### Changed
- `ModuleVersion` subido de 0.1.0 (esqueleto inicial) a 0.4.0, con ReleaseNotes
  que reflejan las capacidades reales del módulo.

## [0.1.0]

### Added
- Base del módulo (sin versionar por separado en su momento): publish a IIS con
  swap seguro y `web.config` preservado, sello `deploy-info.json`, dashboard de
  publicación y órdenes de despliegue vía la tarea elevada `Publish Local`.
