import asyncio
import logging
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional
import qbittorrentapi
import requests as _requests

logger = logging.getLogger("torrentbridge.engine")


def _make_qbit_session(host, port, username, password):
    """
    Create an authenticated requests.Session for qBittorrent.
    Handles both standard (200 Ok.) and binhex (204 empty body + cookie).
    Session jar holds all cookies automatically for subsequent requests.
    """
    from requests.adapters import HTTPAdapter
    base = f"http://{host}:{port}"
    session = _requests.Session()
    session.mount("http://", HTTPAdapter(max_retries=0))
    try:
        r = session.post(
            f"{base}/api/v2/auth/login",
            data={"username": username, "password": password},
            headers={"Content-Type": "application/x-www-form-urlencoded", "Referer": base},
            timeout=10,
        )
        body = r.text.strip()
        if body == "Fails.":
            raise qbittorrentapi.LoginFailed(f"Login failed for {host}:{port}")
        if r.status_code not in (200, 204):
            raise qbittorrentapi.LoginFailed(f"HTTP {r.status_code}: {body[:80]}")
        return session
    except _requests.exceptions.ConnectionError as e:
        raise ConnectionError(f"Cannot reach {host}:{port}") from e
    except _requests.exceptions.Timeout as e:
        raise TimeoutError(f"Timed out connecting to {host}:{port}") from e


class MigrationStage(str, Enum):
    QUEUED = "queued"
    WAITING_IMPORT = "waiting_import"
    TRANSFERRING = "transferring"
    ADDING_TO_SEEDER = "adding_to_seeder"
    VERIFYING = "verifying"
    CLEANING_UP = "cleanup"
    DONE = "done"
    FAILED = "failed"


@dataclass
class MigrationJob:
    torrent_hash: str
    torrent_name: str
    size_bytes: int
    save_path: str
    content_path: str
    stage: MigrationStage = MigrationStage.QUEUED
    progress: float = 0.0
    error: Optional[str] = None
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    transfer_speed: float = 0.0

    def to_dict(self):
        return {
            "hash": self.torrent_hash,
            "name": self.torrent_name,
            "size_bytes": self.size_bytes,
            "save_path": self.save_path,
            "stage": self.stage.value,
            "progress": round(self.progress, 1),
            "error": self.error,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "transfer_speed": self.transfer_speed,
        }


