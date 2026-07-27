#!/usr/bin/env python3
"""Dashboard de publicación (Fase 2+4 del diseño en docs/dashboard-design.md).

Mini servidor local sin dependencias: sirve la UI y expone una API que
sondea cada entorno por HTTP (deploy-info.json + home) y lista las ramas
del repo ordenadas por fecha de commit. El Publish solo funciona para
entornos cuyo `origin` existe en esta máquina (el disparo remoto es Fase 3).

Uso:  python server.py [puerto]   (por defecto 8765)
"""
import base64
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

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
    envs = []
    for name, env in cfg.get("environments", {}).items():
        envs.append({
            "name": name,
            "origin": env.get("origin", ""),
            "destination": env.get("destination", ""),
            "siteUrl": env.get("siteUrl", ""),
            "serverName": env.get("serverName", ""),
            "localOrigin": Path(env.get("origin", "")).exists(),
        })
    return envs


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
# Los entornos de RC no sellan deploy-info.json: lo desplegado se anuncia en
# comentarios de Jira con un link al entorno. Reconstruimos la foto con la
# regla acordada: comentarios en cronológico inverso, solo los que llevan
# links, y la PRIMERA aparición de cada entorno (host con "test" o "dev")
# fija su entrada (jira + fecha); las menciones más antiguas se saltan.
JIRA_ENV_FILE = os.environ.get(
    "JIRA_ENV_FILE",
    r"C:\Users\joaquimms\OneDrive - economitza.com\Documents\Projectes\000. WORKER\.env")
JIRA_WINDOW_DAYS = int(os.environ.get("JIRA_WINDOW_DAYS", "90"))
JIRA_CACHE_TTL = 600  # segundos; el escaneo completo tarda ~10-30 s
_jira_cache = {"ts": 0.0, "data": None}


