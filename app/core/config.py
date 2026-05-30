import os
import json
import logging

logger = logging.getLogger("torrentbridge.config")

DEFAULTS = {
    # Instance names (displayed in UI)
    "downloader_name": "Downloader",
    "seeder_name": "Seeder",
    # Downloader (qBit-A)
    "qbit_a_host": "localhost",
    "qbit_a_port": 8080,
    "qbit_a_user": "admin",
    "qbit_a_pass": "",
    "qbit_a_fastresume_dir": "/config/qBittorrent/data/BT_backup",
    # Seeder (qBit-B)
    "pi_host": "",
    "qbit_b_port": 8080,
    "qbit_b_user": "admin",
    "qbit_b_pass": "",
    "pi_user": "pi",
    "ssh_key_path": "/config/ssh/id_migrate",
    "pi_seed_root": "/mnt/seeds",
    # Arr apps
    "sonarr_host": "",
    "sonarr_port": 8989,
    "sonarr_api_key": "",
    "radarr_host": "",
    "radarr_port": 7878,
    "radarr_api_key": "",
    # Behaviour
    "poll_interval": 30,
    "post_download_delay": 60,
    "recheck_timeout": 300,
    "bwlimit_kbps": 0,
    "watch_category": "",
    "seed_category": "seeding",
    # Path remapping (for Docker path differences)
    # Default: qBit reports /downloads, container has /downloads mounted
    # So no remapping needed by default — they match.
    # Only change these if your qBittorrent reports a different internal path.
    "qbit_path_prefix": "",   # e.g. /data/completed (what qBit reports internally)
    "host_path_prefix": "",   # e.g. /downloads (what it maps to in this container)
    # Web UI auth (leave ui_password blank to disable authentication)
    "ui_username": "admin",
    "ui_password": "",
    # System
    "web_port": 7474,
    "log_level": "INFO",
}

INT_FIELDS = {
    "qbit_a_port","qbit_b_port","sonarr_port","radarr_port",
    "poll_interval","post_download_delay","recheck_timeout",
    "bwlimit_kbps","web_port",
}


def load_config(config_path: str = "/config/torrentbridge.json") -> dict:
    cfg = dict(DEFAULTS)

    if os.path.exists(config_path):
        try:
            with open(config_path) as f:
                file_cfg = json.load(f)
            cfg.update(file_cfg)
            logger.info(f"Loaded config from {config_path}")
        except Exception as e:
            logger.warning(f"Could not read config file {config_path}: {e}")

    # Still support env vars for initial bootstrap / docker-compose
    env_map = {
        "TB_QBIT_A_HOST": "qbit_a_host", "TB_QBIT_A_PORT": "qbit_a_port",
        "TB_QBIT_A_USER": "qbit_a_user", "TB_QBIT_A_PASS": "qbit_a_pass",
        "TB_QBIT_A_FASTRESUME_DIR": "qbit_a_fastresume_dir",
        "TB_PI_HOST": "pi_host", "TB_PI_PORT": "qbit_b_port",
        "TB_PI_USER_SSH": "pi_user", "TB_PI_USER_QBIT": "qbit_b_user",
        "TB_PI_PASS_QBIT": "qbit_b_pass", "TB_PI_SEED_ROOT": "pi_seed_root",
        "TB_SSH_KEY_PATH": "ssh_key_path",
        "TB_SONARR_HOST": "sonarr_host", "TB_SONARR_PORT": "sonarr_port",
        "TB_SONARR_API_KEY": "sonarr_api_key",
        "TB_RADARR_HOST": "radarr_host", "TB_RADARR_PORT": "radarr_port",
        "TB_RADARR_API_KEY": "radarr_api_key",
        "TB_POLL_INTERVAL": "poll_interval",
        "TB_POST_DOWNLOAD_DELAY": "post_download_delay",
        "TB_RECHECK_TIMEOUT": "recheck_timeout",
        "TB_BWLIMIT_KBPS": "bwlimit_kbps",
        "TB_WEB_PORT": "web_port", "TB_LOG_LEVEL": "log_level",
    }
    for env_key, cfg_key in env_map.items():
        val = os.environ.get(env_key)
        if val is not None:
            cfg[cfg_key] = int(val) if cfg_key in INT_FIELDS else val

    return cfg


def save_config(cfg: dict, config_path: str = "/config/torrentbridge.json"):
    with open(config_path, "w") as f:
        json.dump(cfg, f, indent=2)
    logger.info(f"Config saved to {config_path}")
