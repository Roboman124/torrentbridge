import asyncio
import logging
import os
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional
import qbittorrentapi
import requests as _requests

logger = logging.getLogger("torrentbridge.engine")


def _make_qbit_session(host, port, username, password):
    """Authenticated requests.Session — handles both 200 Ok. and binhex 204."""
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
    QUEUED          = "queued"
    WAITING_IMPORT  = "waiting_import"
    TRANSFERRING    = "transferring"
    ADDING_TO_SEEDER= "adding_to_seeder"
    VERIFYING       = "verifying"
    CLEANING_UP     = "cleanup"
    DONE            = "done"
    FAILED          = "failed"


@dataclass
class MigrationJob:
    torrent_hash:  str
    torrent_name:  str
    size_bytes:    int
    save_path:     str
    content_path:  str
    stage:         MigrationStage = MigrationStage.QUEUED
    progress:      float = 0.0
    error:         Optional[str] = None
    status_msg:    str = ""          # human-readable status shown in UI
    created_at:    float = field(default_factory=time.time)
    updated_at:    float = field(default_factory=time.time)
    transfer_speed:float = 0.0
    skip_wait:     bool = False      # set True by "Migrate Now" to skip delay

    def to_dict(self):
        return {
            "hash":           self.torrent_hash,
            "name":           self.torrent_name,
            "size_bytes":     self.size_bytes,
            "save_path":      self.save_path,
            "content_path":   self.content_path,
            "stage":          self.stage.value,
            "progress":       round(self.progress, 1),
            "error":          self.error,
            "status_msg":     self.status_msg,
            "created_at":     self.created_at,
            "updated_at":     self.updated_at,
            "transfer_speed": self.transfer_speed,
        }