def load_jira_creds():
    """Lee JIRA_BASE_URL/JIRA_EMAIL/JIRA_API_TOKEN de un .env (clave=valor)."""
    path = Path(JIRA_ENV_FILE)
    if not path.exists():
        return None
    creds = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\s*([^#=]+)=(.*)$", line)
        if m:
            creds[m.group(1).strip()] = m.group(2).strip()
    if not all(creds.get(k) for k in ("JIRA_BASE_URL", "JIRA_EMAIL", "JIRA_API_TOKEN")):
        return None
    return creds


def jira_get(creds, path):
    auth = base64.b64encode(
        f"{creds['JIRA_EMAIL']}:{creds['JIRA_API_TOKEN']}".encode()).decode()
    req = urllib.request.Request(
        creds["JIRA_BASE_URL"].rstrip("/") + path,
        headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def adf_links(node):
    """Todos los links de un cuerpo ADF: texto http(s), marks de link e inlineCards."""
    links = []

    def walk(n):
        if isinstance(n, list):
            for c in n:
                walk(c)
            return
        if not isinstance(n, dict):
            return
        if isinstance(n.get("text"), str):
            links.extend(re.findall(r"https?://[^\s|\]>)]+", n["text"]))
        attrs = n.get("attrs") or {}
        if isinstance(attrs.get("url"), str):
            links.append(attrs["url"])
        for mk in n.get("marks") or []:
            href = (mk.get("attrs") or {}).get("href")
            if isinstance(href, str):
                links.append(href)
        walk(n.get("content"))

    walk(node)
    return links


def fetch_recent_comments(creds):
    """Comentarios (fecha, jira, links) de los tickets tocados en la ventana."""
    jql = f"project = SI AND updated >= -{JIRA_WINDOW_DAYS}d ORDER BY updated DESC"
    issues, next_token = [], None
    while True:
        path = f"/rest/api/3/search/jql?jql={quote(jql)}&fields=none&maxResults=100"
        if next_token:
            path += f"&nextPageToken={next_token}"
        page = jira_get(creds, path)
        issues.extend(i["key"] for i in page.get("issues", []))
        next_token = page.get("nextPageToken")
        if not next_token or len(issues) >= 400:
            break

    def comments_of(key):
        try:
            data = jira_get(creds, f"/rest/api/3/issue/{key}/comment?orderBy=-created&maxResults=25")
            out = []
            for cm in data.get("comments", []):
                links = adf_links(cm.get("body"))
                if links:
                    out.append({"created": cm.get("created", ""), "jira": key, "links": links})
            return out
        except Exception:
            return []  # un ticket ilegible no tumba el listado

    comments = []
    with ThreadPoolExecutor(max_workers=10) as pool:
        for chunk in pool.map(comments_of, issues):
            comments.extend(chunk)
    return comments


def build_env_table(comments):
    """Cronológico inverso; la primera mención de cada entorno gana, el resto skip.

    Entorno = host con "test"/"dev", deduplicado por host (http y https son el
    mismo entorno) y limitado a dominios propios (*.economitza.com, *.test):
    sin el filtro se cuelan hosts externos tipo supportcenter.devexpress.com.
    """
    table, seen = [], set()
    for cm in sorted(comments, key=lambda c: c["created"], reverse=True):
        for link in cm["links"]:
            host = (urlparse(link).hostname or "").lower()
            if not host or ("test" not in host and "dev" not in host):
                continue
            if not (host.endswith(".economitza.com") or host.endswith(".test")):
                continue
            if host in seen:
                continue
            seen.add(host)
            table.append({"env": f"https://{host}", "jira": cm["jira"], "fecha": cm["created"][:10]})
    return table


def jira_test_envs(force=False):
    if not force and _jira_cache["data"] and time.time() - _jira_cache["ts"] < JIRA_CACHE_TTL:
        return _jira_cache["data"]
    creds = load_jira_creds()
    if not creds:
        return {"error": f"sin credenciales Jira (revisa {JIRA_ENV_FILE})", "envs": []}
    try:
        table = build_env_table(fetch_recent_comments(creds))
        data = {"envs": table, "jiraBase": creds["JIRA_BASE_URL"].rstrip("/"),
                "windowDays": JIRA_WINDOW_DAYS,
                "generatedAt": time.strftime("%Y-%m-%d %H:%M:%S")}
        _jira_cache.update(ts=time.time(), data=data)
        return data
    except Exception as e:
        return {"error": str(e), "envs": []}


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
    """Publish local: checkout de la rama en el origin y Publish del módulo.

    Solo para entornos con origin accesible en esta máquina; el resto es Fase 3.
    Requiere que este servidor corra en una consola con permisos de administrador
    (el swap de IIS los necesita).
    """
    envs = {e["name"]: e for e in load_environments()}
    env = envs.get(env_name)
    if not env:
        return 404, {"error": f"entorno desconocido: {env_name}"}
    if not env["localOrigin"]:
        return 501, {"error": "origin no accesible desde esta máquina: disparo remoto pendiente (Fase 3)"}

    # Validar la rama ANTES de interpolarla en el comando (evita inyección en el
    # borde Python->PowerShell; Invoke-DeployOrder revalida del lado PS).
    if not re.match(r"^[A-Za-z0-9._/+\-]+$", branch or ""):
        return 400, {"error": f"Rama con formato inválido: '{branch}'"}

    module = str(ROOT.parent / "PublishToIIS.psd1")
    ps = (f"$ErrorActionPreference='Stop'; "
          f"Import-Module '{module}' -Force; "
          f"Invoke-DeployOrder -Environment '{env_name}' -Branch '{branch}' -Execute")
    r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
                       capture_output=True, text=True, timeout=1800)
    out = ((r.stdout or "") + ("\n" + r.stderr if r.stderr else "")).strip()

    if r.returncode != 0:
        detail = out or "(el proceso no devolvió salida)"
        low = detail.lower()
        if "administrator" in low or "administrador" in low:
            detail += ("\n\n>>> ACCIÓN: el publish necesita privilegios de administrador "
                       "(parar el app pool y swap de IIS) y el dashboard corre sin elevar. "
                       "Arranca el servidor desde una consola 'Ejecutar como administrador', "
                       "o configura la tarea 'Publish Dashboard' con privilegios elevados.")
        elif "did not match" in low or "no fast-forward" in low or "ff-only" in low:
            detail += ("\n\n>>> ACCIÓN: la rama local del repo diverge del remoto; "
                       "resuélvela a mano (o elige otra rama) antes de reintentar.")
        return 500, {"error": f"Publish de '{env_name}' falló", "detail": detail[-4000:]}
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
