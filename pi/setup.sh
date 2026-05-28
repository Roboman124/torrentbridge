#!/usr/bin/env bash
# =============================================================================
#  TorrentBridge — Raspberry Pi 4 Setup Script v0.2.0
#  Tested on: Raspberry Pi OS Lite 64-bit (Bookworm)
#  Usage: sudo bash setup.sh
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

# ── Detect real user ──────────────────────────────────────────────────────────
REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[[ -z "$REAL_HOME" ]] && REAL_HOME="/home/$REAL_USER"

# ── Config ────────────────────────────────────────────────────────────────────
QBIT_WEB_PORT="${QBIT_WEB_PORT:-8080}"
QBIT_WEBUI_USER="${QBIT_WEBUI_USER:-admin}"
QBIT_WEBUI_PASS="${QBIT_WEBUI_PASS:-}"
SEED_ROOT="${SEED_ROOT:-/mnt/seeds}"
TB_UNRAID_IP="${TB_UNRAID_IP:-}"

QBIT_CONFIG_DIR="$REAL_HOME/.config/qBittorrent"
QBIT_DATA_DIR="$REAL_HOME/.local/share/qBittorrent"

# =============================================================================
hdr "TorrentBridge Pi Setup v0.2.0"
echo -e "  Target user : ${BOLD}$REAL_USER${RESET}"
echo -e "  Home        : ${BOLD}$REAL_HOME${RESET}"
echo -e "  Seed root   : ${BOLD}$SEED_ROOT${RESET}"
echo -e "  qBit port   : ${BOLD}$QBIT_WEB_PORT${RESET}"
echo ""

