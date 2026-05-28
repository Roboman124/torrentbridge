# TorrentBridge 🌉

**Automated two-stage torrent seeding: download fast on Unraid, seed long-term on a Raspberry Pi.**

TorrentBridge runs as a Docker container on Unraid. It watches qBittorrent-A for completed downloads, waits for Sonarr/Radarr to import them, then migrates the data and torrent session to qBittorrent-B on a Raspberry Pi via rsync over SSH. Deletion from Unraid only happens after the Pi confirms a 100% recheck.

---

## How It Works

```
qBit-A (Unraid)  →  Sonarr/Radarr import  →  rsync to Pi  →  qBit-B recheck  →  qBit-A cleanup
  [download]            [wait & confirm]        [transfer]       [verify 100%]      [delete]
```

1. **Download** — Sonarr/Radarr send torrents to qBit-A on Unraid (fast NVMe cache)
2. **Import** — TorrentBridge polls Sonarr/Radarr until the import is confirmed
3. **Transfer** — rsync sends data to the Pi over SSH with checksum verification
4. **Verify** — qBit-B performs a force-recheck; seeding starts only on 100% pass
5. **Cleanup** — qBit-A deletes the torrent and data, freeing Unraid cache space

---

## Quick Start

### 1. Clone this repo

```bash
git clone https://github.com/YOUR_USERNAME/torrentbridge.git
cd torrentbridge
```

### 2. Generate SSH key (on Unraid terminal)

```bash
mkdir -p /mnt/user/appdata/torrentbridge/ssh
ssh-keygen -t ed25519 \
  -f /mnt/user/appdata/torrentbridge/ssh/id_migrate \
  -N "" -C "torrentbridge@unraid"
chmod 600 /mnt/user/appdata/torrentbridge/ssh/id_migrate

# Authorize on Pi (replace IP)
ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub pi@192.168.1.XX
```

### 3. Copy files to Unraid

```bash
cp -r . /mnt/user/appdata/torrentbridge/
```

### 4. Build and run

```bash
cd /mnt/user/appdata/torrentbridge
docker build -t torrentbridge:latest .
# Edit docker-compose.yml with your IPs/passwords
docker compose up -d
```

### 5. Open the Web UI

**http://YOUR-UNRAID-IP:7474**

Use the **Config** tab to set credentials and test all connections.

---

## Installation Methods

### Option A — Docker Compose (recommended)

Edit `docker-compose.yml` with your settings and run:

```bash
docker compose up -d
```

### Option B — Manual `docker run`

```bash
docker run -d \
  --name torrentbridge \
  --network host \
  --restart unless-stopped \
  -v /mnt/user/appdata/torrentbridge:/config \
  -v /mnt/user/appdata/qbittorrent/data/BT_backup:/config/qBittorrent/data/BT_backup:ro \
  -e TB_QBIT_A_HOST=localhost \
  -e TB_QBIT_A_PORT=8080 \
  -e TB_QBIT_A_USER=admin \
  -e TB_QBIT_A_PASS=yourpass \
  -e TB_PI_HOST=192.168.1.XX \
  -e TB_PI_USER_SSH=pi \
  -e TB_PI_USER_QBIT=admin \
  -e TB_PI_PASS_QBIT=yourpass \
  -e TB_PI_SEED_ROOT=/mnt/external/seeds \
  -e TB_SSH_KEY_PATH=/config/ssh/id_migrate \
  torrentbridge:latest
```

### Option C — Unraid Community Applications

Add the template URL in CA (once published to a registry):
Use `torrentbridge-unraid.xml` as the template source.

---

## Configuration

All settings can be configured via environment variables or the web UI Config tab.

