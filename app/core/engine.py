import asyncio
import logging
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional
import qbittorrentapi

logger = logging.getLogger("torrentbridge.engine")


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
        self.history: list[dict] = []
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
        logger.info("Migration engine started")
        asyncio.create_task(self._watch_loop())
        asyncio.create_task(self._midnight_reset())

    async def stop(self):
        self._running = False

    async def _midnight_reset(self):
        """Reset daily counters at midnight."""
        while self._running:
            now = time.localtime()
            seconds_until_midnight = (
                (23 - now.tm_hour) * 3600
                + (59 - now.tm_min) * 60
                + (60 - now.tm_sec)
            )
            await asyncio.sleep(seconds_until_midnight)
            self.stats["migrated_today"] = 0

    async def _watch_loop(self):
        """Poll qBit-A for completed downloads."""
        while self._running:
            try:
                await self._check_for_completed()
            except Exception as e:
                logger.error(f"Watch loop error: {e}")
            await asyncio.sleep(self.config.get("poll_interval", 30))

    async def _check_for_completed(self):
        cfg = self.config
        try:
            with qbittorrentapi.Client(
                host=cfg["qbit_a_host"],
                port=cfg["qbit_a_port"],
                username=cfg["qbit_a_user"],
                password=cfg["qbit_a_pass"],
                REQUESTS_ARGS={"timeout": 10},
                HTTPADAPTER_ARGS={"max_retries": 0},
            ) as qba:
                torrents = qba.torrents_info(
                    status_filter="completed",
                    category=cfg.get("watch_category", ""),
                )
                for t in torrents:
                    if t.hash not in self.jobs:
                        # Skip already-processing or recently-failed
                        async with self._lock:
                            logger.info(f"New completed torrent: {t.name} [{t.hash[:8]}]")
                            job = MigrationJob(
                                torrent_hash=t.hash,
                                torrent_name=t.name,
                                size_bytes=t.size,
                                save_path=t.save_path,
                                content_path=t.content_path,
                            )
                            self.jobs[t.hash] = job
                            asyncio.create_task(self._run_migration(job))
        except qbittorrentapi.LoginFailed:
            logger.error("qBit-A login failed — check credentials in config")
        except Exception as e:
            logger.error(f"Error connecting to qBit-A: {e}")

    def _update_job(self, job: MigrationJob, stage: MigrationStage, progress: float = None, error: str = None):
        job.stage = stage
        job.updated_at = time.time()
        if progress is not None:
            job.progress = progress
        if error is not None:
            job.error = error
        logger.info(f"[{job.torrent_name[:40]}] → {stage.value} ({job.progress:.0f}%)")

    async def _run_migration(self, job: MigrationJob):
        cfg = self.config
        try:
            # Stage 1: Wait for Arr import confirmation
            self._update_job(job, MigrationStage.WAITING_IMPORT, 5.0)
            await self._wait_for_arr_import(job)

            # Stage 2: Pause torrent on qBit-A
            self._update_job(job, MigrationStage.TRANSFERRING, 10.0)
            await self._pause_on_source(job)

            # Stage 3: rsync data to Pi
            await self._rsync_to_pi(job)

            # Stage 4: Add torrent to qBit-B
            self._update_job(job, MigrationStage.ADDING_TO_SEEDER, 85.0)
            await self._add_to_seeder(job)

            # Stage 5: Force recheck on Pi
            self._update_job(job, MigrationStage.VERIFYING, 90.0)
            await self._wait_for_recheck(job)

            # Stage 6: Delete from qBit-A
            self._update_job(job, MigrationStage.CLEANING_UP, 98.0)
            await self._delete_from_source(job)

            # Done
            self._update_job(job, MigrationStage.DONE, 100.0)
            self.stats["migrated_today"] += 1
            self.stats["total_migrated"] += 1
            self.stats["bytes_transferred"] += job.size_bytes

            # Archive to history
            finished = job.to_dict()
            finished["finished_at"] = time.time()
            self.history.insert(0, finished)
            if len(self.history) > 200:
                self.history = self.history[:200]

            # Remove from active jobs after a delay so UI can show completion
            await asyncio.sleep(30)
            async with self._lock:
                self.jobs.pop(job.torrent_hash, None)

        except Exception as e:
            logger.exception(f"Migration failed for {job.torrent_name}: {e}")
            self._update_job(job, MigrationStage.FAILED, error=str(e))
            self.stats["failed"] += 1

    async def _wait_for_arr_import(self, job: MigrationJob):
        """Poll Sonarr/Radarr until import is confirmed, or fall back to timed delay."""
        cfg = self.config
        delay = cfg.get("post_download_delay", 60)

        arr_endpoints = []
        if cfg.get("sonarr_host"):
            arr_endpoints.append(("Sonarr", cfg["sonarr_host"], cfg.get("sonarr_port", 8989), cfg.get("sonarr_api_key", "")))
        if cfg.get("radarr_host"):
            arr_endpoints.append(("Radarr", cfg["radarr_host"], cfg.get("radarr_port", 7878), cfg.get("radarr_api_key", "")))

        if not arr_endpoints:
            logger.info(f"No Arr apps configured, waiting {delay}s fixed delay...")
            await asyncio.sleep(delay)
            return

        # Poll Arr queue to confirm item is no longer queued (= imported)
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
                                records = data.get("records", [])
                                hashes_in_queue = [
                                    r.get("downloadId", "").lower()
                                    for r in records
                                ]
                                if job.torrent_hash.lower() not in hashes_in_queue:
                                    logger.info(f"{name} import confirmed for {job.torrent_name}")
                                    return
                except Exception as e:
                    logger.warning(f"Error polling {name}: {e}")
            await asyncio.sleep(15)

        logger.warning(f"Arr import poll timed out for {job.torrent_name}, proceeding anyway")

    async def _pause_on_source(self, job: MigrationJob):
        cfg = self.config
        loop = asyncio.get_event_loop()
        def _pause():
            with qbittorrentapi.Client(
                host=cfg["qbit_a_host"], port=cfg["qbit_a_port"],
                username=cfg["qbit_a_user"], password=cfg["qbit_a_pass"],
            ) as qba:
                qba.torrents_pause(torrent_hashes=job.torrent_hash)
                qba.torrents_add_tags(tags="migrating", torrent_hashes=job.torrent_hash)
        await loop.run_in_executor(None, _pause)
        await asyncio.sleep(3)

    async def _rsync_to_pi(self, job: MigrationJob):
        cfg = self.config
        import os
        import subprocess

        pi_user = cfg["pi_user"]
        pi_host = cfg["pi_host"]
        pi_root = cfg["pi_seed_root"]
        ssh_key = cfg.get("ssh_key_path", "/root/.ssh/id_migrate")
        bwlimit = cfg.get("bwlimit_kbps", 0)  # 0 = unlimited

        # Preserve relative directory structure under save_path
        dest_dir = os.path.join(pi_root, os.path.basename(job.save_path)) + "/"
        source = job.content_path
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
        bytes_done = 0

        async def read_progress():
            nonlocal bytes_done
            async for line in process.stdout:
                decoded = line.decode("utf-8", errors="replace").strip()
                # rsync progress lines: "    1,234,567  45%   2.34MB/s    0:00:12"
                if "%" in decoded:
                    parts = decoded.split()
                    for i, p in enumerate(parts):
                        if p.endswith("%"):
                            try:
                                pct = float(p.rstrip("%"))
                                # Map rsync 0-100% to our 10-85% range
                                job.progress = 10.0 + (pct * 0.75)
                                job.updated_at = time.time()
                            except ValueError:
                                pass
                        if "MB/s" in p or "kB/s" in p:
                            try:
                                speed_str = p.replace("MB/s", "").replace("kB/s", "")
                                speed = float(speed_str)
                                job.transfer_speed = speed * (1 if "MB/s" in p else 0.001)
                            except ValueError:
                                pass

        await asyncio.gather(read_progress(), process.wait())

        if process.returncode != 0:
            stderr = await process.stderr.read()
            raise RuntimeError(f"rsync failed (code {process.returncode}): {stderr.decode()[:500]}")

        job.transfer_speed = 0.0
        elapsed = time.time() - start_time
        speed_mbps = (job.size_bytes / elapsed / 1_000_000) if elapsed > 0 else 0
        logger.info(f"rsync complete in {elapsed:.0f}s at {speed_mbps:.1f} MB/s")

    async def _add_to_seeder(self, job: MigrationJob):
        cfg = self.config
        import os

        fastresume_dir = cfg.get(
            "qbit_a_fastresume_dir",
            "/config/qBittorrent/data/BT_backup"
        )
        torrent_file = os.path.join(fastresume_dir, f"{job.torrent_hash}.torrent")

        if not os.path.exists(torrent_file):
            raise FileNotFoundError(f".torrent file not found: {torrent_file}")

        pi_root = cfg["pi_seed_root"]
        dest_dir = os.path.join(pi_root, os.path.basename(job.save_path))

        loop = asyncio.get_event_loop()
        def _add():
            with qbittorrentapi.Client(
                host=cfg["pi_host"], port=cfg.get("qbit_b_port", 8080),
                username=cfg["qbit_b_user"], password=cfg["qbit_b_pass"],
            ) as qbb:
                with open(torrent_file, "rb") as fh:
                    torrent_data = fh.read()
                qbb.torrents_add(
                    torrent_files=torrent_data,
                    save_path=dest_dir,
                    category=cfg.get("seed_category", "seeding"),
                    is_paused=True,
                    use_auto_torrent_management=False,
                )

        await loop.run_in_executor(None, _add)
        await asyncio.sleep(5)

    async def _wait_for_recheck(self, job: MigrationJob):
        cfg = self.config
        timeout = cfg.get("recheck_timeout", 300)
        deadline = time.time() + timeout

        loop = asyncio.get_event_loop()

        # Trigger recheck
        def _recheck():
            with qbittorrentapi.Client(
                host=cfg["pi_host"], port=cfg.get("qbit_b_port", 8080),
                username=cfg["qbit_b_user"], password=cfg["qbit_b_pass"],
            ) as qbb:
                qbb.torrents_recheck(torrent_hashes=job.torrent_hash)

        await loop.run_in_executor(None, _recheck)

        while time.time() < deadline:
            def _check():
                with qbittorrentapi.Client(
                    host=cfg["pi_host"], port=cfg.get("qbit_b_port", 8080),
                    username=cfg["qbit_b_user"], password=cfg["qbit_b_pass"],
                ) as qbb:
                    info = qbb.torrents_info(torrent_hashes=job.torrent_hash)
                    return info[0] if info else None

            t = await loop.run_in_executor(None, _check)
            if t:
                state = t.state_enum
                if state in (
                    qbittorrentapi.TorrentStates.UPLOADING,
                    qbittorrentapi.TorrentStates.STALLED_UPLOAD,
                    qbittorrentapi.TorrentStates.PAUSED_UPLOAD,
                    qbittorrentapi.TorrentStates.QUEUED_UPLOAD,
                ):
                    logger.info(f"Recheck passed — state: {t.state}")
                    def _resume():
                        with qbittorrentapi.Client(
                            host=cfg["pi_host"], port=cfg.get("qbit_b_port", 8080),
                            username=cfg["qbit_b_user"], password=cfg["qbit_b_pass"],
                        ) as qbb:
                            qbb.torrents_resume(torrent_hashes=job.torrent_hash)
                    await loop.run_in_executor(None, _resume)
                    return
                elif "error" in str(t.state).lower():
                    raise RuntimeError(f"qBit-B recheck error state: {t.state}")
            await asyncio.sleep(10)

        raise TimeoutError(f"Recheck timed out after {timeout}s")

    async def _delete_from_source(self, job: MigrationJob):
        cfg = self.config
        loop = asyncio.get_event_loop()
        def _delete():
            with qbittorrentapi.Client(
                host=cfg["qbit_a_host"], port=cfg["qbit_a_port"],
                username=cfg["qbit_a_user"], password=cfg["qbit_a_pass"],
            ) as qba:
                qba.torrents_delete(
                    delete_files=True,
                    torrent_hashes=job.torrent_hash,
                )
        await loop.run_in_executor(None, _delete)
        logger.info(f"Deleted from qBit-A: {job.torrent_name}")

    def get_status(self) -> dict:
        """Return full engine status for the API."""
        active = [j.to_dict() for j in self.jobs.values() if j.stage != MigrationStage.DONE]
        return {
            "running": self._running,
            "active_jobs": active,
            "history": self.history[:50],
            "stats": self.stats,
        }
