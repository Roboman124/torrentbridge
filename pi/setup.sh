#!/usr/bin/env bash
# =============================================================================
#  TorrentBridge — Raspberry Pi 4 Setup Script v0.3.0
#  Usage (interactive): curl -fsSL https://raw.githubusercontent.com/roboman124/torrentbridge/main/pi/setup.sh -o /tmp/tb_setup.sh && sudo bash /tmp/tb_setup.sh
#  Or short form via alias in README
# =============================================================================

# ── If being piped (stdin is not a terminal), re-download and exec properly ──
if [ ! -t 0 ]; then
    SCRIPT_URL="https://raw.githubusercontent.com/roboman124/torrentbridge/main/pi/setup.sh"
    TMPFILE=$(mktemp /tmp/tb_setup_XXXXXX.sh)
    echo "Downloading TorrentBridge setup script..."
    curl -fsSL "$SCRIPT_URL" -o "$TMPFILE"
    chmod +x "$TMPFILE"
    echo "Launching interactive installer..."
    exec sudo bash "$TMPFILE"
    exit 0
fi

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
clear
echo -e "${BOLD}"
echo "  ╔════════════════════════════════════════╗"
echo "  ║     TorrentBridge Pi Setup v0.3.0      ║"
echo "  ║     Raspberry Pi 4 — Seeder Node       ║"
echo "  ╚════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  User  : ${BOLD}$REAL_USER${RESET}  |  Home: ${BOLD}$REAL_HOME${RESET}"
echo -e "  Seeds : ${BOLD}$SEED_ROOT${RESET}  |  Port: ${BOLD}$QBIT_WEB_PORT${RESET}"
echo ""
echo -e "  ${YELLOW}This script will:${RESET}"
echo "    • Update the system"
echo "    • Install qBittorrent-nox"
echo "    • Configure it for long-term seeding"
echo "    • Set up SSH key access for Unraid"
echo "    • Tune the Pi for high-connection seeding"
echo ""
read -rp "  Press ENTER to continue or Ctrl+C to cancel..." _
echo ""

# ── Interactive prompts ───────────────────────────────────────────────────────
hdr "Configuration"

