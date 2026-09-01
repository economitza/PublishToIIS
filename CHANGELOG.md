# Changelog

Novedades reseñables de PublishToIIS. Formato basado en
[Keep a Changelog 1.0.0](https://keepachangelog.com/es-ES/1.0.0/); versionado
[SemVer](https://semver.org/lang/es/). Desde 0.4.0 la versión funciona como
**contador de push**: cada push sube el tercer dígito (patch) vía
`tools\Push-Release.ps1` (`-Minor`/`-Major` suben ese nivel y reinician los de abajo).

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
