# Endpoint HTTP de despliegue

Disparo remoto del `Publish` (Fase 3 del dashboard) por HTTP, para no depender
de que RC apruebe el despliegue automatico. El endpoint corre EN el servidor
destino, escucha solo en loopback y se expone a internet a traves de un site de
IIS que hace de reverse proxy con hostname y TLS propios.

## Cadena completa

```
cliente (Request-RemotePublish)
  --HTTPS--> https://deployments-76.economitza.com   (IIS site + ARR, TLS Let's Encrypt)
  --proxy--> http://127.0.0.1:8770                    (Publish Endpoint: listener, sin privilegios)
  --encola-> %ProgramData%\PublishToIIS\queue\        (una orden por fichero, FIFO)
  --drena--> Publish Queue Drainer (sin privilegios)  (una a una, en orden)
  --run---> tarea 'Publish Local' (elevada)           (checkout + MSBuild + swap IIS)
  --sello--> deploy-info.json en el site publicado + results\<runId>.json
```

Dos procesos de fondo, ambos SIN privilegios:

- **Publish Endpoint** (listener HTTP): recibe la peticion, valida y **encola** la
  orden. Nunca publica el mismo ni rechaza por "hay otra en marcha".
- **Publish Queue Drainer**: procesa la cola FIFO **de una en una** llamando a
  `Request-Publish`, que dispara la tarea elevada `Publish Local`. Al ser el
  unico que la llama en la via remota, serializa los despliegues sin candados:
  nunca hay dos publicando a la vez, y esp1/and1 lanzados seguidos se ejecutan en
  orden en vez de perderse. El resultado de cada uno queda en
  `results\<runId>.json` (`running` -> `ok`/`error`).

Toda la validacion (lista blanca de entornos sin prod/staging, formato de rama)
es la misma del resto del flujo. La tarea elevada `Publish Local` y el flujo
local (`Request-Publish`) no cambian.

## Por que loopback + reverse proxy y no exponer el puerto

El servidor solo tiene abiertos 80 y 443, ambos con binding por nombre en IIS.
Un listener Python/PowerShell no puede tomar 443 (lo tiene HTTP.sys para los
sites), y abrir un puerto nuevo hacia fuera no es opcion. La via limpia es que
IIS reciba en 443 por SNI el hostname del endpoint y reenvie a un puerto de
loopback. Ventajas:

- El enrutado por hostname deja intactos los demas sites: una peticion sin ese
  Host (por IP a pelo, un escaner) cae donde cae hoy, nunca en el endpoint.
- TLS lo termina IIS con un certificado normal de Let's Encrypt para el nombre
  (validacion HTTP-01 por el 80 ya abierto). Nada de certificados para IP.
- El proceso del endpoint nunca esta expuesto directamente: solo IIS le habla.

## Puesta en marcha en el servidor (una vez)

Requisitos: IIS con **URL Rewrite** + **ARR** (Application Request Routing) y el
modulo PublishToIIS instalado (`Install.ps1`). La tarea elevada `Publish Local`
ya debe estar registrada (`Register-PublishTask -Unattended`).

1. **DNS: en AWS Route 53.** La zona de `economitza.com` esta delegada en Route 53
   (nameservers `awsdns-*`), asi que el registro se crea en la consola de AWS,
   NO en el panel de Webempresa (un subdominio creado alli no resuelve, porque
   nadie consulta esa zona). Registro **A** `deployments-76.economitza.com` -> IP
   publica del servidor. Ya creado y resolviendo a `15.236.4.76`.

2. **Listener + token + URL ACL** (elevado, una vez). Una sola instruccion, desde
   cualquier carpeta, con el modulo cargado:

   ```powershell
   Import-Module PublishToIIS
   Register-DeployEndpoint            # -Port 8770 por defecto
   ```

   (`Register-DeployEndpoint` es el envoltorio de
   `tools\Register-DeployEndpointTask.ps1`: localiza el repo solo y se auto-eleva
   por UAC.) Genera el token de API (`%ProgramData%\PublishToIIS\api-token.txt`,
   se muestra UNA vez — copialo al cliente), reserva la URL ACL del loopback para
   que el listener escuche sin privilegios, y registra + arranca las dos tareas de
   fondo `Publish Endpoint` y `Publish Queue Drainer` (al arranque, S4U,
   relanzadas si mueren).

   Comprobacion: `Test-DeployEndpoint` -> `Endpoint OK en http://127.0.0.1:8770/health`.