| Variable | Default | Description |
|---|---|---|
| `TB_QBIT_A_HOST` | `localhost` | qBittorrent-A host |
| `TB_QBIT_A_PORT` | `8080` | qBittorrent-A WebUI port |
| `TB_QBIT_A_USER` | `admin` | qBittorrent-A username |
| `TB_QBIT_A_PASS` | — | qBittorrent-A password |
| `TB_PI_HOST` | — | **Required.** Pi IP address |
| `TB_PI_PORT` | `8080` | qBittorrent-B WebUI port |
| `TB_PI_USER_SSH` | `pi` | SSH user for rsync |
| `TB_PI_USER_QBIT` | `admin` | qBittorrent-B username |
| `TB_PI_PASS_QBIT` | — | qBittorrent-B password |
| `TB_PI_SEED_ROOT` | `/mnt/external/seeds` | Root seed path on Pi |
| `TB_SSH_KEY_PATH` | `/config/ssh/id_migrate` | SSH private key path (in container) |
| `TB_SONARR_HOST` | — | Sonarr host (optional) |
| `TB_SONARR_API_KEY` | — | Sonarr API key |
| `TB_RADARR_HOST` | — | Radarr host (optional) |
| `TB_RADARR_API_KEY` | — | Radarr API key |
| `TB_POLL_INTERVAL` | `30` | Seconds between qBit-A polls |
| `TB_POST_DOWNLOAD_DELAY` | `60` | Seconds to wait for Arr import |
| `TB_RECHECK_TIMEOUT` | `300` | Max seconds for Pi recheck |
| `TB_BWLIMIT_KBPS` | `0` | rsync bandwidth cap (0 = unlimited) |
| `TB_WATCH_CATEGORY` | `` | Only migrate this qBit category (blank = all) |
| `TB_SEED_CATEGORY` | `seeding` | Category assigned on qBit-B |
| `TB_WEB_PORT` | `7474` | Web UI port |
| `TB_LOG_LEVEL` | `INFO` | Log verbosity: DEBUG / INFO / WARNING / ERROR |

---

## Volume Mounts

| Container Path | Default Host Path | Purpose |
|---|---|---|
| `/config` | `/mnt/user/appdata/torrentbridge` | Config file, SSH keys, persistent data |
| `/config/qBittorrent/data/BT_backup` | `/mnt/user/appdata/qbittorrent/data/BT_backup` | qBit-A `.torrent` + `.fastresume` files (read-only) |

---

## Sonarr / Radarr Setup

To prevent errors when TorrentBridge removes torrents from qBit-A after import:

**Settings → Download Clients → qBittorrent:**
- ✅ Remove Completed: **Enabled**
- Minimum Seed Time: **0**
- Minimum Ratio: **0.0**

TorrentBridge handles all seeding tracking from this point.

---

## Project Structure

```
torrentbridge/
├── Dockerfile                    # Container definition
├── docker-compose.yml            # Compose config with all env vars
├── requirements.txt              # Python dependencies
├── torrentbridge-unraid.xml      # Unraid CA template
├── README.md                     # This file
├── SETUP.md                      # Detailed setup guide
└── app/
    ├── main.py                   # Entrypoint — starts engine + web server
    ├── core/
    │   ├── engine.py             # Migration pipeline orchestration
    │   └── config.py             # Config loader (env vars + JSON file)
    ├── api/
    │   └── routes.py             # REST API (aiohttp)
    └── web/
        └── static/
            └── index.html        # Single-page web UI
```

---

## Troubleshooting

**`rsync: Permission denied (publickey)`**
SSH key not copied to Pi. Re-run the `ssh-copy-id` step.

**`qBit-A login failed`**
Check `TB_QBIT_A_USER` / `TB_QBIT_A_PASS`. With `network_mode: host`, use `localhost` or your Unraid LAN IP.

**`.torrent file not found`**
Verify the BT_backup volume mount path matches your qBittorrent appdata location.

**Recheck times out on Pi**
Increase `TB_RECHECK_TIMEOUT`. Large files (4K Blu-ray rips etc.) can take several minutes. Also confirm the rsync destination path exactly matches qBit-B's configured save path.

**Sonarr shows errors after migration**
Set Minimum Seed Time to `0` in Sonarr's download client settings (see above).

---

## Requirements

- Unraid 6.x+ with Docker
- qBittorrent with WebUI enabled on both Unraid and Pi
- Raspberry Pi accessible on LAN via SSH
- Python 3.12+ (provided by the Docker image)

---

## License

MIT — do whatever you want with it.