class MigrationEngine:
    def __init__(self, config: dict):
        self.config = config
        self.jobs: dict[str, MigrationJob] = {}
        self._tasks: dict[str, asyncio.Task] = {}          # track running tasks for cancellation
        self.history: list[dict] = []
        self.pending_approval: dict[str, dict] = {}        # hash -> torrent info (UI visibility only)
        self.dismissed_hashes: set = set()                 # user-dismissed hashes
        self._lock = asyncio.Lock()
        self._running = False
        self.stats = {
            "migrated_today": 0,
            "total_migrated": 0,
            "failed": 0,
            "bytes_transferred": 0,
        }

    async def start(self):
        self._running = True
        self._start_time = time.time()
        logger.info("Migration engine started")
        asyncio.create_task(self._watch_loop())
        asyncio.create_task(self._midnight_reset())

    async def stop(self):
        self._running = False

    async def _midnight_reset(self):
        while self._running:
            now = time.localtime()
            seconds_until_midnight = (
                (23 - now.tm_hour) * 3600
                + (59 - now.tm_min) * 60
                + (59 - now.tm_sec)
            )
            await asyncio.sleep(max(seconds_until_midnight, 1))
            self.stats["migrated_today"] = 0

    async def _watch_loop(self):
        while self._running:
            try:
                await self._check_for_completed()
            except Exception as e:
                logger.error(f"Watch loop error: {e}")
            await asyncio.sleep(int(self.config.get("poll_interval", 30)))

    def _required_config_ok(self) -> bool:
        """Return False (and log) if critical config is missing."""
        missing = [k for k in ("qbit_a_host", "pi_host", "qbit_b_user", "qbit_b_pass")
                   if not self.config.get(k)]
        if missing:
            logger.warning(f"Missing required config: {missing} — skipping poll")
            return False
        return True

    async def _check_for_completed(self):
        if not self._required_config_ok():
            return

        cfg = self.config
        loop = asyncio.get_running_loop()
        try:
            def _fetch():
                session = _make_qbit_session(
                    cfg["qbit_a_host"], int(cfg["qbit_a_port"]),
                    cfg["qbit_a_user"], cfg["qbit_a_pass"]
                )
                base = f"http://{cfg['qbit_a_host']}:{int(cfg['qbit_a_port'])}"
                params = {}
                if cfg.get("watch_category", ""):
                    params["category"] = cfg["watch_category"]
                r = session.get(
                    f"{base}/api/v2/torrents/info",
                    params=params,
                    headers={"Referer": base},
                    timeout=10,
                )
                if r.status_code == 403:
                    raise qbittorrentapi.LoginFailed("403 — disable Host Header Validation in qBittorrent")
                r.raise_for_status()
                all_torrents = r.json()
                finished = [
                    t for t in all_torrents
                    if (t.get("progress", 0) >= 1.0
                        or t.get("amount_left", -1) == 0
                        or t.get("state", "") in {
                            "uploading", "stalledUP", "pausedUP", "queuedUP",
                            "forcedUP", "completed", "checkingUP"
                        })
                ]
                logger.debug(f"qBit-A: {len(all_torrents)} total, {len(finished)} finished")
                return finished

            torrents = await asyncio.wait_for(
                loop.run_in_executor(None, _fetch), timeout=20
            )

            migrated_hashes = {h.get("hash", "") for h in self.history}

            for t in torrents:
                thash = t.get("hash", "")
                name = t.get("name", "unknown")

                if (thash in self.jobs
                        or thash in migrated_hashes
                        or thash in self.dismissed_hashes
                        or thash in self.pending_approval):
                    continue

                self.pending_approval[thash] = {
                    "hash": thash,
                    "name": name,
                    "size_bytes": t.get("size", 0),
                    "save_path": t.get("save_path", ""),
                    "content_path": t.get("content_path", t.get("save_path", "")),
                    "state": t.get("state", ""),
                    "category": t.get("category", ""),
                    "added_at": time.time(),
                }
                logger.info(f"Detected: {name} [{thash[:8]}] — queuing for migration")

                async with self._lock:
                    job = MigrationJob(
                        torrent_hash=thash,
                        torrent_name=name,
                        size_bytes=t.get("size", 0),
                        save_path=t.get("save_path", ""),
                        content_path=t.get("content_path", t.get("save_path", "")),
                    )
                    self.jobs[thash] = job
                    task = asyncio.create_task(self._run_migration(job))
                    self._tasks[thash] = task

        except asyncio.TimeoutError:
            logger.warning("qBit-A timed out — is it reachable?")
        except (ConnectionError, TimeoutError) as e:
            logger.error(f"qBit-A unreachable: {e}")
        except qbittorrentapi.LoginFailed as e:
            logger.error(f"qBit-A login failed: {e}")
        except RecursionError:
            logger.error("qBit-A recursion error — check host/port")
        except Exception as e:
            logger.error(f"qBit-A error: {type(e).__name__}: {e}")

    def _update_job(self, job: MigrationJob, stage: MigrationStage,
                    progress: float = None, error: str = None):
        job.stage = stage
        job.updated_at = time.time()
        if progress is not None:
            job.progress = progress
        if error is not None:
            job.error = error
        logger.info(f"[{job.torrent_name[:40]}] → {stage.value} ({job.progress:.0f}%)")

    async def _run_migration(self, job: MigrationJob):
        try:
            self._update_job(job, MigrationStage.WAITING_IMPORT, 5.0)
            await self._wait_for_arr_import(job)

            self._update_job(job, MigrationStage.TRANSFERRING, 10.0)
            await self._pause_on_source(job)

            await self._rsync_to_pi(job)

            self._update_job(job, MigrationStage.ADDING_TO_SEEDER, 85.0)
            await self._add_to_seeder(job)

            self._update_job(job, MigrationStage.VERIFYING, 90.0)
            await self._wait_for_recheck(job)

            self._update_job(job, MigrationStage.CLEANING_UP, 98.0)
            await self._delete_from_source(job)

            self._update_job(job, MigrationStage.DONE, 100.0)
            self.stats["migrated_today"] += 1
            self.stats["total_migrated"] += 1
            self.stats["bytes_transferred"] += job.size_bytes

            finished = job.to_dict()
            finished["finished_at"] = time.time()
            self.history.insert(0, finished)
            if len(self.history) > 200:
                self.history = self.history[:200]

            # Clean up pending entry now that migration is done
            self.pending_approval.pop(job.torrent_hash, None)

            await asyncio.sleep(30)
            async with self._lock:
                self.jobs.pop(job.torrent_hash, None)
                self._tasks.pop(job.torrent_hash, None)

        except asyncio.CancelledError:
            logger.info(f"Migration cancelled: {job.torrent_name}")
            self._update_job(job, MigrationStage.FAILED, error="Cancelled")
            self.pending_approval.pop(job.torrent_hash, None)
        except Exception as e:
            logger.exception(f"Migration failed for {job.torrent_name}: {e}")
            self._update_job(job, MigrationStage.FAILED, error=str(e))
            self.stats["failed"] += 1
            # Keep in pending so user can see it failed and retry
            if job.torrent_hash in self.pending_approval:
                self.pending_approval[job.torrent_hash]["failed"] = True

    async def _wait_for_arr_import(self, job: MigrationJob):
        cfg = self.config
        delay = int(cfg.get("post_download_delay", 60))

        arr_endpoints = []
        if cfg.get("sonarr_host"):
            arr_endpoints.append(("Sonarr", cfg["sonarr_host"],
                                  int(cfg.get("sonarr_port", 8989)), cfg.get("sonarr_api_key", "")))
        if cfg.get("radarr_host"):
            arr_endpoints.append(("Radarr", cfg["radarr_host"],
                                  int(cfg.get("radarr_port", 7878)), cfg.get("radarr_api_key", "")))

        if not arr_endpoints:
            if delay > 0:
                logger.info(f"No media manager — waiting {delay}s before migrating...")
                await asyncio.sleep(delay)
            else:
                logger.info("No media manager — migrating immediately")
            return

        deadline = time.time() + max(delay, 300)
        while time.time() < deadline:
            for name, host, port, key in arr_endpoints:
                try:
                    import aiohttp
                    url = f"http://{host}:{port}/api/v3/queue?apiKey={key}&pageSize=100"
                    async with aiohttp.ClientSession() as session:
                        async with session.get(url, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                            if resp.status == 200:
                                data = await resp.json()
                                hashes_in_queue = [
                                    r.get("downloadId", "").lower()
                                    for r in data.get("records", [])
                                ]
                                if job.torrent_hash.lower() not in hashes_in_queue:
                                    logger.info(f"{name} import confirmed: {job.torrent_name}")
                                    return
                except Exception as e:
                    logger.warning(f"Error polling {name}: {e}")
            await asyncio.sleep(15)

        logger.warning(f"Arr import poll timed out for {job.torrent_name}, proceeding anyway")

    def _a_base(self):
        cfg = self.config
        return f"http://{cfg['qbit_a_host']}:{int(cfg['qbit_a_port'])}"

    def _b_base(self):
        cfg = self.config
        return f"http://{cfg['pi_host']}:{int(cfg.get('qbit_b_port', 8080))}"

    def _a_session(self):
        cfg = self.config
        return _make_qbit_session(cfg["qbit_a_host"], int(cfg["qbit_a_port"]),
                                  cfg["qbit_a_user"], cfg["qbit_a_pass"])

    def _b_session(self):
        cfg = self.config
        return _make_qbit_session(cfg["pi_host"], int(cfg.get("qbit_b_port", 8080)),
                                  cfg["qbit_b_user"], cfg["qbit_b_pass"])

    async def _pause_on_source(self, job: MigrationJob):
        loop = asyncio.get_running_loop()
        def _pause():
            s, base = self._a_session(), self._a_base()
            s.post(f"{base}/api/v2/torrents/pause",
                   data={"hashes": job.torrent_hash},
                   headers={"Referer": base}, timeout=10)
            s.post(f"{base}/api/v2/torrents/addTags",
                   data={"hashes": job.torrent_hash, "tags": "migrating"},
                   headers={"Referer": base}, timeout=10)
        await loop.run_in_executor(None, _pause)
        await asyncio.sleep(3)

    async def _rsync_to_pi(self, job: MigrationJob):
        import os
        cfg = self.config
        pi_user    = cfg["pi_user"]
        pi_host    = cfg["pi_host"]
        pi_root    = cfg["pi_seed_root"]
        ssh_key    = cfg.get("ssh_key_path", "/root/.ssh/id_migrate")
        bwlimit    = int(cfg.get("bwlimit_kbps", 0))

        dest_dir = os.path.join(pi_root, os.path.basename(job.save_path)) + "/"
        source   = job.content_path
        if os.path.isdir(source):
            source = source.rstrip("/") + "/"

        cmd = [
            "rsync", "-avz", "--progress", "--checksum",
            "--partial-dir=.rsync-partial",
            "-e", f"ssh -i {ssh_key} -o StrictHostKeyChecking=no -o ConnectTimeout=10",
        ]
        if bwlimit:
            cmd += [f"--bwlimit={bwlimit}"]
        cmd += [source, f"{pi_user}@{pi_host}:{dest_dir}"]

        logger.info(f"rsync: {source} → {pi_user}@{pi_host}:{dest_dir}")

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        start_time = time.time()

        async def read_stdout():
            async for line in process.stdout:
                decoded = line.decode("utf-8", errors="replace").strip()
                if "%" in decoded:
                    for p in decoded.split():
                        if p.endswith("%"):
                            try:
                                pct = float(p.rstrip("%"))
                                job.progress = 10.0 + (pct * 0.75)
                                job.updated_at = time.time()
                            except ValueError:
                                pass
                        if "MB/s" in p or "kB/s" in p:
                            try:
                                speed = float(p.replace("MB/s","").replace("kB/s",""))
                                job.transfer_speed = speed * (1 if "MB/s" in p else 0.001)
                            except ValueError:
                                pass

        async def drain_stderr():
            return await process.stderr.read()

        _, stderr_data, _ = await asyncio.gather(
            read_stdout(), drain_stderr(), process.wait()
        )

        job.transfer_speed = 0.0
        if process.returncode != 0:
            raise RuntimeError(f"rsync failed (code {process.returncode}): {stderr_data.decode()[:500]}")

        elapsed = time.time() - start_time
        speed_mbps = (job.size_bytes / elapsed / 1_000_000) if elapsed > 0 else 0
        logger.info(f"rsync complete in {elapsed:.0f}s at {speed_mbps:.1f} MB/s")

    async def _add_to_seeder(self, job: MigrationJob):
        import os
        cfg = self.config
        fastresume_dir = cfg.get("qbit_a_fastresume_dir", "/config/qBittorrent/data/BT_backup")
        torrent_file   = os.path.join(fastresume_dir, f"{job.torrent_hash}.torrent")

        if not os.path.exists(torrent_file):
            raise FileNotFoundError(f".torrent file not found: {torrent_file}")

        dest_dir = os.path.join(cfg["pi_seed_root"], os.path.basename(job.save_path))
        loop = asyncio.get_running_loop()

        def _add():
            s, base = self._b_session(), self._b_base()
            with open(torrent_file, "rb") as fh:
                torrent_data = fh.read()
            resp = s.post(
                f"{base}/api/v2/torrents/add",
                files={"torrents": (f"{job.torrent_hash}.torrent", torrent_data,
                                    "application/x-bittorrent")},
                data={
                    "savepath": dest_dir,
                    "category": cfg.get("seed_category", "seeding"),
                    "paused":   "true",
                    "autoTMM":  "false",
                },
                headers={"Referer": base},
                timeout=30,
            )
            result = resp.text.strip()
            if result not in ("Ok.", "Duplicate torrent!"):
                logger.warning(f"Add torrent response: {result[:100]}")

        await loop.run_in_executor(None, _add)
        await asyncio.sleep(5)

    async def _wait_for_recheck(self, job: MigrationJob):
        cfg     = self.config
        timeout = int(cfg.get("recheck_timeout", 300))
        deadline = time.time() + timeout
        loop    = asyncio.get_running_loop()
        seeding_states = {"uploading", "stalledUP", "pausedUP", "queuedUP", "forcedUP"}

        # Trigger recheck — one session, one login
        def _recheck():
            s, base = self._b_session(), self._b_base()
            s.post(f"{base}/api/v2/torrents/recheck",
                   data={"hashes": job.torrent_hash},
                   headers={"Referer": base}, timeout=10)
            return s  # reuse session for polling

        session = await loop.run_in_executor(None, _recheck)

        while time.time() < deadline:
            def _check(s=session):
                base = self._b_base()
                r = s.get(f"{base}/api/v2/torrents/info",
                          params={"hashes": job.torrent_hash},
                          headers={"Referer": base}, timeout=10)
                data = r.json()
                return data[0] if data else None

            t = await loop.run_in_executor(None, _check)
            if t:
                state = t.get("state", "")
                if state in seeding_states:
                    logger.info(f"Recheck passed — state: {state}")
                    def _resume(s=session):
                        base = self._b_base()
                        s.post(f"{base}/api/v2/torrents/resume",
                               data={"hashes": job.torrent_hash},
                               headers={"Referer": base}, timeout=10)
                    await loop.run_in_executor(None, _resume)
                    return
                elif "error" in state.lower():
                    raise RuntimeError(f"Recheck error state on seeder: {state}")
                logger.debug(f"Recheck in progress — state: {state}")
            await asyncio.sleep(10)

        raise TimeoutError(f"Recheck timed out after {timeout}s")

    async def _delete_from_source(self, job: MigrationJob):
        loop = asyncio.get_running_loop()
        def _delete():
            s, base = self._a_session(), self._a_base()
            s.post(f"{base}/api/v2/torrents/delete",
                   data={"hashes": job.torrent_hash, "deleteFiles": "true"},
                   headers={"Referer": base}, timeout=10)
        await loop.run_in_executor(None, _delete)
        logger.info(f"Deleted from qBit-A: {job.torrent_name}")

    def cancel_job(self, torrent_hash: str):
        """Cancel a running migration task cleanly."""
        task = self._tasks.pop(torrent_hash, None)
        if task and not task.done():
            task.cancel()
        self.jobs.pop(torrent_hash, None)
        self.pending_approval.pop(torrent_hash, None)

    def get_status(self) -> dict:
        active = [j.to_dict() for j in self.jobs.values() if j.stage != MigrationStage.DONE]
        return {
            "running": self._running,
            "active_jobs": active,
            "history": self.history[:50],
            "stats": self.stats,
        }
