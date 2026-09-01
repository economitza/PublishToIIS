#!/usr/bin/env python3
"""Dashboard de publicación (Fase 2+4 del diseño en docs/dashboard-design.md).

Mini servidor local sin dependencias: sirve la UI y expone una API que
sondea cada entorno por HTTP (deploy-info.json + home) y lista las ramas
del repo ordenadas por fecha de commit. El Publish solo funciona para
entornos cuyo `origin` existe en esta máquina (el disparo remoto es Fase 3).

Uso:  python server.py [puerto]   (por defecto 8765)
"""
import json
import os
import re
import ssl
import subprocess
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT.parent / "config" / "environments.json"
# Repo local por defecto para listar ramas cuando el origin del entorno
# no existe en esta máquina (p. ej. rutas E:\ de los servidores de test).
DEFAULT_BRANCH_REPO = r"C:\Users\joaquimms\Documents\git\20260430\central-de-compres"
PROBE_TIMEOUT = 20  # los app pools fríos de los entornos de test tardan en despertar

_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE  # entornos de test con certificados internos


def load_environments():
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    servers = cfg.get("servers", {})
    envs = []
    for name, env in cfg.get("environments", {}).items():
        server = env.get("server", "")
        # endpointUrl se resuelve del servidor referenciado (o el legacy por entorno).
        endpoint_url = env.get("endpointUrl", "") or servers.get(server, {}).get("endpointUrl", "")
        local_origin = Path(env.get("origin", "")).exists()
        is_local = endpoint_url.startswith("http://127.0.0.1") or endpoint_url.startswith("http://localhost")
        envs.append({
            "name": name,
            "origin": env.get("origin", ""),
            "destination": env.get("destination", ""),
            "siteUrl": env.get("siteUrl", ""),
            "server": server,
            "serverName": env.get("serverName", "") or server,
            "responsable": env.get("responsable", ""),
            "endpointUrl": endpoint_url,
            "localOrigin": local_origin,
            # Todo se publica por endpoint (el dashboard es cliente puro, sin
            # privilegios). 'local' = el endpoint del propio equipo (loopback);
            # 'remote' = un servidor de test. Solo distingue orden y estilo en la UI.
            "local": is_local,
            "remote": bool(endpoint_url) and not is_local,
            "publishable": bool(endpoint_url),
        })
    return envs


def resolve_api_token(server):
    """Token del endpoint del servidor `server`, del registro por servidor en
    %ProgramData%\\PublishToIIS\\tokens\\<server>.txt. Compat: variable de entorno
    y fichero legacy remote-api-token.txt (token único)."""
    store = Path(os.environ.get("ProgramData", "")) / "PublishToIIS" / "tokens" / f"{server}.txt"
    try:
        if store.exists():
            t = store.read_text(encoding="utf-8").strip()
            if t:
                return t
    except Exception:
        pass
    tok = os.environ.get("PUBLISHTOIIS_API_TOKEN")
    if tok:
        return tok.strip()
    for p in (ROOT / "remote-api-token.txt",
              Path(os.environ.get("ProgramData", "")) / "PublishToIIS" / "remote-api-token.txt"):
        try:
            if p and p.exists():
                return p.read_text(encoding="utf-8").strip()
        except Exception:
            pass
    return None


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "publish-dashboard"})
    return urllib.request.urlopen(req, timeout=PROBE_TIMEOUT, context=_ssl_ctx)


def probe(env):
    """Estado de un entorno vía HTTP contra su siteUrl: deploy-info.json (qué hay
    desplegado y servido) + semáforo online. Mismo mecanismo para todos los
    entornos (local o remoto): lo autoritativo es lo que el site sirve."""
    site_url = env.get("siteUrl", "")
    result = {"online": "off", "deployInfo": None, "httpStatus": None, "error": None}
    if not site_url:
        result["error"] = "sin siteUrl configurada"
        return result
    base = site_url.rstrip("/")
    try:
        with http_get(base + "/deploy-info.json") as r:
            result["deployInfo"] = json.loads(r.read().decode("utf-8-sig"))
    except Exception:
        pass  # sello aún no publicado en ese site: no es un error del site
    try:
        with http_get(base + "/") as r:
            result["httpStatus"] = r.status
            result["online"] = "ok" if r.status == 200 else "error"
    except urllib.error.HTTPError as e:
        result["httpStatus"] = e.code
        result["online"] = "error"
        result["error"] = f"HTTP {e.code}"
    except Exception as e:
        result["online"] = "off"
        result["error"] = str(e.reason if hasattr(e, "reason") else e)
    return result


# ─── Entornos de test según comentarios de Jira ─────────────────────────────
# El cálculo vive en el microservicio jira-envs-service (000. WORKER, tarea
# "Economitza - Jira envs service", recalcula cada hora): aquí solo un proxy
# para que la UI lo consuma same-origin. Para añadir propiedades a la tabla,
# tocar SOLO el microservicio (el team dashboard consume el mismo servicio).
JIRA_ENVS_SERVICE = os.environ.get("JIRA_ENVS_SERVICE", "http://localhost:8768")


