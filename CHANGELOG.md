# Changelog

Novedades reseñables de PublishToIIS. Formato basado en
[Keep a Changelog 1.0.0](https://keepachangelog.com/es-ES/1.0.0/); versionado
[SemVer](https://semver.org/lang/es/). Desde 0.4.0 la versión funciona como
**contador de push**: cada push sube el tercer dígito (patch) vía
`tools\Push-Release.ps1` (`-Minor`/`-Major` suben ese nivel y reinician los de abajo).

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