class MigrationEngine:
    def __init__(self, config: dict):
        self.config = config
        self.jobs:            dict[str, MigrationJob] = {}
        self._tasks:          dict[str, asyncio.Task] = {}
        self.history:         list[dict] = []
        self.pending_approval:dict[str, dict] = {}
        self.dismissed_hashes:set = set()
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
            secs = ((23-now.tm_hour)*3600 + (59-now.tm_min)*60 + (59-now.tm_sec))
            await asyncio.sleep(max(secs, 1))
            self.stats["migrated_today"] = 0

    async def _watch_loop(self):
        while self._running:
            try:
                await self._check_for_completed()
            except Exception as e:
                logger.error(f"Watch loop error: {e}")
            await asyncio.sleep(int(self.config.get("poll_interval", 30)))

    def _required_config_ok(self) -> bool:
        missing = [k for k in ("qbit_a_host", "pi_host", "qbit_b_user", "qbit_b_pass")
                   if not self.config.get(k)]
        if missing:
            logger.warning(f"Missing required config: {missing} — skipping poll")
            return False
        return True

    async def _check_for_completed(self):
        if not self._required_config_ok():
            return

        cfg  = self.config
        loop = asyncio.get_running_loop()
        try:
            def _fetch():
                session = _make_qbit_session(
                    cfg["qbit_a_host"], int(cfg["qbit_a_port"]),
                    cfg["qbit_a_user"], cfg["qbit_a_pass"]
                )
                base   = f"http://{cfg['qbit_a_host']}:{int(cfg['qbit_a_port'])}"
                params = {}
                if cfg.get("watch_category", ""):
                    params["category"] = cfg["watch_category"]
                r = session.get(f"{base}/api/v2/torrents/info",
                                params=params, headers={"Referer": base}, timeout=10)
                if r.status_code == 403:
                    raise qbittorrentapi.LoginFailed("403 — disable Host Header Validation")
                r.raise_for_status()
                all_t = r.json()
                done  = [t for t in all_t
                         if (t.get("progress", 0) >= 1.0
                             or t.get("amount_left", -1) == 0
                             or t.get("state","") in {
                                 "uploading","stalledUP","pausedUP","queuedUP",
                                 "forcedUP","completed","checkingUP"})]
                logger.debug(f"qBit-A: {len(all_t)} total, {len(done)} finished")
                return done

            torrents = await asyncio.wait_for(loop.run_in_executor(None, _fetch), timeout=20)
            migrated = {h.get("hash","") for h in self.history}

            for t in torrents:
                thash = t.get("hash","")
                name  = t.get("name","unknown")
                if (thash in self.jobs or thash in migrated
                        or thash in self.dismissed_hashes
                        or thash in self.pending_approval):
                    continue

                self.pending_approval[thash] = {
                    "hash":         thash,
                    "name":         name,
                    "size_bytes":   t.get("size", 0),
                    "save_path":    t.get("save_path",""),
                    "content_path": t.get("content_path", t.get("save_path","")),
                    "state":        t.get("state",""),
                    "category":     t.get("category",""),
                    "added_at":     time.time(),
                }
                logger.info(f"Detected: {name} [{thash[:8]}] "
                            f"save_path={t.get('save_path','')} "
                            f"content_path={t.get('content_path','')}")

                async with self._lock:
                    job = MigrationJob(
                        torrent_hash=thash, torrent_name=name,
                        size_bytes=t.get("size",0),
                        save_path=t.get("save_path",""),
                        content_path=t.get("content_path", t.get("save_path","")),
                    )
                    self.jobs[thash] = job
                    task = asyncio.create_task(self._run_migration(job))
                    self._tasks[thash] = task

        except asyncio.TimeoutError:
            logger.warning("qBit-A timed out")
        except (ConnectionError, TimeoutError) as e:
            logger.error(f"qBit-A unreachable: {e}")
        except qbittorrentapi.LoginFailed as e:
            logger.error(f"qBit-A login failed: {e}")
        except RecursionError:
            logger.error("qBit-A recursion error — check host/port")
        except Exception as e:
            logger.error(f"qBit-A error: {type(e).__name__}: {e}")

    def _update_job(self, job: MigrationJob, stage: MigrationStage,
                    progress: float = None, msg: str = ""):
        job.stage      = stage
        job.updated_at = time.time()
        if progress is not None:
            job.progress = progress
        if msg:
            job.status_msg = msg
        logger.info(f"[{job.torrent_name[:45]}] {stage.value} ({job.progress:.0f}%) — {msg or stage.value}")

    async def _run_migration(self, job: MigrationJob):
        try:
            self._update_job(job, MigrationStage.WAITING_IMPORT, 5.0,
                             "Waiting for media manager import…")
            await self._wait_for_arr_import(job)

            self._update_job(job, MigrationStage.TRANSFERRING, 10.0,
                             "Pausing torrent on downloader…")
            await self._pause_on_source(job)

            self._update_job(job, MigrationStage.TRANSFERRING, 12.0,
                             "Starting rsync transfer to seeder…")
            await self._rsync_to_pi(job)

            self._update_job(job, MigrationStage.ADDING_TO_SEEDER, 85.0,
                             "Adding torrent to seeder…")
            await self._add_to_seeder(job)

            self._update_job(job, MigrationStage.VERIFYING, 90.0,
                             "Verifying data integrity on seeder…")
            await self._wait_for_recheck(job)

            self._update_job(job, MigrationStage.CLEANING_UP, 98.0,
                             "Deleting from downloader…")
            await self._delete_from_source(job)

            self._update_job(job, MigrationStage.DONE, 100.0, "Migration complete")
            self.stats["migrated_today"]  += 1
            self.stats["total_migrated"]  += 1
            self.stats["bytes_transferred"] += job.size_bytes

            finished = job.to_dict()
            finished["finished_at"] = time.time()
            self.history.insert(0, finished)
            if len(self.history) > 200:
                self.history = self.history[:200]

            self.pending_approval.pop(job.torrent_hash, None)

            await asyncio.sleep(30)
            async with self._lock:
                self.jobs.pop(job.torrent_hash, None)
                self._tasks.pop(job.torrent_hash, None)

        except asyncio.CancelledError:
            logger.info(f"Migration cancelled: {job.torrent_name}")
            self._update_job(job, MigrationStage.FAILED, msg="Cancelled by user")
            self.pending_approval.pop(job.torrent_hash, None)
        except Exception as e:
            logger.exception(f"Migration failed for {job.torrent_name}: {e}")
            self._update_job(job, MigrationStage.FAILED, msg=str(e)[:200])
            self.stats["failed"] += 1
            if job.torrent_hash in self.pending_approval:
                self.pending_approval[job.torrent_hash]["failed"] = True

    async def _wait_for_arr_import(self, job: MigrationJob):
        cfg   = self.config
        delay = int(cfg.get("post_download_delay", 60))

        # "Migrate Now" sets skip_wait=True to bypass this entirely
        if job.skip_wait:
            logger.info(f"Skipping import wait (manually triggered): {job.torrent_name}")
            return

        arr_endpoints = []
        if cfg.get("sonarr_host"):
            arr_endpoints.append(("Sonarr", cfg["sonarr_host"],
                                  int(cfg.get("sonarr_port", 8989)),
                                  cfg.get("sonarr_api_key","")))
        if cfg.get("radarr_host"):
            arr_endpoints.append(("Radarr", cfg["radarr_host"],
                                  int(cfg.get("radarr_port", 7878)),
                                  cfg.get("radarr_api_key","")))

        if not arr_endpoints:
            if delay > 0:
                logger.info(f"Waiting {delay}s before migrating {job.torrent_name}…")
                # Sleep in 1s chunks so skip_wait can interrupt
                for _ in range(delay):
                    if job.skip_wait:
                        logger.info("Wait skipped by user")
                        return
                    await asyncio.sleep(1)
            return

        deadline = time.time() + max(delay, 300)
        while time.time() < deadline:
            if job.skip_wait:
                logger.info(f"Import wait skipped by user: {job.torrent_name}")
                return
            for arr_name, host, port, key in arr_endpoints:
                try:
                    import aiohttp
                    url = f"http://{host}:{port}/api/v3/queue?apiKey={key}&pageSize=100"
                    async with aiohttp.ClientSession() as sess:
                        async with sess.get(url, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                            if resp.status == 200:
                                data = await resp.json()
                                in_queue = [r.get("downloadId","").lower()
                                            for r in data.get("records",[])]
                                if job.torrent_hash.lower() not in in_queue:
                                    logger.info(f"{arr_name} import confirmed: {job.torrent_name}")
                                    return
                                job.status_msg = f"Waiting for {arr_name} to import…"
                except Exception as e:
                    logger.warning(f"Error polling {arr_name}: {e}")
            await asyncio.sleep(15)

        logger.warning(f"Import wait timed out — proceeding: {job.torrent_name}")

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _a_base(self):
        cfg = self.config
        return f"http://{cfg['qbit_a_host']}:{int(cfg['qbit_a_port'])}"

    def _b_base(self):
        cfg = self.config
        return f"http://{cfg['pi_host']}:{int(cfg.get('qbit_b_port',8080))}"

    def _a_session(self):
        cfg = self.config
        return _make_qbit_session(cfg["qbit_a_host"], int(cfg["qbit_a_port"]),
                                  cfg["qbit_a_user"], cfg["qbit_a_pass"])

    def _b_session(self):
        cfg = self.config
        return _make_qbit_session(cfg["pi_host"], int(cfg.get("qbit_b_port",8080)),
                                  cfg["qbit_b_user"], cfg["qbit_b_pass"])

    def _remap_path(self, path: str) -> str:
        """Map qBittorrent's internal Docker path to the real host path."""
        qbit_prefix = self.config.get("qbit_path_prefix","").rstrip("/")
        host_prefix = self.config.get("host_path_prefix","").rstrip("/")
        if qbit_prefix and host_prefix and path.startswith(qbit_prefix):
            remapped = host_prefix + path[len(qbit_prefix):]
            logger.debug(f"Path remap: {path} → {remapped}")
            return remapped
        return path

    def _find_source_path(self, job: MigrationJob) -> str:
        """
        Resolve the actual on-disk path for the torrent content.
        Tries remapped path first, then original, then searches subdirectories.
        Logs everything so users can diagnose path mapping issues.
        """
        candidates = []

        # 1. Remapped content_path
        remapped_content = self._remap_path(job.content_path)
        if remapped_content != job.content_path:
            candidates.append(remapped_content)

        # 2. Original content_path (in case no remapping configured)
        candidates.append(job.content_path)

        # 3. Remapped save_path + torrent name
        remapped_save = self._remap_path(job.save_path)
        candidates.append(os.path.join(remapped_save, job.torrent_name))
        candidates.append(os.path.join(job.save_path, job.torrent_name))

        logger.info(f"Looking for source paths:")
        logger.info(f"  qBit reported save_path:    {job.save_path}")
        logger.info(f"  qBit reported content_path: {job.content_path}")
        logger.info(f"  After remapping:")
        logger.info(f"    save_path:    {remapped_save}")
        logger.info(f"    content_path: {remapped_content}")

        for path in candidates:
            if os.path.exists(path):
                logger.info(f"  ✓ Found at: {path}")
                return path
            else:
                logger.info(f"  ✗ Not found: {path}")

        # Nothing found — give a helpful error
        qbit_prefix = self.config.get("qbit_path_prefix","")
        host_prefix = self.config.get("host_path_prefix","")
        hint = ""
        if not qbit_prefix:
            hint = (f"\n\nHint: qBittorrent is reporting path '{job.content_path}'. "
                    f"If it's inside a Docker container, set:\n"
                    f"  qBit Path Prefix = {os.path.dirname(job.content_path) or job.save_path}\n"
                    f"  Host Path Prefix = <actual host path to your downloads folder>")
        else:
            hint = (f"\n\nCurrent mapping: '{qbit_prefix}' → '{host_prefix}'\n"
                    f"Tried: {candidates}")

        raise FileNotFoundError(
            f"Cannot find source data for '{job.torrent_name}'.{hint}"
        )

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
        cfg      = self.config
        pi_user  = cfg["pi_user"]
        pi_host  = cfg["pi_host"]
        pi_root  = cfg["pi_seed_root"]
        ssh_key  = cfg.get("ssh_key_path", "/root/.ssh/id_migrate")
        bwlimit  = int(cfg.get("bwlimit_kbps", 0))

        # Resolve actual source path
        source = self._find_source_path(job)

        # Use remapped save_path for dest structure
        remapped_save = self._remap_path(job.save_path)
        dest_dir = os.path.join(pi_root, os.path.basename(remapped_save)) + "/"

        if os.path.isdir(source):
            source = source.rstrip("/") + "/"

        job.status_msg = f"Transferring to seeder ({os.path.basename(source)})…"
        logger.info(f"rsync: {source} → {pi_user}@{pi_host}:{dest_dir}")

        # Pre-create destination directory on Pi
        loop = asyncio.get_running_loop()
        def _mkdir():
            import subprocess
            r = subprocess.run(
                ["ssh", "-i", ssh_key, "-o", "StrictHostKeyChecking=no",
                 f"{pi_user}@{pi_host}", f"mkdir -p '{dest_dir.rstrip('/')}'"],
                capture_output=True, timeout=15
            )
            if r.returncode != 0:
                logger.warning(f"mkdir on Pi returned {r.returncode}: {r.stderr.decode()[:150]}")
        await loop.run_in_executor(None, _mkdir)

        cmd = [
            "rsync", "-avz", "--progress", "--checksum",
            "--partial-dir=.rsync-partial",
            "-e", f"ssh -i {ssh_key} -o StrictHostKeyChecking=no -o ConnectTimeout=10",
        ]
        if bwlimit:
            cmd += [f"--bwlimit={bwlimit}"]
        cmd += [source, f"{pi_user}@{pi_host}:{dest_dir}"]

        process = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        start = time.time()

        async def read_stdout():
            async for line in process.stdout:
                d = line.decode("utf-8", errors="replace").strip()
                if "%" in d:
                    for p in d.split():
                        if p.endswith("%"):
                            try:
                                pct = float(p.rstrip("%"))
                                job.progress   = 12.0 + (pct * 0.73)
                                job.updated_at = time.time()
                                job.status_msg = f"Transferring… {pct:.0f}%"
                            except ValueError:
                                pass
                        if "MB/s" in p or "kB/s" in p:
                            try:
                                spd = float(p.replace("MB/s","").replace("kB/s",""))
                                job.transfer_speed = spd * (1 if "MB/s" in p else 0.001)
                            except ValueError:
                                pass

        async def drain_stderr():
            return await process.stderr.read()

        _, stderr_data, _ = await asyncio.gather(read_stdout(), drain_stderr(), process.wait())

        job.transfer_speed = 0.0
        if process.returncode != 0:
            raise RuntimeError(
                f"rsync failed (code {process.returncode}): {stderr_data.decode()[:500]}")

        elapsed = time.time() - start
        mbps    = (job.size_bytes / elapsed / 1_000_000) if elapsed > 0 else 0
        logger.info(f"rsync complete in {elapsed:.0f}s at {mbps:.1f} MB/s")

    async def _add_to_seeder(self, job: MigrationJob):
        cfg            = self.config
        fastresume_dir = cfg.get("qbit_a_fastresume_dir", "/config/qBittorrent/data/BT_backup")
        torrent_file   = os.path.join(fastresume_dir, f"{job.torrent_hash}.torrent")

        if not os.path.exists(torrent_file):
            raise FileNotFoundError(f".torrent file not found: {torrent_file}")

        remapped_save = self._remap_path(job.save_path)
        dest_dir = os.path.join(cfg["pi_seed_root"], os.path.basename(remapped_save))
        loop     = asyncio.get_running_loop()

        def _add():
            s, base = self._b_session(), self._b_base()
            with open(torrent_file, "rb") as fh:
                data = fh.read()
            resp = s.post(
                f"{base}/api/v2/torrents/add",
                files={"torrents": (f"{job.torrent_hash}.torrent", data,
                                    "application/x-bittorrent")},
                data={"savepath": dest_dir,
                      "category": cfg.get("seed_category","seeding"),
                      "paused":   "true", "autoTMM": "false"},
                headers={"Referer": base}, timeout=30,
            )
            result = resp.text.strip()
            if result not in ("Ok.", "Duplicate torrent!"):
                logger.warning(f"Add torrent response: {result[:100]}")

        await loop.run_in_executor(None, _add)
        await asyncio.sleep(5)

    async def _wait_for_recheck(self, job: MigrationJob):
        cfg      = self.config
        timeout  = int(cfg.get("recheck_timeout", 300))
        deadline = time.time() + timeout
        loop     = asyncio.get_running_loop()
        seeding  = {"uploading","stalledUP","pausedUP","queuedUP","forcedUP"}

        def _recheck():
            s, base = self._b_session(), self._b_base()
            s.post(f"{base}/api/v2/torrents/recheck",
                   data={"hashes": job.torrent_hash},
                   headers={"Referer": base}, timeout=10)
            return s  # reuse session

        session = await loop.run_in_executor(None, _recheck)

        while time.time() < deadline:
            def _check(s=session):
                base = self._b_base()
                r    = s.get(f"{base}/api/v2/torrents/info",
                             params={"hashes": job.torrent_hash},
                             headers={"Referer": base}, timeout=10)
                d = r.json()
                return d[0] if d else None

            t = await loop.run_in_executor(None, _check)
            if t:
                state = t.get("state","")
                pct   = t.get("progress", 0) * 100
                job.status_msg = f"Verifying on seeder… {pct:.0f}% ({state})"
                if state in seeding:
                    logger.info(f"Recheck passed — state: {state}")
                    def _resume(s=session):
                        base = self._b_base()
                        s.post(f"{base}/api/v2/torrents/resume",
                               data={"hashes": job.torrent_hash},
                               headers={"Referer": base}, timeout=10)
                    await loop.run_in_executor(None, _resume)
                    return
                elif "error" in state.lower():
                    raise RuntimeError(f"Recheck error on seeder: {state}")
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
        logger.info(f"Deleted from downloader: {job.torrent_name}")

    def cancel_job(self, torrent_hash: str):
        task = self._tasks.pop(torrent_hash, None)
        if task and not task.done():
            task.cancel()
        self.jobs.pop(torrent_hash, None)
        self.pending_approval.pop(torrent_hash, None)

    def get_status(self) -> dict:
        active = [j.to_dict() for j in self.jobs.values() if j.stage != MigrationStage.DONE]
        return {"running": self._running, "active_jobs": active,
                "history": self.history[:50], "stats": self.stats}
