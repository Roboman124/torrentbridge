#!/usr/bin/env bash
# =============================================================================
#  TorrentBridge — Raspberry Pi 4 Setup Script
#  Tested on: Raspberry Pi OS Lite 64-bit (Bookworm)
#  Run as: curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/torrentbridge/main/pi/setup.sh | bash
#  Or locally: bash setup.sh
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[TB]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!!]${RESET} $*"; }
err()  { echo -e "${RED}[ERR]${RESET} $*"; exit 1; }
hdr()  { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    warn "Not running as root. Re-launching with sudo..."
    exec sudo bash "$0" "$@"
fi

# ── Detect real user (the one who invoked sudo) ───────────────────────────────
REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[[ -z "$REAL_HOME" ]] && REAL_HOME="/home/$REAL_USER"

# ── Config — edit these before running if you want non-interactive setup ─────
QBIT_WEB_PORT="${QBIT_WEB_PORT:-8080}"
QBIT_WEBUI_USER="${QBIT_WEBUI_USER:-admin}"
QBIT_WEBUI_PASS="${QBIT_WEBUI_PASS:-}"        # blank = prompted interactively
SEED_ROOT="${SEED_ROOT:-/mnt/seeds}"
TB_UNRAID_IP="${TB_UNRAID_IP:-}"              # blank = prompted interactively

QBIT_CONFIG_DIR="$REAL_HOME/.config/qBittorrent"
QBIT_DATA_DIR="$REAL_HOME/.local/share/qBittorrent"

# =============================================================================
hdr "TorrentBridge Pi Setup"
echo -e "  Target user : ${BOLD}$REAL_USER${RESET}"
echo -e "  Home        : ${BOLD}$REAL_HOME${RESET}"
echo -e "  Seed root   : ${BOLD}$SEED_ROOT${RESET}"
echo -e "  qBit port   : ${BOLD}$QBIT_WEB_PORT${RESET}"
echo ""

# ── Interactive prompts ───────────────────────────────────────────────────────
if [[ -z "$QBIT_WEBUI_PASS" ]]; then
    read -rsp "  Enter qBittorrent WebUI password: " QBIT_WEBUI_PASS
    echo ""
    [[ -z "$QBIT_WEBUI_PASS" ]] && err "Password cannot be empty"
fi

if [[ -z "$TB_UNRAID_IP" ]]; then
    read -rp "  Enter your Unraid IP (for SSH authorized_keys, e.g. 192.168.1.10): " TB_UNRAID_IP
    echo ""
fi

# =============================================================================
hdr "1 / 7  System update"
log "Updating package lists..."
apt-get update -qq
log "Upgrading installed packages..."
apt-get upgrade -y -qq
ok "System up to date"

# =============================================================================
hdr "2 / 7  Install packages"
log "Installing qBittorrent-nox, rsync, curl, jq, htop..."
apt-get install -y -qq \
    qbittorrent-nox \
    rsync \
    curl \
    jq \
    htop \
    openssh-server \
    ca-certificates \
    avahi-daemon
ok "Packages installed"

# ── Print qBittorrent version ─────────────────────────────────────────────────
QBIT_VER=$(qbittorrent-nox --version 2>/dev/null | head -1 || echo "unknown")
log "qBittorrent version: $QBIT_VER"

# =============================================================================
hdr "3 / 7  Configure seed storage (SD card)"

log "Creating seed directory at $SEED_ROOT..."
mkdir -p "$SEED_ROOT"
chown "$REAL_USER:$REAL_USER" "$SEED_ROOT"
chmod 755 "$SEED_ROOT"

# Optimise ext4 mount options for SD card seeding
# Detect the root filesystem device and re-mount with noatime
ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_FS=$(findmnt -n -o FSTYPE /)

log "Root filesystem: $ROOT_DEV ($ROOT_FS)"

if [[ "$ROOT_FS" == "ext4" ]]; then
    # Check if noatime is already set
    if ! grep -q "noatime" /etc/fstab; then
        log "Adding noatime to root mount options in /etc/fstab..."
        cp /etc/fstab /etc/fstab.bak
        # Add noatime,nodiratime to the root entry
        sed -i '/\s\/\s/s/defaults/defaults,noatime,nodiratime/' /etc/fstab
        ok "noatime added (will take effect on next boot)"
    else
        ok "noatime already set"
    fi
else
    warn "Root is not ext4 ($ROOT_FS) — skipping mount option tuning"
fi

# Reduce SD card writes: move qBit session/resume files to tmpfs
log "Setting up tmpfs for qBittorrent BT_backup (reduces SD writes)..."
mkdir -p "$QBIT_DATA_DIR/BT_backup"
chown -R "$REAL_USER:$REAL_USER" "$QBIT_DATA_DIR"

# Add tmpfs entry to fstab if not already there
TMPFS_LINE="tmpfs  $QBIT_DATA_DIR/BT_backup  tmpfs  size=256M,uid=$(id -u $REAL_USER),gid=$(id -g $REAL_USER),mode=0755  0 0"
if ! grep -qF "$QBIT_DATA_DIR/BT_backup" /etc/fstab; then
    echo "$TMPFS_LINE" >> /etc/fstab
    log "tmpfs entry added to /etc/fstab"
fi

# Mount it now
mount "$QBIT_DATA_DIR/BT_backup" 2>/dev/null || true
ok "tmpfs configured for BT_backup"

# Cron job: back up BT_backup to SD every 15 minutes (survive reboots)
BACKUP_DIR="$SEED_ROOT/.qbt_session_backup"
mkdir -p "$BACKUP_DIR"
chown "$REAL_USER:$REAL_USER" "$BACKUP_DIR"

CRON_BACKUP="*/15 * * * * rsync -a --delete $QBIT_DATA_DIR/BT_backup/ $BACKUP_DIR/ 2>/dev/null"
CRON_RESTORE="@reboot sleep 10 && rsync -a $BACKUP_DIR/ $QBIT_DATA_DIR/BT_backup/ 2>/dev/null"

(crontab -u "$REAL_USER" -l 2>/dev/null | grep -v "BT_backup" || true
 echo "$CRON_BACKUP"
 echo "$CRON_RESTORE") | crontab -u "$REAL_USER" -
ok "Session backup cron jobs installed"

# =============================================================================
hdr "4 / 7  Configure qBittorrent"

mkdir -p "$QBIT_CONFIG_DIR"
chown -R "$REAL_USER:$REAL_USER" "$QBIT_CONFIG_DIR"

# Hash the password using qBittorrent's PBKDF2 format
# qBittorrent 4.6+ uses PBKDF2-HMAC-SHA512
# We generate the hash using Python (always available on Pi OS)
PASS_HASH=$(python3 -c "
import hashlib, secrets, base64, sys
password = sys.argv[1]
salt = secrets.token_bytes(16)
dk = hashlib.pbkdf2_hmac('sha512', password.encode(), salt, 100000)
salt_b64 = base64.b64encode(salt).decode()
hash_b64 = base64.b64encode(dk).decode()
print(f'@ByteArray({salt_b64}:{hash_b64})')
" "$QBIT_WEBUI_PASS")

log "Writing qBittorrent config..."
cat > "$QBIT_CONFIG_DIR/qBittorrent.conf" << EOF
[AutoRun]
enabled=false

[BitTorrent]
Session\DefaultSavePath=$SEED_ROOT
Session\MaxActiveCheckingTorrents=1
Session\MaxActiveDownloads=0
Session\MaxActiveTorrents=2000
Session\MaxActiveUploads=2000
Session\MaxConnections=300
Session\MaxConnectionsPerTorrent=6
Session\MaxUploads=-1
Session\MaxUploadsPerTorrent=-1
Session\Port=6881
Session\Preallocation=false
Session\QueueingSystemEnabled=true
Session\TempPath=$SEED_ROOT/.incomplete
Session\TempPathEnabled=false
Session\uTPMixedMode=true

[Core]
AutoDeleteAddedTorrentFile=Never

[LegalNotice]
Accepted=true

[Preferences]
Advanced\RecheckOnCompletion=false
Advanced\trackerPort=9000
Connection\GlobalDLLimitAlt=0
Connection\GlobalUPLimitAlt=0
Connection\PortRangeMin=$QBIT_WEB_PORT
Downloads\PreallocateAll=false
Downloads\SavePath=$SEED_ROOT
Downloads\TempPath=$SEED_ROOT/.incomplete
General\Locale=en
MailNotification\enabled=false
Scheduler\days=EveryDay
Scheduler\end_time=@Variant(\0\0\0\xf\0\0\0\0)
Scheduler\start_time=@Variant(\0\0\0\xf\0\0\0\0)
WebUI\Address=*
WebUI\AlternativeUIEnabled=false
WebUI\AuthSubnetWhitelistEnabled=false
WebUI\BanDuration=3600
WebUI\CSRFProtection=true
WebUI\ClickjackingProtection=true
WebUI\Enabled=true
WebUI\HTTPS\Enabled=false
WebUI\HostHeaderValidation=false
WebUI\LocalHostAuth=false
WebUI\MaxAuthenticationFailCount=5
WebUI\Password_PBKDF2=$PASS_HASH
WebUI\Port=$QBIT_WEB_PORT
WebUI\SecureCookie=false
WebUI\ServerDomains=*
WebUI\UseUPnP=false
WebUI\Username=$QBIT_WEBUI_USER
EOF

chown "$REAL_USER:$REAL_USER" "$QBIT_CONFIG_DIR/qBittorrent.conf"
ok "qBittorrent config written"

# =============================================================================
hdr "5 / 7  Create systemd service"

log "Creating qbittorrent-nox systemd service..."
cat > /etc/systemd/system/qbittorrent-nox.service << EOF
[Unit]
Description=qBittorrent-nox (TorrentBridge Seeder)
Documentation=https://github.com/YOUR_USERNAME/torrentbridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REAL_USER
Group=$REAL_USER
UMask=0002
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$QBIT_WEB_PORT
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

# Resource limits — sensible for Pi 4
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable qbittorrent-nox
systemctl start qbittorrent-nox
ok "qbittorrent-nox service enabled and started"

# Wait for qBit to initialise
log "Waiting 8s for qBittorrent WebUI to come up..."
sleep 8

# Quick health check
if curl -sf "http://localhost:$QBIT_WEB_PORT/api/v2/app/version" > /dev/null 2>&1; then
    QBIT_API_VER=$(curl -s "http://localhost:$QBIT_WEB_PORT/api/v2/app/version")
    ok "qBittorrent WebUI responding — version $QBIT_API_VER"
else
    warn "WebUI not yet responding — it may still be starting up. Check: systemctl status qbittorrent-nox"
fi

# =============================================================================
hdr "6 / 7  SSH hardening & authorized_keys"

log "Ensuring SSH server is enabled..."
systemctl enable ssh
systemctl start ssh

SSH_DIR="$REAL_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown -R "$REAL_USER:$REAL_USER" "$SSH_DIR"

# Harden SSH config
SSH_CONFIG="/etc/ssh/sshd_config"
cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"

log "Hardening SSH config..."
# Disable password auth if an Unraid IP was provided (key-only)
if [[ -n "$TB_UNRAID_IP" ]]; then
    # Note: We only disable password auth after you've confirmed key access
    # For now, keep password auth on so you can still get in if needed
    warn "Password authentication left ENABLED — disable it manually after confirming SSH key access from Unraid"
fi

# Ensure public key auth is on
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
grep -q "PubkeyAuthentication" "$SSH_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSH_CONFIG"

systemctl reload ssh
ok "SSH configured"

echo ""
log "To authorise TorrentBridge on Unraid to SSH into this Pi, run on Unraid:"
echo -e "  ${CYAN}ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub $REAL_USER@$(hostname -I | awk '{print $1}')${RESET}"

# =============================================================================
hdr "7 / 7  System tuning for seeding workload"

log "Tuning kernel network parameters..."
cat > /etc/sysctl.d/99-torrentbridge.conf << 'EOF'
# TorrentBridge — Pi 4 seeding optimisation

# Increase socket buffer sizes for better throughput
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864

# Increase connection backlog
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 4096

# Reduce TIME_WAIT connections
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Increase max open file descriptors
fs.file-max = 500000

# Reduce swappiness — keep data in RAM on Pi
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

sysctl -p /etc/sysctl.d/99-torrentbridge.conf > /dev/null 2>&1
ok "Kernel parameters tuned"

# Increase open file limit for the user
log "Setting file descriptor limits..."
cat > /etc/security/limits.d/99-torrentbridge.conf << EOF
$REAL_USER  soft  nofile  65536
$REAL_USER  hard  nofile  65536
$REAL_USER  soft  nproc   4096
$REAL_USER  hard  nproc   4096
EOF
ok "File descriptor limits set"

# Disable swap to protect SD card
if swapon --summary | grep -q "Filename"; then
    log "Disabling swap to reduce SD card wear..."
    dphys-swapfile swapoff 2>/dev/null || true
    dphys-swapfile uninstall 2>/dev/null || true
    systemctl disable dphys-swapfile 2>/dev/null || true
    ok "Swap disabled"
else
    ok "Swap already disabled"
fi

# Enable zram for better memory efficiency (Pi 4)
if ! dpkg -l | grep -q zram-tools; then
    log "Installing zram-tools for compressed RAM swap..."
    apt-get install -y -qq zram-tools
    cat > /etc/default/zramswap << 'EOF'
ALGO=lz4
PERCENT=50
EOF
    systemctl enable zramswap
    systemctl start zramswap
    ok "zram swap enabled (50% RAM, lz4 compression)"
fi

# =============================================================================
hdr "Setup Complete!"

PI_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}${BOLD}  ✓ TorrentBridge Pi seeder is ready${RESET}"
echo ""
echo -e "  ${BOLD}Pi IP address    :${RESET} $PI_IP"
echo -e "  ${BOLD}qBit WebUI       :${RESET} http://$PI_IP:$QBIT_WEB_PORT"
echo -e "  ${BOLD}WebUI username   :${RESET} $QBIT_WEBUI_USER"
echo -e "  ${BOLD}Seed directory   :${RESET} $SEED_ROOT"
echo -e "  ${BOLD}SSH user         :${RESET} $REAL_USER"
echo ""
echo -e "${YELLOW}  Next steps:${RESET}"
echo -e "  1. Run this on your Unraid terminal to authorize SSH access:"
echo -e "     ${CYAN}ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub $REAL_USER@$PI_IP${RESET}"
echo -e "  2. Test the connection:"
echo -e "     ${CYAN}ssh -i /mnt/user/appdata/torrentbridge/ssh/id_migrate $REAL_USER@$PI_IP 'echo OK'${RESET}"
echo -e "  3. Open TorrentBridge on Unraid: http://YOUR-UNRAID-IP:7474"
echo -e "     → Config tab → fill in Pi IP ($PI_IP) → Test connection"
echo ""
echo -e "${BOLD}  A reboot is recommended to apply all settings:${RESET}"
echo -e "  ${CYAN}sudo reboot${RESET}"
echo ""
