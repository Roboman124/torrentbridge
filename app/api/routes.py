import asyncio
import json
import logging
import os
import secrets
import time
from aiohttp import web

logger = logging.getLogger("torrentbridge.api")

MAX_RETRIES = 3

# ── Login page ────────────────────────────────────────────────────────────────

_LOGIN_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TorrentBridge · Sign In</title>
<link href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700&display=swap" rel="stylesheet">
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{background:#1f2634;color:#dde3ef;font-family:'Roboto',sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px}}
.card{{background:#252d3d;border:1px solid #323d52;border-radius:16px;padding:40px;width:100%;max-width:380px;box-shadow:0 8px 40px rgba(0,0,0,.5)}}
.logo{{width:52px;height:52px;background:#00b4d8;border-radius:14px;display:flex;align-items:center;justify-content:center;margin:0 auto 18px}}
.logo svg{{width:30px;height:30px}}
h1{{text-align:center;font-size:20px;font-weight:700;margin-bottom:4px}}
.sub{{text-align:center;font-size:13px;color:#8b98b1;margin-bottom:28px}}
.field{{margin-bottom:16px}}
.field label{{display:block;font-size:11px;font-weight:700;color:#8b98b1;text-transform:uppercase;letter-spacing:.07em;margin-bottom:6px}}
.field input{{width:100%;background:#1f2634;border:1px solid #3d4a62;border-radius:8px;padding:11px 14px;font-size:14px;color:#dde3ef;font-family:inherit;outline:none;transition:border-color .15s}}
.field input:focus{{border-color:#00b4d8}}
.btn{{width:100%;background:#00b4d8;border:none;border-radius:8px;padding:12px;font-size:14px;font-weight:600;color:#fff;cursor:pointer;font-family:inherit;margin-top:8px;transition:background .15s}}
.btn:hover{{background:#0090ac}}
.err{{background:rgba(231,76,60,.12);border:1px solid #e74c3c;border-radius:8px;padding:10px 14px;font-size:13px;color:#e74c3c;margin-bottom:16px}}
</style>
</head>
<body>
<div class="card">
  <div class="logo">
    <svg viewBox="0 0 16 16" fill="none">
      <circle cx="4" cy="8" r="2.5" fill="white" opacity=".9"/>
      <circle cx="13" cy="3.5" r="1.8" fill="white" opacity=".7"/>
      <circle cx="13" cy="12.5" r="1.8" fill="white" opacity=".7"/>
      <path d="M6.5 8h3M10 3.5H8.5a2 2 0 00-2 2v5a2 2 0 002 2H10" stroke="white" stroke-width="1.1" stroke-opacity=".4" fill="none"/>
    </svg>
  </div>
  <h1>TorrentBridge</h1>
  <div class="sub">Sign in to continue</div>
  {error_html}
  <form method="post" action="/api/auth/login">
    <input type="hidden" name="next" value="{next_url}">
    <div class="field"><label>Username</label><input type="text" name="username" autocomplete="username" autofocus></div>
    <div class="field"><label>Password</label><input type="password" name="password" autocomplete="current-password"></div>
    <button type="submit" class="btn">Sign In</button>
  </form>
</div>
</body>
</html>"""


# ── Session store ─────────────────────────────────────────────────────────────

class _SessionStore:
    def __init__(self):
        self._tokens: set[str] = set()

    def create(self) -> str:
        token = secrets.token_hex(32)
        self._tokens.add(token)
        return token

    def valid(self, token: str) -> bool:
        return token in self._tokens

    def revoke(self, token: str):
        self._tokens.discard(token)


# ── App factory ───────────────────────────────────────────────────────────────

def create_app(engine, config: dict) -> web.Application:
    sessions = _SessionStore()

    @web.middleware
    async def auth_middleware(request, handler):
        # Auth disabled when no password is set
        if not config.get("ui_password", ""):
            return await handler(request)

        # Always allow static assets, login page, and login POST
        skip = (request.path in ("/login", "/api/auth/login")
                or request.path.startswith("/static/"))
        if skip:
            return await handler(request)

        token = request.cookies.get("tb_session", "")
        if sessions.valid(token):
            return await handler(request)

        if request.path.startswith("/api/"):
            return web.Response(
                status=401,
                text=json.dumps({"error": "Unauthorized"}),
                content_type="application/json",
            )
        raise web.HTTPFound(f"/login?next={request.path}")

    app = web.Application(middlewares=[auth_middleware])
    handler = APIHandler(engine, config, sessions)

    # Auth
    app.router.add_get("/login",               handler.serve_login)
    app.router.add_post("/api/auth/login",      handler.do_login)
    app.router.add_post("/api/auth/logout",     handler.do_logout)

    # Core API
    app.router.add_get("/api/status",                    handler.get_status)
    app.router.add_get("/api/config",                    handler.get_config)
    app.router.add_post("/api/config",                   handler.post_config)
    app.router.add_get("/api/jobs",                      handler.get_jobs)
    app.router.add_get("/api/pending",                   handler.get_pending)
    app.router.add_post("/api/pending/{hash}/approve",   handler.approve_pending)
    app.router.add_post("/api/pending/{hash}/dismiss",   handler.dismiss_pending)
    app.router.add_get("/api/history",                   handler.get_history)
    app.router.add_get("/api/stats",                     handler.get_stats)
    app.router.add_post("/api/jobs/{hash}/retry",        handler.retry_job)
    app.router.add_delete("/api/jobs/{hash}",            handler.cancel_job)
    app.router.add_post("/api/test/connection",          handler.test_connection)
    app.router.add_get("/api/logs",                      handler.get_logs)

    static_dir = os.path.join(os.path.dirname(__file__), "../web/static")
    app.router.add_static("/static", static_dir)
    app.router.add_get("/", handler.serve_index)
    app.router.add_get("/{path:.*}", handler.serve_index)

    return app


class APIHandler:
    def __init__(self, engine, config: dict, sessions: _SessionStore):
        self.engine   = engine
        self.config   = config
        self.sessions = sessions
        self._log_buffer: list[dict] = []
        self._setup_log_capture()

    def _setup_log_capture(self):
        class BufferHandler(logging.Handler):
            def __init__(self, buf):
                super().__init__()
                self.buf = buf
            def emit(self, record):
                self.buf.append({
                    "time": record.created,
                    "level": record.levelname,
                    "msg": self.format(record),
                })
                if len(self.buf) > 500:
                    self.buf.pop(0)

        h = BufferHandler(self._log_buffer)
        h.setFormatter(logging.Formatter(
            "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
            datefmt="%H:%M:%S"
        ))
        logging.getLogger("torrentbridge").addHandler(h)

    def _json_response(self, data, status=200):
        return web.Response(
            text=json.dumps(data, default=str),
            status=status,
            content_type="application/json",
            headers={"Access-Control-Allow-Origin": "*"},
        )

    # ── Auth ──────────────────────────────────────────────────────────────────

    async def serve_login(self, request):
        next_url = request.rel_url.query.get("next", "/")
        error    = request.rel_url.query.get("error", "")
        error_html = f'<div class="err">{error}</div>' if error else ""
        html = _LOGIN_PAGE.format(error_html=error_html, next_url=next_url)
        return web.Response(text=html, content_type="text/html")

    async def do_login(self, request):
        data     = await request.post()
        username = data.get("username", "").strip()
        password = data.get("password", "")
        next_url = data.get("next", "/") or "/"

        cfg_user = self.config.get("ui_username", "admin")
        cfg_pass = self.config.get("ui_password", "")

        if username == cfg_user and password == cfg_pass:
            token    = self.sessions.create()
            response = web.HTTPFound(next_url)
            response.set_cookie(
                "tb_session", token,
                httponly=True, samesite="Lax", max_age=86400 * 30,
            )
            raise response

        raise web.HTTPFound(f"/login?next={next_url}&error=Invalid+username+or+password")

    async def do_logout(self, request):
        token = request.cookies.get("tb_session", "")
        self.sessions.revoke(token)
        response = web.HTTPFound("/login")
        response.del_cookie("tb_session")
        raise response

    # ── Pages ─────────────────────────────────────────────────────────────────

    async def serve_index(self, request):
        index_path = os.path.join(os.path.dirname(__file__), "../web/static/index.html")
        with open(index_path) as f:
            return web.Response(text=f.read(), content_type="text/html")

    # ── Status ────────────────────────────────────────────────────────────────

    async def get_status(self, request):
        from core.engine import MigrationStage
        active = [j for j in self.engine.jobs.values() if j.stage != MigrationStage.DONE]
        return self._json_response({
            "running":           self.engine._running,
            "active_count":      len(active),
            "seeder_online":     await self._check_instance_online("seeder"),
            "downloader_online": await self._check_instance_online("downloader"),
            "uptime":            time.time() - getattr(self.engine, "_start_time", time.time()),
            "ssh_key_warning":   self.engine._ssh_key_warning,
            "auth_enabled":      bool(self.config.get("ui_password", "")),
        })

    async def _check_instance_online(self, which: str) -> bool:
        import requests
        from requests.adapters import HTTPAdapter
        try:
            if which == "downloader":
                host = self.config.get("qbit_a_host", "")
                port = int(self.config.get("qbit_a_port", 8080))
                user = self.config.get("qbit_a_user", "admin")
                pw   = self.config.get("qbit_a_pass", "")
            else:
                host = self.config.get("pi_host", "")
                port = int(self.config.get("qbit_b_port", 8080))
                user = self.config.get("qbit_b_user", "admin")
                pw   = self.config.get("qbit_b_pass", "")

            if not host:
                return False

            loop = asyncio.get_running_loop()
            def _ping():
                base = f"http://{host}:{port}"
                s = requests.Session()
                s.mount("http://", HTTPAdapter(max_retries=0))
                r = s.post(
                    f"{base}/api/v2/auth/login",
                    data={"username": user, "password": pw},
                    headers={"Content-Type": "application/x-www-form-urlencoded",
                             "Referer": base},
                    timeout=4,
                )
                return r.status_code in (200, 204) and r.text.strip() != "Fails."

            return await asyncio.wait_for(
                loop.run_in_executor(None, _ping), timeout=6
            )
        except Exception:
            return False

    # ── Config ────────────────────────────────────────────────────────────────

    async def get_config(self, request):
        safe = dict(self.config)
        for key in ("qbit_a_pass", "qbit_b_pass", "sonarr_api_key",
                    "radarr_api_key", "ui_password"):
            if key in safe and safe[key]:
                safe[key] = "••••••••"
        return self._json_response(safe)

    async def post_config(self, request):
        try:
            data = await request.json()
        except Exception:
            return self._json_response({"error": "Invalid JSON"}, 400)

        for k, v in data.items():
            if v != "••••••••":
                self.config[k] = v

        # Re-validate SSH key whenever config is saved
        self.engine._validate_ssh_key()

        try:
            os.makedirs("/config", exist_ok=True)
            from core.config import save_config
            save_config(self.config)
            return self._json_response({"ok": True})
        except Exception as e:
            logger.error(f"Config file save failed: {e}")
            return self._json_response({
                "ok": True,
                "warning": f"Settings applied in memory but file write failed: {e}"
            })

    # ── Jobs ──────────────────────────────────────────────────────────────────

    async def get_jobs(self, request):
        return self._json_response([j.to_dict() for j in self.engine.jobs.values()])

    async def retry_job(self, request):
        torrent_hash = request.match_info["hash"]
        from core.engine import MigrationStage
        job = self.engine.jobs.get(torrent_hash)
        if not job:
            return self._json_response({"error": "Job not found"}, 404)
        if job.stage != MigrationStage.FAILED:
            return self._json_response({"error": "Job is not in failed state"}, 400)
        if job.retry_count >= MAX_RETRIES:
            return self._json_response({
                "error": f"Max retries ({MAX_RETRIES}) reached — permanently failed"
            }, 400)
        job.retry_count += 1
        job.stage = MigrationStage.QUEUED
        job.error = None
        task = asyncio.create_task(self.engine._run_migration(job))
        self.engine._tasks[torrent_hash] = task
        return self._json_response({"ok": True})

    async def cancel_job(self, request):
        torrent_hash = request.match_info["hash"]
        self.engine.cancel_job(torrent_hash)
        return self._json_response({"ok": True})

    # ── Pending ───────────────────────────────────────────────────────────────

    async def get_pending(self, request):
        return self._json_response(list(self.engine.pending_approval.values()))

    async def approve_pending(self, request):
        torrent_hash = request.match_info["hash"]
        torrent = self.engine.pending_approval.get(torrent_hash)
        if not torrent:
            if torrent_hash in self.engine.jobs:
                return self._json_response({"ok": True, "note": "Already migrating"})
            return self._json_response({"error": "Not found in pending list"}, 404)

        torrent["skip_wait"] = True
        torrent["status"]    = "starting…"
        logger.info(f"Migrate Now: skip_wait set for {torrent['name']}")
        return self._json_response({"ok": True})

    async def dismiss_pending(self, request):
        torrent_hash = request.match_info["hash"]
        self.engine.cancel_job(torrent_hash)
        self.engine.dismissed_hashes.add(torrent_hash)
        return self._json_response({"ok": True})

    # ── History ───────────────────────────────────────────────────────────────

    async def get_history(self, request):
        limit  = int(request.rel_url.query.get("limit", 200))
        search = request.rel_url.query.get("search", "").lower()
        status = request.rel_url.query.get("status", "")
        items  = self.engine.history
        if search:
            items = [h for h in items if search in h.get("name", "").lower()]
        if status:
            items = [h for h in items if h.get("stage", "") == status]
        return self._json_response(items[:limit])

    # ── Stats ─────────────────────────────────────────────────────────────────

    async def get_stats(self, request):
        stats = dict(self.engine.stats)
        import requests
        from requests.adapters import HTTPAdapter
        loop = asyncio.get_running_loop()
        try:
            pi_host = self.config.get("pi_host", "")
            pi_port = int(self.config.get("qbit_b_port", 8080))
            pi_user = self.config.get("qbit_b_user", "admin")
            pi_pass = self.config.get("qbit_b_pass", "")

            if not pi_host:
                raise ValueError("pi_host not configured")

            def _get_counts():
                from core.engine import _make_qbit_session
                s = _make_qbit_session(pi_host, pi_port, pi_user, pi_pass)
                base = f"http://{pi_host}:{pi_port}"
                r = s.get(f"{base}/api/v2/torrents/info",
                          headers={"Referer": base}, timeout=8)
                torrents = r.json()
                seeding_states = {"uploading", "stalledUP", "forcedUP", "queuedUP"}
                seeding = sum(1 for t in torrents if t.get("state","") in seeding_states)
                return len(torrents), seeding

            total, seeding = await asyncio.wait_for(
                loop.run_in_executor(None, _get_counts), timeout=10
            )
            stats["pi_total_torrents"] = total
            stats["pi_seeding"] = seeding
        except Exception:
            stats["pi_total_torrents"] = "?"
            stats["pi_seeding"] = "?"

        return self._json_response(stats)

    # ── Test Connection ───────────────────────────────────────────────────────

    async def _qbit_test(self, host: str, port: int, username: str, password: str) -> dict:
        import requests
        from requests.adapters import HTTPAdapter

        base = f"http://{host}:{port}"
        loop = asyncio.get_running_loop()

        def _do_test():
            session = requests.Session()
            session.mount("http://", HTTPAdapter(max_retries=0))
            try:
                r = session.post(
                    f"{base}/api/v2/auth/login",
                    data={"username": username, "password": password},
                    headers={"Content-Type": "application/x-www-form-urlencoded",
                             "Referer": base},
                    timeout=8,
                )
            except requests.exceptions.ConnectionError:
                return {"ok": False, "message": f"Cannot reach {host}:{port} — check host/port"}
            except requests.exceptions.Timeout:
                return {"ok": False, "message": f"Timed out connecting to {host}:{port}"}

            body = r.text.strip()
            if body == "Fails.":
                return {"ok": False, "message": "Login failed — check username/password"}
            if r.status_code not in (200, 204):
                return {"ok": False, "message": f"Unexpected response (HTTP {r.status_code}): {body[:100]}"}

            try:
                vr = session.get(f"{base}/api/v2/app/version",
                                 headers={"Referer": base}, timeout=5)
                if vr.status_code == 200:
                    return {"ok": True, "message": f"Connected — qBittorrent {vr.text.strip()}"}
                return {"ok": False,
                        "message": f"Login OK but version check returned HTTP {vr.status_code}"}
            except Exception as e:
                return {"ok": False, "message": f"Version check failed: {e}"}

        try:
            return await asyncio.wait_for(
                loop.run_in_executor(None, _do_test), timeout=15
            )
        except asyncio.TimeoutError:
            return {"ok": False, "message": "Connection timed out after 15s"}
        except Exception as e:
            return {"ok": False, "message": f"Error: {type(e).__name__}: {str(e)[:200]}"}

    async def test_connection(self, request):
        try:
            data = await request.json()
        except Exception:
            return self._json_response({"error": "Invalid JSON"}, 400)

        target      = data.get("target")
        inline_host = data.get("_host")
        inline_port = data.get("_port")
        inline_user = data.get("_user")
        inline_pass = data.get("_pass")
        result      = {"ok": False, "message": "Unknown target"}

        if target == "downloader":
            result = await self._qbit_test(
                host=inline_host or self.config.get("qbit_a_host", "localhost"),
                port=inline_port or int(self.config.get("qbit_a_port", 8080)),
                username=inline_user or self.config.get("qbit_a_user", "admin"),
                password=inline_pass or self.config.get("qbit_a_pass", ""),
            )
        elif target == "seeder":
            host = inline_host or self.config.get("pi_host", "")
            if not host:
                result = {"ok": False, "message": "Seeder host not configured"}
            else:
                result = await self._qbit_test(
                    host=host,
                    port=inline_port or int(self.config.get("qbit_b_port", 8080)),
                    username=inline_user or self.config.get("qbit_b_user", "admin"),
                    password=inline_pass or self.config.get("qbit_b_pass", ""),
                )
        elif target in ("sonarr", "radarr"):
            host    = self.config.get(f"{target}_host")
            port    = int(self.config.get(f"{target}_port", 8989 if target == "sonarr" else 7878))
            api_key = self.config.get(f"{target}_api_key", "")
            if not host:
                result = {"ok": False, "message": f"{target.capitalize()} host not configured"}
            else:
                try:
                    import aiohttp
                    url = f"http://{host}:{port}/api/v3/system/status?apiKey={api_key}"
                    async with aiohttp.ClientSession() as s:
                        async with s.get(url, timeout=aiohttp.ClientTimeout(total=5)) as r:
                            if r.status == 200:
                                body = await r.json()
                                result = {"ok": True,
                                          "message": f"Connected — {target.capitalize()} {body.get('version','')}"}
                            else:
                                result = {"ok": False, "message": f"HTTP {r.status}"}
                except Exception as e:
                    result = {"ok": False, "message": str(e)}

        return self._json_response(result)

    # ── Logs ──────────────────────────────────────────────────────────────────

    async def get_logs(self, request):
        limit = int(request.rel_url.query.get("limit", 100))
        level = request.rel_url.query.get("level", "")
        logs  = self._log_buffer[-limit:]
        if level:
            logs = [l for l in logs if l["level"] == level.upper()]
        return self._json_response(logs)