3. **Site de IIS + reverse proxy**, tambien en una instruccion (elevado, requiere
   URL Rewrite + ARR instalados):

   ```powershell
   Register-DeployProxySite -HostName deployments-76.economitza.com
   # con restriccion por IP y copiando el cert de otro site:
   Register-DeployProxySite -HostName deployments-76.economitza.com -RestrictToIp <tu-ip> -FromSite devecoesp1
   ```

   Habilita el proxy de ARR, deja el `web.config` con la regla que reenvia todo a
   `http://127.0.0.1:8770/{R:1}`, crea el site con binding http:80 y **reusa el
   certificado** que ya cubra el host para el https:443 (ver punto siguiente).
   `-DryRun` muestra el plan sin tocar IIS. La IP real del cliente llega en
   `X-Forwarded-For` (ARR la añade) — es lo que el listener apunta en `endpoint.log`.

4. **Certificado: se reusa el que ya tienes, no hace falta uno nuevo.** Si en el
   servidor ya sirve un **wildcard `*.economitza.com`** (el que usan
   `devecoesp1.economitza.com` y compania), cubre `deployments-76.economitza.com`
   y `Register-DeployProxySite` lo enlaza solo al binding https:443. Un cert de un
   solo host (p. ej. solo `devecoesp1`) NO cubre `deployments-76`: ahi si haria
   falta un wildcard o uno que incluya el host (via win-acme, que el script indica
   como fallback si no encuentra ninguno que sirva).

5. **Autenticacion en el borde**: ademas del token, `-RestrictToIp` limita el site
   a la IP de origen del despliegue (IIS IP Address and Domain Restrictions). El
   firewall no sirve para esto porque 443 esta abierto en global.

## Uso desde el cliente

```powershell
$env:PUBLISHTOIIS_API_TOKEN = '<el token del servidor>'
Import-Module .\PublishToIIS.psd1
Request-RemotePublish -Url https://deployments-76.economitza.com `
    -Environment devecoesp1 -Branch main_deploy-20260901 -Execute
```

Sin `-Execute` es dry-run (valida y resuelve el plan, no publica). `-NoWait`
dispara y vuelve con el `runId`; el estado se consulta luego en
`GET /api/result?runId=...`.

### Desde el dashboard de publicación

El dashboard (`dashboard/`, en `localhost:8765`, corre en el portátil) publica en
estos entornos con el botón **Publish**, igual que en los locales. Un entorno es
"remoto" cuando su entrada en `environments.json` declara `endpointUrl`
(los `deveco*` apuntan a `https://deployments-76.economitza.com`); el botón llama
por dentro a `Request-RemotePublish`. El dashboard necesita el token del endpoint
en `PUBLISHTOIIS_API_TOKEN` o en `dashboard\remote-api-token.txt` (fichero
gitignorado). El Publish remoto NO requiere el dashboard elevado — la elevación
solo hace falta para el Publish local, que hace el swap de IIS en la propia
máquina.

## API

Todas menos `/health` exigen la cabecera `X-Api-Token`.

| Metodo | Ruta | Que hace |
|---|---|---|
| GET | `/health` | Sonda sin token: `{ok:true}`. |
| GET | `/api/environments` | Entornos desplegables (lista blanca, sin prod/staging). |
| POST | `/api/publish` | Cuerpo `{environment, branch, execute, overrideWebconfig, requestedBy}`. **Encola** y responde **202** con `runId` y `position`. No publica en la request. |
| GET | `/api/result?runId=...` | `queued` (con posicion) / `running` / `ok` / `error`; 404 si el runId no existe. |
| GET | `/api/queue` | Cola pendiente, en orden de proceso. |
| GET | `/api/log` | Cola del transcript de la publicacion en curso. |

Notas de diseño:

- El POST responde **202 sin bloquear**: una publicacion tarda minutos y el
  proxy de ARR cerraria la conexion por timeout. El cliente sondea `/api/result`.
- **Cola FIFO, nunca rechazo**: cada orden se encola y el drenador las procesa en
  orden, una a una. Dos despliegues a entornos distintos (esp1 y and1) lanzados
  seguidos se ejecutan ambos, en orden de llegada — no se pierde ninguno. El
  orden se fija con un contador persistente (`queue\.seq`), no con el reloj, que
  en Windows tiene resolucion de ~15 ms.
- `execute` solo dispara con un booleano JSON de verdad; cualquier otro valor
  degrada a dry-run (un `"false"` string convertido a `[bool]` seria `$true`).
- `requestedBy` (`EQUIPO\usuario` de quien pide) lo declara el cliente y viaja por
  la cola y la orden hasta el `deploy-info.json` del site, junto a `publishedBy`
  (la cuenta que ejecuto el swap: en un deploy por endpoint, la del listener). Si
  no viene, se anota la cuenta del proceso que encola. Es **atribucion, no
  autenticacion**: con el token compartido cualquiera puede declarar cualquier nombre.
- Cada peticion queda en `%ProgramData%\PublishToIIS\endpoint.log`
  (fecha | IP de X-Forwarded-For | metodo ruta | status); el drenador deja su
  rastro en `drainer.log`.

## Rotar el token

```powershell
New-DeployEndpointToken -Force            # nuevo token, invalida el anterior
Restart-ScheduledTask -TaskName 'Publish Endpoint'
```