# qBittorrent password
while true; do
    echo -e "  ${CYAN}Set your qBittorrent WebUI password${RESET}"
    echo -e "  ${YELLOW}(min 6 characters — you'll use this to log into qBit)${RESET}"
    echo ""
    read -rsp "  Password: " QBIT_WEBUI_PASS
    echo ""
    if [[ ${#QBIT_WEBUI_PASS} -lt 6 ]]; then
        echo -e "  ${RED}Too short — must be at least 6 characters. Try again.${RESET}\n"
        continue
    fi
    read -rsp "  Confirm password: " PASS_CONFIRM
    echo ""
    if [[ "$QBIT_WEBUI_PASS" != "$PASS_CONFIRM" ]]; then
        echo -e "  ${RED}Passwords don't match. Try again.${RESET}\n"
        continue
    fi
    break
done
ok "Password set"
echo ""

# Unraid IP
echo -e "  ${CYAN}Enter your Unraid server IP address${RESET}"
echo -e "  ${YELLOW}(used to display the ssh-copy-id command at the end)${RESET}"
echo -e "  ${YELLOW}Press Enter to skip${RESET}"
echo ""
read -rp "  Unraid IP: " TB_UNRAID_IP
echo ""

# Confirm seed path
echo -e "  ${CYAN}Where should torrents be stored on this Pi?${RESET}"
echo -e "  ${YELLOW}Default: /mnt/seeds — Press Enter to accept${RESET}"
echo ""
read -rp "  Seed path [$SEED_ROOT]: " SEED_INPUT
[[ -n "$SEED_INPUT" ]] && SEED_ROOT="$SEED_INPUT"
echo ""

# Summary before proceeding
echo -e "${BOLD}  Summary:${RESET}"
echo -e "  • WebUI user     : $QBIT_WEBUI_USER"
echo -e "  • WebUI port     : $QBIT_WEB_PORT"
echo -e "  • Seed directory : $SEED_ROOT"
[[ -n "$TB_UNRAID_IP" ]] && echo -e "  • Unraid IP      : $TB_UNRAID_IP"
echo ""
read -rp "  Looks good? Press ENTER to start installation, Ctrl+C to cancel..." _
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
pkill -9 qbittorrent-nox 2>/dev/null || true
sleep 2

if ss -tlnp | grep -q ":${QBIT_WEB_PORT}"; then
    STALE_PID=$(ss -tlnp | grep ":${QBIT_WEB_PORT}" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    [[ -n "$STALE_PID" ]] && kill -9 "$STALE_PID" 2>/dev/null || true
    sleep 2
fi

if ss -tlnp | grep -q ":${QBIT_WEB_PORT}"; then
    err "Port $QBIT_WEB_PORT still in use after cleanup. Reboot the Pi and re-run."
fi
ok "Port $QBIT_WEB_PORT is free"

# =============================================================================
hdr "4 / 8  Configure seed storage"
mkdir -p "$SEED_ROOT"
chown "$REAL_USER:$REAL_USER" "$SEED_ROOT"
chmod 755 "$SEED_ROOT"

ROOT_FS=$(findmnt -n -o FSTYPE /)
if [[ "$ROOT_FS" == "ext4" ]]; then
    if ! grep -q "noatime" /etc/fstab; then
        cp /etc/fstab /etc/fstab.bak
        sed -i '/\s\/\s/s/defaults/defaults,noatime,nodiratime/' /etc/fstab
        ok "noatime added to fstab"
    else
        ok "noatime already set"
    fi
fi

mkdir -p "$QBIT_DATA_DIR/BT_backup"
mkdir -p "$QBIT_CONFIG_DIR"
chown -R "$REAL_USER:$REAL_USER" "$QBIT_DATA_DIR"
chown -R "$REAL_USER:$REAL_USER" "$QBIT_CONFIG_DIR"
ok "Storage configured at $SEED_ROOT"

# =============================================================================
hdr "5 / 8  Start qBittorrent and set password via API"

# Write minimal bootstrap config — no password hash, let qBit generate one
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

# Start qBit as real user, capture output to find temp password
QBIT_LOG=$(mktemp /tmp/qbit_init_XXXXXX.log)
log "Starting qBittorrent-nox to initialise (watching for temp password)..."
sudo -u "$REAL_USER" qbittorrent-nox --webui-port="$QBIT_WEB_PORT" > "$QBIT_LOG" 2>&1 &
QBIT_PID=$!

# Poll WebUI + watch log for temp password simultaneously
MAX_WAIT=40
WAITED=0
TEMP_PASS=""
WEB_UP=false

while [[ $WAITED -lt $MAX_WAIT ]]; do
    sleep 2
    WAITED=$((WAITED + 2))

    # Check if qBit printed a temporary password
    if [[ -z "$TEMP_PASS" ]]; then
        TEMP_PASS=$(grep -oP '(?<=temporary password is: )\S+' "$QBIT_LOG" 2>/dev/null | tail -1 || true)
        [[ -n "$TEMP_PASS" ]] && log "Found temporary password in log"
    fi

    # Check if WebUI is up
    if curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1; then
        WEB_UP=true
        ok "WebUI is up (${WAITED}s)"
        break
    fi
    log "Waiting for WebUI... (${WAITED}s)"
done

if [[ "$WEB_UP" != "true" ]]; then
    kill "$QBIT_PID" 2>/dev/null || true
    cat "$QBIT_LOG"
    err "WebUI did not come up after ${MAX_WAIT}s"
fi

# Try to login — first with temp password, then classic default
LOGIN_OK=false
for TRY_PASS in "$TEMP_PASS" "adminadmin" ""; do
    [[ -z "$TRY_PASS" ]] && continue
    RESP=$(curl -s -c /tmp/qbit_cookies.txt \
        -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/auth/login" \
        -d "username=$QBIT_WEBUI_USER&password=$TRY_PASS" 2>/dev/null || true)
    if [[ "$RESP" == "Ok." ]]; then
        log "Logged in with password: ${TRY_PASS:0:3}***"
        LOGIN_OK=true
        break
    fi
done

if [[ "$LOGIN_OK" == "true" ]]; then
    log "Setting your password via API..."
    curl -s -b /tmp/qbit_cookies.txt \
        -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/app/setPreferences" \
        -d "json=$(jq -n --arg p "$QBIT_WEBUI_PASS" '{web_ui_password: $p}')" > /dev/null 2>&1
    ok "Password set successfully via API"
else
    warn "Could not log in automatically to set password"
    warn "After setup, log in with admin / adminadmin (or check the temp password above)"
    warn "Then go to Settings → Web UI → Password to change it"
fi

# Clean up
kill "$QBIT_PID" 2>/dev/null || true
pkill -9 qbittorrent-nox 2>/dev/null || true
rm -f /tmp/qbit_cookies.txt "$QBIT_LOG"
sleep 3
ok "Bootstrap complete"

# =============================================================================
hdr "6 / 8  Apply full qBittorrent config"

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

[Core]
AutoDeleteAddedTorrentFile=Never
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
log "Waiting for service WebUI..."

WAITED=0
until curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1; do
    sleep 2; WAITED=$((WAITED+2))
    [[ $WAITED -ge 30 ]] && { warn "WebUI slow — check: systemctl status qbittorrent-nox"; break; }
done

curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1 && ok "Service running — WebUI confirmed" || warn "Service started but WebUI not yet responding"

# =============================================================================
hdr "8 / 8  SSH + system tuning"

systemctl enable ssh && systemctl start ssh
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

cat > /etc/security/limits.d/99-torrentbridge.conf << EOF
$REAL_USER  soft  nofile  65536
$REAL_USER  hard  nofile  65536
EOF
ok "File descriptor limits set"

dphys-swapfile swapoff 2>/dev/null || true
dphys-swapfile uninstall 2>/dev/null || true
systemctl disable dphys-swapfile 2>/dev/null || true
ok "Swap disabled"

modprobe zram 2>/dev/null || true
if lsmod | grep -q zram; then
    echo "zram" > /etc/modules-load.d/zram.conf
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zram-tools 2>/dev/null || true
    if [[ -f /etc/default/zramswap ]]; then
        printf 'ALGO=lz4\nPERCENT=50\n' > /etc/default/zramswap
        systemctl enable zramswap 2>/dev/null || true
        systemctl start zramswap 2>/dev/null && ok "zram enabled" || warn "zram failed to start — not critical"
    fi
else
    warn "zram module not available — skipping"
fi

# =============================================================================
hdr "Setup Complete!"

PI_IP=$(hostname -I | awk '{print $1}')
QBIT_RUNNING=$(systemctl is-active qbittorrent-nox 2>/dev/null || echo "unknown")

# Final login test
LOGIN_FINAL=$(curl -s -c /tmp/qbit_final.txt \
    -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/auth/login" \
    -d "username=$QBIT_WEBUI_USER&password=$QBIT_WEBUI_PASS" 2>/dev/null || true)
rm -f /tmp/qbit_final.txt

echo ""
echo -e "${GREEN}${BOLD}  ╔════════════════════════════════════════╗"
echo -e "  ║         Pi Seeder Node Ready!          ║"
echo -e "  ╚════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Pi IP        :${RESET} $PI_IP"
echo -e "  ${BOLD}qBit WebUI   :${RESET} http://$PI_IP:$QBIT_WEB_PORT"
echo -e "  ${BOLD}Username     :${RESET} $QBIT_WEBUI_USER"
echo -e "  ${BOLD}Service      :${RESET} $QBIT_RUNNING"
echo -e "  ${BOLD}Seed dir     :${RESET} $SEED_ROOT"
echo ""

if [[ "$LOGIN_FINAL" == "Ok." ]]; then
    echo -e "  ${GREEN}✓ WebUI login verified with your password${RESET}"
else
    echo -e "  ${YELLOW}⚠  Could not verify password — try: admin / adminadmin${RESET}"
    echo -e "     Or check: ${CYAN}journalctl -u qbittorrent-nox | grep -i password${RESET}"
fi

echo ""
echo -e "  ${YELLOW}━━━  Next Steps  ━━━${RESET}"
echo ""
echo -e "  ${BOLD}1. Authorize Unraid SSH key — run this on Unraid terminal:${RESET}"
echo -e "     ${CYAN}ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub $REAL_USER@$PI_IP${RESET}"
echo ""
echo -e "  ${BOLD}2. Test the key works:${RESET}"
echo -e "     ${CYAN}ssh -i /mnt/user/appdata/torrentbridge/ssh/id_migrate $REAL_USER@$PI_IP 'echo OK'${RESET}"
echo ""
if [[ -n "$TB_UNRAID_IP" ]]; then
echo -e "  ${BOLD}3. Open TorrentBridge on Unraid:${RESET}"
echo -e "     ${CYAN}http://$TB_UNRAID_IP:7474${RESET}"
echo ""
fi
echo -e "  ${BOLD}Reboot now?${RESET}"
read -rp "  Press ENTER to reboot, or Ctrl+C to skip: " _
reboot
