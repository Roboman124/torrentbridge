# TorrentBridge — Raspberry Pi Setup

This folder contains the setup script for the Pi 4 seeder node.

---

## Requirements

- Raspberry Pi 4 (any RAM)
- SD card — 32GB minimum, 64GB+ recommended for seeding storage
- Raspberry Pi OS Lite **64-bit** (Bookworm) — headless, no desktop
- Connected to your LAN via ethernet (recommended) or Wi-Fi

---

## Step 1 — Flash the SD Card

1. Download **Raspberry Pi Imager**: https://www.raspberrypi.com/software/
2. Choose OS: **Raspberry Pi OS Lite (64-bit)** under "Raspberry Pi OS (other)"
3. Click the ⚙️ gear icon before flashing and configure:
   - ✅ Set hostname: `torrentbridge-pi`
   - ✅ Enable SSH (use password authentication for now)
   - ✅ Set username: `pi` and a password
   - ✅ Configure Wi-Fi if not using ethernet
4. Flash to your SD card
5. Insert card, connect ethernet (recommended), power on

---

## Step 2 — Find the Pi's IP Address

Check your router's DHCP client list, or from another machine on the network:

```bash
# Linux/Mac
ping torrentbridge-pi.local

# Or scan the network
nmap -sn 192.168.1.0/24 | grep -A2 "Raspberry"
```

---

## Step 3 — SSH in and Run the Setup Script

```bash
ssh pi@<PI-IP-ADDRESS>
```

Then run the setup script:

```bash
# Option A — from GitHub (once published)
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/torrentbridge/main/pi/setup.sh | sudo bash

# Option B — copy script to Pi first, then run
scp setup.sh pi@<PI-IP>:~/
ssh pi@<PI-IP>
sudo bash setup.sh
```

The script will ask for:
- A qBittorrent WebUI password
- Your Unraid IP address (used for SSH key instructions)

It takes about 3–5 minutes to complete.

---

## What the Script Does

| Step | Action |
|---|---|
| 1 | `apt update && apt upgrade` |
| 2 | Installs `qbittorrent-nox`, `rsync`, `openssh-server`, `avahi-daemon` |
| 3 | Creates `/mnt/seeds` seed directory, tunes ext4 mount options (`noatime`) |
| 4 | Mounts a 256MB tmpfs for qBit session files (reduces SD card writes) |
| 5 | Sets up cron to back up session files every 15 min (survive reboots) |
| 6 | Writes optimised `qBittorrent.conf` (seeding-focused, no downloads) |
| 7 | Creates and enables `qbittorrent-nox` systemd service |
| 8 | Hardens SSH config, enables public key auth |
| 9 | Tunes kernel network parameters for high-connection-count seeding |
| 10 | Disables SD card swap, enables zram (compressed RAM swap with lz4) |

---

## After the Script

### Authorize the Unraid SSH Key

Run this **on your Unraid terminal** (not the Pi):

```bash
ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub pi@<PI-IP>
```

Test it works:

```bash
ssh -i /mnt/user/appdata/torrentbridge/ssh/id_migrate pi@<PI-IP> "echo OK"
# Should print: OK   (no password prompt)
```

### Reboot the Pi

```bash
sudo reboot
```

### Configure TorrentBridge on Unraid

Open **http://YOUR-UNRAID-IP:7474** → Config tab:
- Pi IP / Hostname: your Pi's IP
- qBit-B Password: the password you set during setup
- SSH User: `pi`
- Click **▶ test connection** for both qBit-A and qBit-B

---

## Useful Commands on the Pi

```bash
# Check qBittorrent service status
systemctl status qbittorrent-nox

# View live logs
journalctl -u qbittorrent-nox -f

# Restart qBittorrent
sudo systemctl restart qbittorrent-nox

# Check seed directory usage
du -sh /mnt/seeds

# Check tmpfs session backup
ls ~/.local/share/qBittorrent/BT_backup/

# Check network tuning applied
sysctl net.core.rmem_max

# Monitor resource usage
htop
```

---

## Defaults

| Setting | Value |
|---|---|
| WebUI port | `8080` |
| WebUI username | `admin` |
| Seed directory | `/mnt/seeds` |
| SSH user | `pi` |
| Session tmpfs size | `256 MB` |
| Max active torrents | `2000` |
| Max connections | `300` |
| Swap | Disabled (zram used instead) |

Override any default by setting environment variables before running:

```bash
QBIT_WEB_PORT=9090 SEED_ROOT=/data/seeds sudo -E bash setup.sh
```

---

## Troubleshooting

**qBittorrent won't start**
```bash
journalctl -u qbittorrent-nox --no-pager -n 50
```

**WebUI not accessible**
```bash
# Check it's listening
ss -tlnp | grep 8080
# Check firewall (Pi OS usually has none by default)
sudo ufw status
```

**rsync from Unraid fails with "Permission denied"**
The SSH key hasn't been authorized. Run the `ssh-copy-id` command from Unraid again.

**Session files lost after reboot**
The tmpfs restore cron (`@reboot`) runs after 10s delay. Wait 15s after boot before checking.