# ── Interactive prompts ───────────────────────────────────────────────────────
while [[ -z "$QBIT_WEBUI_PASS" ]]; do
    read -rsp "  Enter qBittorrent WebUI password (min 6 chars): " QBIT_WEBUI_PASS
    echo ""
    if [[ ${#QBIT_WEBUI_PASS} -lt 6 ]]; then
        warn "Password must be at least 6 characters. Try again."
        QBIT_WEBUI_PASS=""
    fi
done

read -rp "  Enter your Unraid IP (e.g. 192.168.1.10, or press Enter to skip): " TB_UNRAID_IP
echo ""

# =============================================================================
hdr "1 / 8  System update"
log "Updating package lists..."
apt-get update -qq
log "Upgrading installed packages (this may take a few minutes)..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "System up to date"

# =============================================================================
hdr "2 / 8  Install packages"
log "Installing qBittorrent-nox, rsync, curl, jq, htop..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    qbittorrent-nox \
    rsync \
    curl \
    jq \
    htop \
    openssh-server \
    ca-certificates \
    avahi-daemon \
    procps

QBIT_VER=$(qbittorrent-nox --version 2>/dev/null | head -1 || echo "unknown")
ok "Packages installed — $QBIT_VER"

# =============================================================================
hdr "3 / 8  Kill any existing qBittorrent processes"
log "Ensuring no stale qBittorrent processes..."
pkill -9 qbittorrent-nox 2>/dev/null || true
sleep 2

# Free port if still occupied
if ss -tlnp | grep -q ":${QBIT_WEB_PORT}"; then
    STALE_PID=$(ss -tlnp | grep ":${QBIT_WEB_PORT}" | grep -oP 'pid=\K[0-9]+' | head -1)
    if [[ -n "$STALE_PID" ]]; then
        log "Killing stale process on port $QBIT_WEB_PORT (PID $STALE_PID)..."
        kill -9 "$STALE_PID" 2>/dev/null || true
        sleep 2
    fi
fi

if ss -tlnp | grep -q ":${QBIT_WEB_PORT}"; then
    err "Port $QBIT_WEB_PORT is still in use. Reboot the Pi and re-run this script."
fi
ok "Port $QBIT_WEB_PORT is free"

# =============================================================================
hdr "4 / 8  Configure seed storage"
log "Creating seed directory at $SEED_ROOT..."
mkdir -p "$SEED_ROOT"
chown "$REAL_USER:$REAL_USER" "$SEED_ROOT"
chmod 755 "$SEED_ROOT"

# noatime on root ext4
ROOT_FS=$(findmnt -n -o FSTYPE /)
if [[ "$ROOT_FS" == "ext4" ]]; then
    if ! grep -q "noatime" /etc/fstab; then
        log "Adding noatime to fstab..."
        cp /etc/fstab /etc/fstab.bak
        sed -i '/\s\/\s/s/defaults/defaults,noatime,nodiratime/' /etc/fstab
        ok "noatime added"
    else
        ok "noatime already set"
    fi
fi

# Create qBit data dirs (NO tmpfs this time — caused too many issues)
mkdir -p "$QBIT_DATA_DIR/BT_backup"
mkdir -p "$QBIT_CONFIG_DIR"
chown -R "$REAL_USER:$REAL_USER" "$QBIT_DATA_DIR"
chown -R "$REAL_USER:$REAL_USER" "$QBIT_CONFIG_DIR"
ok "Storage configured"

# =============================================================================
hdr "5 / 8  Start qBittorrent and set password via API"

# Create a minimal config — let qBit handle the password itself via API
# qBit 5.x generates its own valid password hash on first run
cat > "$QBIT_CONFIG_DIR/qBittorrent.conf" << EOF
[LegalNotice]
Accepted=true

[Preferences]
WebUI\Address=*
WebUI\Enabled=true
WebUI\Port=$QBIT_WEB_PORT
WebUI\Username=$QBIT_WEBUI_USER
WebUI\LocalHostAuth=false
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
Downloads\SavePath=$SEED_ROOT
EOF

chown "$REAL_USER:$REAL_USER" "$QBIT_CONFIG_DIR/qBittorrent.conf"

# Start qBittorrent as the real user (not root)
log "Starting qBittorrent-nox temporarily to initialise..."
sudo -u "$REAL_USER" qbittorrent-nox --daemon --webui-port="$QBIT_WEB_PORT" 2>/dev/null || true

# Wait for WebUI to come up — poll instead of fixed sleep
log "Waiting for WebUI on port $QBIT_WEB_PORT..."
MAX_WAIT=30
WAITED=0
until curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1; do
    sleep 2
    WAITED=$((WAITED + 2))
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        err "qBittorrent WebUI did not come up after ${MAX_WAIT}s. Check: journalctl -u qbittorrent-nox"
    fi
    log "Still waiting... (${WAITED}s)"
done
ok "WebUI is up"

# Get the temporary default password from qBit's log
# qBit 5.x prints a random password on first run to stdout/log
TEMP_PASS=$(grep -r "password" "$QBIT_DATA_DIR/" 2>/dev/null | grep -oP '(?<=password is )\S+' | head -1 || true)

# If we can't find the temp password, try the classic default
if [[ -z "$TEMP_PASS" ]]; then
    # Try logging in with classic default first
    LOGIN_RESP=$(curl -s -c /tmp/qbit_cookies.txt \
        -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/auth/login" \
        -d "username=$QBIT_WEBUI_USER&password=adminadmin" 2>/dev/null || true)

    if [[ "$LOGIN_RESP" != "Ok." ]]; then
        # qBit 5.x — find the generated password from journal
        TEMP_PASS=$(journalctl -u qbittorrent-nox --no-pager 2>/dev/null | \
            grep -oP '(?<=temporary password is: )\S+' | tail -1 || true)

        # Also check the process stdout
        if [[ -z "$TEMP_PASS" ]]; then
            TEMP_PASS=$(sudo -u "$REAL_USER" cat /tmp/qbt_init.log 2>/dev/null | \
                grep -oP '(?<=password is: )\S+' | tail -1 || true)
        fi
    else
        TEMP_PASS="adminadmin"
    fi
fi

# Try to login with found temp password
if [[ -n "$TEMP_PASS" ]]; then
    log "Attempting login with temporary password..."
    LOGIN_RESP=$(curl -s -c /tmp/qbit_cookies.txt \
        -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/auth/login" \
        -d "username=$QBIT_WEBUI_USER&password=$TEMP_PASS" 2>/dev/null || true)
fi

if [[ "${LOGIN_RESP:-}" == "Ok." ]]; then
    log "Logged in. Setting your password via API..."
    PREF_RESP=$(curl -s -b /tmp/qbit_cookies.txt \
        -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/app/setPreferences" \
        -d "json=$(jq -n --arg p "$QBIT_WEBUI_PASS" '{web_ui_password: $p}')" 2>/dev/null || true)
    ok "Password set via API"
    rm -f /tmp/qbit_cookies.txt
else
    warn "Could not set password automatically — you will need to set it manually in the WebUI"
    warn "Open http://$(hostname -I | awk '{print $1}'):$QBIT_WEB_PORT after setup"
    warn "Default credentials are usually admin / adminadmin or a random password shown in: journalctl -u qbittorrent-nox"
fi

# Stop the temporary daemon
pkill -9 qbittorrent-nox 2>/dev/null || true
sleep 3

# =============================================================================
hdr "6 / 8  Apply full qBittorrent config"

# Now write the full optimised config on top
cat >> "$QBIT_CONFIG_DIR/qBittorrent.conf" << EOF

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
Session\uTPMixedMode=true

[Preferences]
Advanced\RecheckOnCompletion=false
Downloads\PreallocateAll=false
Downloads\SavePath=$SEED_ROOT
General\Locale=en
WebUI\Address=*
WebUI\Enabled=true
WebUI\Port=$QBIT_WEB_PORT
WebUI\Username=$QBIT_WEBUI_USER
WebUI\LocalHostAuth=false
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
WebUI\UseUPnP=false
EOF

chown "$REAL_USER:$REAL_USER" "$QBIT_CONFIG_DIR/qBittorrent.conf"
ok "Full config applied"

# =============================================================================
hdr "7 / 8  Create systemd service"
cat > /etc/systemd/system/qbittorrent-nox.service << EOF
[Unit]
Description=qBittorrent-nox (TorrentBridge Seeder)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REAL_USER
Group=$REAL_USER
UMask=0002
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$QBIT_WEB_PORT
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable qbittorrent-nox
systemctl start qbittorrent-nox
log "Waiting for service to come up..."

WAITED=0
until curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1; do
    sleep 2
    WAITED=$((WAITED + 2))
    if [[ $WAITED -ge 30 ]]; then
        warn "WebUI slow to start — check: systemctl status qbittorrent-nox"
        break
    fi
done

if curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1; then
    ok "qbittorrent-nox service running — WebUI confirmed up"
else
    warn "Service started but WebUI not yet responding. Check logs after reboot."
fi

# =============================================================================
hdr "8 / 8  SSH + system tuning"

# SSH
systemctl enable ssh
systemctl start ssh
SSH_DIR="$REAL_HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$REAL_USER:$REAL_USER" "$SSH_DIR"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^PubkeyAuthentication" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
systemctl reload ssh
ok "SSH configured"

# Kernel tuning
cat > /etc/sysctl.d/99-torrentbridge.conf << 'EOF'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 4096
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 500000
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
sysctl -p /etc/sysctl.d/99-torrentbridge.conf > /dev/null 2>&1
ok "Kernel parameters tuned"

# File limits
cat > /etc/security/limits.d/99-torrentbridge.conf << EOF
$REAL_USER  soft  nofile  65536
$REAL_USER  hard  nofile  65536
EOF
ok "File descriptor limits set"

# Disable swap
dphys-swapfile swapoff 2>/dev/null || true
dphys-swapfile uninstall 2>/dev/null || true
systemctl disable dphys-swapfile 2>/dev/null || true
ok "Swap disabled"

# zram — load module first, then install
log "Setting up zram..."
modprobe zram 2>/dev/null || warn "zram module not available — skipping"
if lsmod | grep -q zram; then
    echo "zram" > /etc/modules-load.d/zram.conf
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zram-tools 2>/dev/null || true
    if command -v zramswap &>/dev/null || [[ -f /etc/default/zramswap ]]; then
        cat > /etc/default/zramswap << 'EOF'
ALGO=lz4
PERCENT=50
EOF
        systemctl enable zramswap 2>/dev/null || true
        systemctl start zramswap 2>/dev/null || warn "zramswap failed to start — not critical"
        ok "zram configured"
    fi
else
    warn "zram not available on this kernel — skipping (not critical)"
fi

# =============================================================================
hdr "Setup Complete!"

PI_IP=$(hostname -I | awk '{print $1}')
QBIT_RUNNING=$(systemctl is-active qbittorrent-nox 2>/dev/null || echo "unknown")

echo ""
echo -e "${GREEN}${BOLD}  ✓ TorrentBridge Pi seeder is ready${RESET}"
echo ""
echo -e "  ${BOLD}Pi IP address    :${RESET} $PI_IP"
echo -e "  ${BOLD}qBit WebUI       :${RESET} http://$PI_IP:$QBIT_WEB_PORT"
echo -e "  ${BOLD}WebUI username   :${RESET} $QBIT_WEBUI_USER"
echo -e "  ${BOLD}qBit service     :${RESET} $QBIT_RUNNING"
echo -e "  ${BOLD}Seed directory   :${RESET} $SEED_ROOT"
echo ""

# Print password status
if curl -s -c /tmp/qbit_test.txt \
    -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/auth/login" \
    -d "username=$QBIT_WEBUI_USER&password=$QBIT_WEBUI_PASS" 2>/dev/null | grep -q "Ok."; then
    echo -e "  ${GREEN}✓ WebUI login confirmed with your password${RESET}"
    rm -f /tmp/qbit_test.txt
else
    echo -e "  ${YELLOW}⚠ Could not confirm WebUI password — check manually:${RESET}"
    echo -e "    Try logging in with: admin / adminadmin"
    echo -e "    Or check temp password: journalctl -u qbittorrent-nox | grep -i password"
fi

echo ""
echo -e "${YELLOW}  Next steps:${RESET}"
if [[ -n "$TB_UNRAID_IP" ]]; then
    echo -e "  1. Run on your Unraid terminal:"
    echo -e "     ${CYAN}ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub $REAL_USER@$PI_IP${RESET}"
    echo -e "  2. Test SSH key works:"
    echo -e "     ${CYAN}ssh -i /mnt/user/appdata/torrentbridge/ssh/id_migrate $REAL_USER@$PI_IP 'echo OK'${RESET}"
    echo -e "  3. Open TorrentBridge: http://$TB_UNRAID_IP:7474"
else
    echo -e "  1. Run ssh-copy-id from Unraid to authorize the SSH key"
    echo -e "  2. Open TorrentBridge on Unraid: http://YOUR-UNRAID-IP:7474"
fi
echo ""
echo -e "${BOLD}  Reboot recommended:${RESET} ${CYAN}sudo reboot${RESET}"
echo ""
