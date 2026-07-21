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

Estructura relevante:

- `src/` : implementación del módulo
- `config/environments.json` : fichero central con `origin` y `destination` por entorno
- `config/config.ps1` : loader `Get-PublishConfig`
- `tests/` : pruebas Pester
- `build/pack.ps1` : empaquetador simple

Integración en solución .NET Framework:

- Opción simple: añadir la carpeta del repo (o `src`/`config`) como `Existing Item` en la solución y marcar scripts a copiar al output (`Copy to Output Directory`).
- Opción escalable: generar un `.nupkg` y referenciarlo desde la solución CI/CD.
