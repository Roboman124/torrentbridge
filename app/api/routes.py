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

    app.router.add_get("/api/status", handler.get_status)
    app.router.add_get("/api/config", handler.get_config)
    app.router.add_post("/api/config", handler.post_config)
    app.router.add_get("/api/jobs", handler.get_jobs)
    app.router.add_get("/api/history", handler.get_history)
    app.router.add_get("/api/stats", handler.get_stats)
    app.router.add_post("/api/jobs/{hash}/retry", handler.retry_job)
    app.router.add_delete("/api/jobs/{hash}", handler.cancel_job)
    app.router.add_post("/api/test/connection", handler.test_connection)
    app.router.add_get("/api/logs", handler.get_logs)

    # Serve static frontend
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
        """Capture log lines into an in-memory buffer for the UI."""
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
        h.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s",
                                          datefmt="%H:%M:%S"))
        logging.getLogger("torrentbridge").addHandler(h)

    def _json_response(self, data, status=200):
        return web.Response(
            text=json.dumps(data, default=str),
            status=status,
            content_type="application/json",
            headers={"Access-Control-Allow-Origin": "*"},
        )

    async def serve_index(self, request):
        index_path = os.path.join(
            os.path.dirname(__file__), "../web/static/index.html"
        )
        with open(index_path) as f:
            return web.Response(text=f.read(), content_type="text/html")

    async def get_status(self, request):
        from .engine import MigrationStage
        active = [j for j in self.engine.jobs.values() if j.stage != MigrationStage.DONE]
        return self._json_response({
            "running": self.engine._running,
            "active_count": len(active),
            "seeder_online": await self._check_seeder_online(),
            "downloader_online": await self._check_downloader_online(),
            "uptime": time.time() - self.engine._start_time if hasattr(self.engine, "_start_time") else 0,
        })

    async def _check_seeder_online(self) -> bool:
        try:
            import aiohttp
            url = f"http://{self.config['pi_host']}:{self.config.get('qbit_b_port', 8080)}/api/v2/app/version"
            async with aiohttp.ClientSession() as s:
                async with s.get(url, timeout=aiohttp.ClientTimeout(total=3)) as r:
                    return r.status == 200
        except Exception:
            return False

    async def _check_downloader_online(self) -> bool:
        try:
            import aiohttp
            url = f"http://{self.config['qbit_a_host']}:{self.config.get('qbit_a_port', 8080)}/api/v2/app/version"
            async with aiohttp.ClientSession() as s:
                async with s.get(url, timeout=aiohttp.ClientTimeout(total=3)) as r:
                    return r.status == 200
        except Exception:
            return False

    async def get_config(self, request):
        # Never expose passwords in API response
        safe = {k: v for k, v in self.config.items()}
        for key in ("qbit_a_pass", "qbit_b_pass", "sonarr_api_key", "radarr_api_key"):
            if key in safe:
                safe[key] = "••••••••"
        return self._json_response(safe)

    async def post_config(self, request):
        try:
            data = await request.json()
        except Exception:
            return self._json_response({"error": "Invalid JSON"}, 400)

        # Update in-memory config
        for k, v in data.items():
            if v != "••••••••":  # Don't overwrite masked passwords
                self.config[k] = v

        # Persist to file
        from .config import save_config
        save_config(self.config)

        return self._json_response({"ok": True})

    async def get_jobs(self, request):
        jobs = [j.to_dict() for j in self.engine.jobs.values()]
        return self._json_response(jobs)

    async def get_history(self, request):
        limit = int(request.rel_url.query.get("limit", 50))
        return self._json_response(self.engine.history[:limit])

    async def get_stats(self, request):
        stats = dict(self.engine.stats)
        # Add seeder torrent count
        loop = asyncio.get_event_loop()
        try:
            import qbittorrentapi
            def _get_counts():
                with qbittorrentapi.Client(
                    host=self.config["pi_host"],
                    port=self.config.get("qbit_b_port", 8080),
                    username=self.config["qbit_b_user"],
                    password=self.config["qbit_b_pass"],
                ) as qbb:
                    torrents = qbb.torrents_info()
                    uploading = [t for t in torrents if "upload" in str(t.state).lower() or "seeding" in str(t.state).lower()]
                    return len(torrents), len(uploading)
            total, seeding = await asyncio.wait_for(
                loop.run_in_executor(None, _get_counts), timeout=5
            )
            stats["pi_total_torrents"] = total
            stats["pi_seeding"] = seeding
        except Exception:
            stats["pi_total_torrents"] = "?"
            stats["pi_seeding"] = "?"
        return self._json_response(stats)

    async def retry_job(self, request):
        torrent_hash = request.match_info["hash"]
        from .engine import MigrationStage
        job = self.engine.jobs.get(torrent_hash)
        if not job:
            return self._json_response({"error": "Job not found"}, 404)
        if job.stage != MigrationStage.FAILED:
            return self._json_response({"error": "Job is not in failed state"}, 400)
        job.stage = MigrationStage.QUEUED
        job.error = None
        asyncio.create_task(self.engine._run_migration(job))
        return self._json_response({"ok": True})

    async def cancel_job(self, request):
        torrent_hash = request.match_info["hash"]
        async with self.engine._lock:
            self.engine.jobs.pop(torrent_hash, None)
        return self._json_response({"ok": True})

    async def _qbit_test(self, host: str, port: int, username: str, password: str) -> dict:
        """
        Test qBittorrent connection using a persistent requests session.
        Handles both standard qBit (200 Ok.) and binhex (204 empty + SID cookie).
        """
        import requests
        from requests.adapters import HTTPAdapter

        base = f"http://{host}:{port}"
        session = requests.Session()
        adapter = HTTPAdapter(max_retries=0)
        session.mount("http://", adapter)
        session.headers.update({
            "Referer": base,
            "Origin": base,
        })

        loop = asyncio.get_event_loop()

        def _do_test():
            # Step 1: try connecting
            try:
                r = session.get(
                    f"{base}/api/v2/app/version",
                    timeout=5,
                )
                if r.status_code == 200:
                    return {"ok": True, "message": f"Connected (no auth needed) - qBittorrent {r.text.strip()}"}
            except requests.exceptions.ConnectionError:
                return {"ok": False, "message": f"Cannot reach {host}:{port} - check host/port and that qBittorrent is running"}
            except requests.exceptions.Timeout:
                return {"ok": False, "message": f"Timed out connecting to {host}:{port}"}

            # Step 2: login — persistent session keeps all cookies automatically
            try:
                r = session.post(
                    f"{base}/api/v2/auth/login",
                    data={"username": username, "password": password},
                    headers={"Content-Type": "application/x-www-form-urlencoded"},
                    timeout=8,
                )
            except Exception as e:
                return {"ok": False, "message": f"Login request failed: {e}"}

            body = r.text.strip()
            # Accept: 200 "Ok.", 204 empty (binhex), or any 2xx
            if body == "Fails.":
                return {"ok": False, "message": "Login failed - check username/password"}
            if r.status_code not in (200, 204) and body not in ("Ok.", ""):
                return {"ok": False, "message": f"Unexpected login response (HTTP {r.status_code}): {body[:100]}"}

            # Step 3: use the session (cookies already set) to get version
            try:
                vr = session.get(
                    f"{base}/api/v2/app/version",
                    timeout=5,
                )
                if vr.status_code == 200:
                    return {"ok": True, "message": f"Connected - qBittorrent {vr.text.strip()}"}
                elif vr.status_code == 403:
                    # Banned IP or session not accepted — still connected though
                    return {"ok": True, "message": f"Connected (login OK, but version endpoint returned 403 — check qBittorrent WebUI security settings: disable Host Header Validation)"}
                else:
                    return {"ok": True, "message": f"Connected - qBittorrent (HTTP {vr.status_code} on version check)"}
            except Exception as e:
                return {"ok": True, "message": f"Connected (login OK, version check failed: {e})"}

        try:
            result = await asyncio.wait_for(
                loop.run_in_executor(None, _do_test),
                timeout=15
            )
            return result
        except asyncio.TimeoutError:
            return {"ok": False, "message": f"Connection timed out after 15s"}
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
                result = {"ok": False, "message": "Pi host not configured"}
            else:
                result = await self._qbit_test(
                    host=self.config.get("pi_host", ""),
                    port=int(self.config.get("qbit_b_port", 8080)),
                    username=self.config.get("qbit_b_user", "admin"),
                    password=self.config.get("qbit_b_pass", ""),
                )

        elif target in ("sonarr", "radarr"):
            host_key = f"{target}_host"
            port_key = f"{target}_port"
            key_key = f"{target}_api_key"
            host = self.config.get(host_key)
            port = self.config.get(port_key, 8989 if target == "sonarr" else 7878)
            api_key = self.config.get(key_key, "")
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
                                result = {"ok": True, "message": f"Connected — {target.capitalize()} {body.get('version', '')}"}
                            else:
                                result = {"ok": False, "message": f"HTTP {r.status}"}
                except Exception as e:
                    result = {"ok": False, "message": str(e)}

        return self._json_response(result)

    async def get_logs(self, request):
        limit = int(request.rel_url.query.get("limit", 100))
        level = request.rel_url.query.get("level", "")
        logs = self._log_buffer[-limit:]
        if level:
            logs = [l for l in logs if l["level"] == level.upper()]
        return self._json_response(logs)
