# Dashboard de publicación — diseño consolidado

> Visión de Joaquim (2026-07-17). Documento de diseño previo a implementación;
> las fases están ordenadas para que cada una aporte valor por sí sola.

## Qué se quiere

Un mini servidor web local que muestre, por cada entorno/site:

| Campo | Contenido |
|---|---|
| **Servidor** | Nombre/IP del servidor destino |
| **Rama** | Desplegable **buscable** con las ramas del repo, ordenado por fecha de último commit (descendente, no alfabético — hay muchísimas ramas); el valor seleccionado es el que se publicará |
| **Publish** | Botón que lanza la publicación de la rama seleccionada al site |
| **Status** | Si el entorno publicado está en ejecución o no |
| **Online** | Semáforo: 🟢 el site responde con normalidad · ⚪ apagado · 🔴 en estado de error |
| **Detalles** | 1) rama publicada, 2) commit publicado |

Matices importantes:
- La información es **del repo Y del site**: un mismo repo se publica a varios
  sites, así que el estado/versión es por site (= por entorno de
  `config/environments.json`), no por repo.
- Hoy la rama/commit publicados **no se persisten en ningún sitio** — es el
  primer hueco a cerrar (Fase 1), todo lo demás se apoya en ello.
- Al servidor remoto hoy solo hay acceso por **RDP**: el disparo remoto del
  publish es el problema de transporte a resolver (Fase 3).

## Fase 1 — Sello de versión en el site publicado (`deploy-info.json`) — ✅ IMPLEMENTADA (2026-07-21)

En cada `Publish`, escribir en la raíz del site publicado un `deploy-info.json`:

```json
{
  "branch": "main_deploy-20260715",
  "commit": "204f03043",
  "commitDate": "2026-07-17T15:24:27+02:00",
  "publishDate": "2026-07-17T18:40:12+02:00",
  "environment": "testesp3",
  "publishedBy": "joaquimms@MAQUINA"
}
```

**Dónde implementarlo — decisión razonada**: en el propio módulo de publish
(función auxiliar `New-DeployInfo` en `src/`), NO en el `.csproj`:
- El publish script corre donde está la copia de trabajo git → `git -C
  $ProjectPath rev-parse --short HEAD` y `--abbrev-ref HEAD` sin problema.
  (El csproj podría hacerlo con un target Exec pre-build, pero además de la
  duda de visibilidad de `.git`, conceptualmente rama/commit/entorno son
  **metadatos de despliegue, no de build** — el csproj ni sabe a qué site va.)
- Al escribirse tras el MSBuild y antes del swap, cae en `releasing/` y viaja
  con el site de forma atómica.

Bonus inmediato: `GET https://<site>/deploy-info.json` ya responde la rama y
commit publicados **sin necesidad de agente en el servidor**. (Valorar si se
quiere restringir su exposición pública — allowlist de IP o carpeta protegida —
aunque el contenido es poco sensible.)

## Fase 2 — Sondas de estado (sin tocar el servidor)

El dashboard obtiene Status/Online/Detalles por **HTTP puro contra el site**:
- `GET /deploy-info.json` → rama + commit (Detalles).
- `GET /` (o una URL de health barata) →
  - 200 → 🟢 online
  - timeout / connection refused → ⚪ apagado
  - 5xx / página de error → 🔴 error
- "Status" (en ejecución o no) se deriva de lo mismo; si algún día hay agente
  (Fase 3) podrá afinarse con el estado real del app pool.

## Fase 3 — Disparo remoto del Publish (el problema de transporte)

Opciones analizadas, de más a menos recomendada para nuestro contexto
(solo RDP hoy, firewall de entrada presumiblemente cerrado):

1. **Runner de GitLab CI en el servidor** (pull, sin abrir puertos de entrada):
   el servidor ejecuta un runner que tira de jobs `deploy` del pipeline. El
   botón Publish del dashboard dispara el pipeline vía API de GitLab. Sinergia
   total con la tarea de CI ya encolada en el WORKER — un solo agente resuelve
   CI y despliegues.
2. **Agente propio en modo pull**: tarea programada en el servidor que consulta
   cada X segundos una cola (fichero en carpeta compartida, rama git de
   "órdenes", o endpoint saliente) y ejecuta `Publish` del módulo. Sin puertos
   de entrada; más artesanal que (1).
3. **PowerShell Remoting (WinRM)**: lo natural en Windows y lo más directo
   (`Invoke-Command -ComputerName ...  { Publish ... }`), pero requiere abrir
   5985/5986 hacia el servidor — depende de red/VPN.
4. **Webhook/listener HTTP en el servidor**: requiere abrir puerto de entrada y
   asegurar el endpoint (token, TLS) — más superficie que (1)/(2) para el mismo
   resultado.

## Fase 4 — El mini web server (UI)

- Mismo patrón que el preview-checker del WORKER: servidor Python stdlib
  (`http.server`) + HTML/JS vanilla, sin dependencias. Vive en `dashboard/`
  de este repo.
- Fuente de entornos: `config/environments.json` (ya existe: origin,
  destination, appPool por entorno; ampliar con `siteUrl` y `serverName`).
- Ramas: `git -C <origin> for-each-ref --sort=-committerdate --format='%(refname:short)|%(committerdate:iso)' refs/remotes/origin` → desplegable buscable (input + lista filtrada) manteniendo el orden por fecha.
- El botón Publish invoca la Fase 3 elegida y refresca las sondas de la Fase 2.

## Orden de implementación propuesto

1. Fase 1 (`New-DeployInfo` + integración en `Publish`, con tests Pester) — pequeña y desbloquea todo.
2. Fase 2+4 en local apuntando a sites ya accesibles por HTTP (valor visible sin resolver el transporte).
3. Fase 3 según decisión de infraestructura (recomendación: runner GitLab, unificando con la tarea de CI).
