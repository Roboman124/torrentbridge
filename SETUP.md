# TorrentBridge — Setup Guide

## Prerequisites

- Unraid with qBittorrent (qBit-A) already running
- Raspberry Pi with qBittorrent (qBit-B) already running and accessible on your LAN
- Both on the same network

---

## Step 1 — Generate SSH Key (run on Unraid terminal)

TorrentBridge uses SSH key authentication for rsync. No passwords.

```bash
# Create the config directory and SSH subfolder
mkdir -p /mnt/user/appdata/torrentbridge/ssh

# Generate the key pair
ssh-keygen -t ed25519 \
  -f /mnt/user/appdata/torrentbridge/ssh/id_migrate \
  -N "" \
  -C "torrentbridge@unraid"

# Fix permissions
chmod 700 /mnt/user/appdata/torrentbridge/ssh
chmod 600 /mnt/user/appdata/torrentbridge/ssh/id_migrate
```

---

## Step 2 — Authorize the Key on the Pi (run on Unraid terminal)

```bash
# Copy the public key to your Pi (replace 192.168.1.XX with your Pi's IP)
ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub pi@192.168.1.XX

# Test it works (should NOT ask for a password)
ssh -i /mnt/user/appdata/torrentbridge/ssh/id_migrate pi@192.168.1.XX "echo OK"
```

---

## Step 3 — Prepare the Pi's Seed Directory

SSH into your Pi:

```bash
ssh pi@192.168.1.XX

# Create the seed root
mkdir -p /mnt/external/seeds

# Ensure the SSH user owns it
sudo chown -R pi:pi /mnt/external/seeds
```

---

## Step 4 — Install TorrentBridge on Unraid

### Option A: Docker Compose

```bash
cd /mnt/user/appdata/torrentbridge
# Edit docker-compose.yml with your settings, then:
docker compose up -d
```

### Option B: Unraid Community Applications (once published)

1. Open Community Applications
2. Search for "TorrentBridge"
3. Click Install
4. Fill in the template fields (Pi IP, passwords, paths)
5. Apply

### Option C: Manual docker run

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
  -e TB_QBIT_A_PASS=YOUR_PASS \
  -e TB_PI_HOST=192.168.1.XX \
  -e TB_PI_USER_SSH=pi \
  -e TB_PI_USER_QBIT=admin \
  -e TB_PI_PASS_QBIT=YOUR_PASS \
  -e TB_PI_SEED_ROOT=/mnt/external/seeds \
  -e TB_SSH_KEY_PATH=/config/ssh/id_migrate \
  -e TB_SONARR_HOST=192.168.1.10 \
  -e TB_SONARR_API_KEY=YOUR_KEY \
  -e TB_RADARR_HOST=192.168.1.10 \
  -e TB_RADARR_API_KEY=YOUR_KEY \
  torrentbridge:latest
```

---

## Step 5 — Open the Web UI

Navigate to: **http://YOUR-UNRAID-IP:7474**

Click **Config**, fill in any remaining settings, click **Save Config**.

Use the **▶ test connection** buttons to verify all four connections (qBit-A, qBit-B, Sonarr, Radarr).

---

## Step 6 — Configure Sonarr/Radarr (Important)

To prevent Sonarr/Radarr from erroring when TorrentBridge removes torrents from qBit-A:

1. In Sonarr: **Settings → Download Clients → qBittorrent**
   - Set **Minimum Free Space**: leave default
   - Set **Remove Completed**: ✓ Enabled
   - Set **Minimum Seed Time**: `0`
   - Set **Minimum Ratio**: `0.0`

2. Repeat the same in Radarr.

This tells the Arr apps: "you don't need to track seeding — TorrentBridge handles it."

---

## Volume Mount Reference

| Container Path | Host Path (default) | Notes |
|---|---|---|
| `/config` | `/mnt/user/appdata/torrentbridge` | Config file, SSH keys, logs |
| `/config/qBittorrent/data/BT_backup` | `/mnt/user/appdata/qbittorrent/data/BT_backup` | qBit-A .torrent files (read-only) |

---

## Environment Variables Reference

| Variable | Default | Description |
|---|---|---|
| `TB_QBIT_A_HOST` | `localhost` | qBit-A host |
| `TB_QBIT_A_PORT` | `8080` | qBit-A WebUI port |
| `TB_QBIT_A_USER` | `admin` | qBit-A username |
| `TB_QBIT_A_PASS` | — | qBit-A password |
| `TB_QBIT_A_FASTRESUME_DIR` | `/config/qBittorrent/data/BT_backup` | Mapped BT_backup path |
| `TB_PI_HOST` | — | **Required.** Pi IP address |
| `TB_PI_PORT` | `8080` | qBit-B WebUI port |
| `TB_PI_USER_SSH` | `pi` | SSH user for rsync |
| `TB_PI_USER_QBIT` | `admin` | qBit-B username |
| `TB_PI_PASS_QBIT` | — | qBit-B password |
| `TB_PI_SEED_ROOT` | `/mnt/external/seeds` | Root seed path on Pi |
| `TB_SSH_KEY_PATH` | `/config/ssh/id_migrate` | SSH key inside container |
| `TB_SONARR_HOST` | — | Sonarr host (optional) |
| `TB_SONARR_PORT` | `8989` | Sonarr port |
| `TB_SONARR_API_KEY` | — | Sonarr API key |
| `TB_RADARR_HOST` | — | Radarr host (optional) |
| `TB_RADARR_PORT` | `7878` | Radarr port |
| `TB_RADARR_API_KEY` | — | Radarr API key |
| `TB_POLL_INTERVAL` | `30` | Seconds between qBit-A polls |
| `TB_POST_DOWNLOAD_DELAY` | `60` | Seconds to wait for Arr import |
| `TB_RECHECK_TIMEOUT` | `300` | Recheck timeout in seconds |
| `TB_BWLIMIT_KBPS` | `0` | rsync bandwidth cap (0=unlimited) |
| `TB_WATCH_CATEGORY` | `` | Only migrate this category (blank=all) |
| `TB_SEED_CATEGORY` | `seeding` | Category assigned on Pi |
| `TB_LOG_LEVEL` | `INFO` | Log verbosity |
| `TB_WEB_PORT` | `7474` | Web UI port |

---

## Troubleshooting

**"rsync failed: Permission denied (publickey)"**
→ SSH key not authorized. Re-run Step 2.

**"qBit-A login failed"**
→ Check `TB_QBIT_A_USER` / `TB_QBIT_A_PASS`. If using `network_mode: host`, `localhost` should work. If not, use your Unraid's actual LAN IP.

**".torrent file not found"**
→ Verify the BT_backup volume mount. The path inside the container must match `TB_QBIT_A_FASTRESUME_DIR`.

**Sonarr showing "Import failed" after migration**
→ Set Sonarr's Minimum Seed Time to 0 per Step 6.

**Pi recheck fails / times out**
→ Increase `TB_RECHECK_TIMEOUT`. Large files can take several minutes to verify. Also confirm the rsync destination path matches qBit-B's save path.