def jira_test_envs(force=False):
    url = JIRA_ENVS_SERVICE + "/api/test-envs" + ("?refresh=1" if force else "")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "publish-dashboard"})
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        return {"error": "microservicio jira-envs-service no disponible "
                         f"(tarea 'Economitza - Jira envs service'): {e}", "envs": []}


def list_branches(repo):
    out = subprocess.run(
        ["git", "-C", repo, "for-each-ref", "--sort=-committerdate",
         "--format=%(refname:short)|%(committerdate:iso8601)", "refs/remotes/origin"],
        capture_output=True, text=True, timeout=30)
    branches = []
    for line in out.stdout.splitlines():
        name, _, date = line.partition("|")
        name = name.replace("origin/", "", 1)
        if name not in ("HEAD", "origin"):  # origin/HEAD se abrevia como 'origin'
            branches.append({"name": name, "date": date})
    return branches


def publish(env_name, branch):
    """Publica la rama en el entorno SIEMPRE por el endpoint HTTP de su servidor:
    el dashboard es un cliente sin privilegios: no hace checkout ni swap, solo pide
    al endpoint (local del propio equipo o remoto) que lo haga."""
    envs = {e["name"]: e for e in load_environments()}
    env = envs.get(env_name)
    if not env:
        return 404, {"error": f"entorno desconocido: {env_name}"}

    # Validar la rama ANTES de interpolarla en el comando (evita inyección en el
    # borde Python->PowerShell; el módulo revalida del lado PS).
    if not re.match(r"^[A-Za-z0-9._/+\-]+$", branch or ""):
        return 400, {"error": f"Rama con formato inválido: '{branch}'"}

    if not env["endpointUrl"]:
        return 501, {"error": f"El entorno '{env_name}' no tiene servidor/endpoint configurado: "
                              "revisa su 'server' y la sección 'servers' del config."}
    return publish_via_endpoint(env, branch)


def publish_via_endpoint(env, branch):
    """POST al endpoint del servidor del entorno (encola y sondea) vía
    Request-RemotePublish. El token —el del servidor referenciado, del registro por
    servidor— viaja al proceso hijo por variable de entorno, no en la línea de comando."""
    server = env["server"]
    token = resolve_api_token(server)
    if not token:
        return 400, {"error": f"Sin token para el servidor '{server}'. Regístralo con: "
                              f"Set-DeployToken -Server {server}"}
    module = str(ROOT.parent / "PublishToIIS.psd1")
    url = env["endpointUrl"]
    ps = (f"$ErrorActionPreference='Stop'; "
          f"Import-Module '{module}' -Force; "
          f"Request-RemotePublish -Url '{url}' -Environment '{env['name']}' -Branch '{branch}' -Execute")
    child_env = {**os.environ, "PUBLISHTOIIS_API_TOKEN": token}
    r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
                       capture_output=True, text=True, timeout=1800, env=child_env)
    out = ((r.stdout or "") + ("\n" + r.stderr if r.stderr else "")).strip()
    if r.returncode != 0:
        return 500, {"error": f"Publish de '{env['name']}' (servidor '{server}') falló",
                     "detail": (out or "(el proceso no devolvió salida)")[-4000:]}
    return 200, {"ok": True, "output": out[-4000:]}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload, content_type="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/", "/index.html"):
            self._send(200, (ROOT / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif url.path == "/favicon.svg":
            self._send(200, (ROOT / "favicon.svg").read_bytes(), "image/svg+xml")
        elif url.path == "/api/environments":
            self._send(200, load_environments())
        elif url.path == "/api/status":
            name = parse_qs(url.query).get("env", [""])[0]
            envs = {e["name"]: e for e in load_environments()}
            if name not in envs:
                self._send(404, {"error": "entorno desconocido"})
                return
            self._send(200, probe(envs[name]))
        elif url.path == "/api/test-envs":
            force = parse_qs(url.query).get("refresh", ["0"])[0] == "1"
            self._send(200, jira_test_envs(force))
        elif url.path == "/api/branches":
            name = parse_qs(url.query).get("env", [""])[0]
            envs = {e["name"]: e for e in load_environments()}
            repo = envs[name]["origin"] if name in envs and envs[name]["localOrigin"] else DEFAULT_BRANCH_REPO
            try:
                self._send(200, list_branches(repo))
            except Exception as e:
                self._send(500, {"error": str(e)})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if urlparse(self.path).path == "/api/publish":
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length) or b"{}")
            code, payload = publish(data.get("env", ""), data.get("branch", ""))
            self._send(code, payload)
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):  # silenciar el ruido por request
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"Dashboard de publicación: http://localhost:{port}  (config: {CONFIG_PATH})")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
