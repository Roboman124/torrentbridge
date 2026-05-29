import asyncio
import json
import logging
import os
import time
from aiohttp import web

logger = logging.getLogger("torrentbridge.api")


def create_app(engine, config: dict) -> web.Application:
    app = web.Application()
    handler = APIHandler(engine, config)

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
    def __init__(self, engine, config: dict):
        self.engine = engine
        self.config = config
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

    async def serve_index(self, request):
        index_path = os.path.join(os.path.dirname(__file__), "../web/static/index.html")
        with open(index_path) as f:
            return web.Response(text=f.read(), content_type="text/html")

    # ── Status ────────────────────────────────────────────────────────────────

    async def get_status(self, request):
        from core.engine import MigrationStage
        active = [j for j in self.engine.jobs.values() if j.stage != MigrationStage.DONE]
        return self._json_response({
            "running": self.engine._running,
            "active_count": len(active),
            "seeder_online": await self._check_instance_online("seeder"),
            "downloader_online": await self._check_instance_online("downloader"),
            "uptime": time.time() - getattr(self.engine, "_start_time", time.time()),
        })

    async def _check_instance_online(self, which: str) -> bool:
        """
        Check if a qBittorrent instance is online by attempting a login.
        Uses session-based auth to handle binhex 204 responses correctly.
        """
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
        for key in ("qbit_a_pass", "qbit_b_pass", "sonarr_api_key", "radarr_api_key"):
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

        try:
            os.makedirs("/config", exist_ok=True)
            from core.config import save_config      # fixed: was from .config (wrong package)
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
        job.stage = MigrationStage.QUEUED
        job.error = None
        task = asyncio.create_task(self.engine._run_migration(job))
        self.engine._tasks[torrent_hash] = task
        return self._json_response({"ok": True})

    async def cancel_job(self, request):
        torrent_hash = request.match_info["hash"]
        self.engine.cancel_job(torrent_hash)    # uses engine method that also cancels the task
        return self._json_response({"ok": True})

    # ── Pending ───────────────────────────────────────────────────────────────

    async def get_pending(self, request):
        return self._json_response(list(self.engine.pending_approval.values()))

    async def approve_pending(self, request):
        """Force-start migration immediately, skipping any import wait delay."""
        torrent_hash = request.match_info["hash"]
        torrent = self.engine.pending_approval.get(torrent_hash)
        if not torrent:
            return self._json_response({"error": "Not found in pending list"}, 404)

        # If already running (auto-queue started it), just set skip_wait to interrupt the delay
        if torrent_hash in self.engine.jobs:
            job = self.engine.jobs[torrent_hash]
            job.skip_wait  = True
            job.status_msg = "Manually triggered — skipping wait…"
            logger.info(f"Migrate Now: skipping wait for {job.torrent_name}")
            return self._json_response({"ok": True, "note": "Skipping import wait"})

        # Not yet started — create and queue immediately with skip_wait=True
        from core.engine import MigrationJob
        job = MigrationJob(
            torrent_hash=torrent["hash"],
            torrent_name=torrent["name"],
            size_bytes=torrent["size_bytes"],
            save_path=torrent["save_path"],
            content_path=torrent["content_path"],
            skip_wait=True,
        )
        async with self.engine._lock:
            self.engine.jobs[torrent_hash] = job
            task = asyncio.create_task(self.engine._run_migration(job))
            self.engine._tasks[torrent_hash] = task
        return self._json_response({"ok": True})

    async def dismiss_pending(self, request):
        torrent_hash = request.match_info["hash"]
        # Also cancel any running migration for this hash
        self.engine.cancel_job(torrent_hash)
        self.engine.dismissed_hashes.add(torrent_hash)
        return self._json_response({"ok": True})

    # ── History ───────────────────────────────────────────────────────────────

    async def get_history(self, request):
        limit = int(request.rel_url.query.get("limit", 50))
        return self._json_response(self.engine.history[:limit])

    # ── Stats ─────────────────────────────────────────────────────────────────

    async def get_stats(self, request):
        stats = dict(self.engine.stats)
        # Get seeder torrent counts via session-based auth (no qbittorrentapi.Client)
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
        except Exception as e:
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

        target = data.get("target")
        result = {"ok": False, "message": "Unknown target"}

        if target == "downloader":
            result = await self._qbit_test(
                host=self.config.get("qbit_a_host", "localhost"),
                port=int(self.config.get("qbit_a_port", 8080)),
                username=self.config.get("qbit_a_user", "admin"),
                password=self.config.get("qbit_a_pass", ""),
            )
        elif target == "seeder":
            if not self.config.get("pi_host"):
                result = {"ok": False, "message": "Seeder host not configured"}
            else:
                result = await self._qbit_test(
                    host=self.config.get("pi_host", ""),
                    port=int(self.config.get("qbit_b_port", 8080)),
                    username=self.config.get("qbit_b_user", "admin"),
                    password=self.config.get("qbit_b_pass", ""),
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
