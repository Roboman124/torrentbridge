#!/usr/bin/env bash
# =============================================================================
#  TorrentBridge — Raspberry Pi 4 Setup Script v0.4.0
#  Usage: curl -fsSL https://raw.githubusercontent.com/roboman124/torrentbridge/main/pi/setup.sh | sudo bash
# =============================================================================

# ── If piped, re-download and exec with a real terminal ──────────────────────
if [ ! -t 0 ]; then
    SCRIPT_URL="https://raw.githubusercontent.com/roboman124/torrentbridge/main/pi/setup.sh"
    TMPFILE=$(mktemp /tmp/tb_setup_XXXXXX.sh)
    curl -fsSL "$SCRIPT_URL" -o "$TMPFILE"
    chmod +x "$TMPFILE"
    exec sudo bash "$TMPFILE" < /dev/tty
    exit 0
fi

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[TB]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!!]${RESET} $*"; }
err()  { echo -e "${RED}[ERR]${RESET} $*"; exit 1; }
hdr()  { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@" < /dev/tty
fi

# ── Detect real user ──────────────────────────────────────────────────────────
REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[[ -z "$REAL_HOME" ]] && REAL_HOME="/home/$REAL_USER"

# ── Defaults ──────────────────────────────────────────────────────────────────
QBIT_WEB_PORT=8080
QBIT_WEBUI_USER="admin"
QBIT_WEBUI_PASS="admin"        # User changes this after install via WebUI
SEED_ROOT="/mnt/seeds"
TB_UNRAID_IP=""

QBIT_CONFIG_DIR="$REAL_HOME/.config/qBittorrent"
QBIT_DATA_DIR="$REAL_HOME/.local/share/qBittorrent"

# =============================================================================
clear
echo -e "${BOLD}"
echo "  ╔════════════════════════════════════════╗"
echo "  ║     TorrentBridge Pi Setup v0.4.0      ║"
echo "  ║     Raspberry Pi 4 — Seeder Node       ║"
echo "  ╚════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${YELLOW}qBittorrent will be installed with:${RESET}"
echo -e "  • Username : ${BOLD}admin${RESET}"
echo -e "  • Password : ${BOLD}admin${RESET}"
echo -e "  ${YELLOW}You can change this in the WebUI after install.${RESET}"
echo ""

read -rp "  Press ENTER to continue or Ctrl+C to cancel..." _ < /dev/tty
echo ""

# ── Optional: Unraid IP ───────────────────────────────────────────────────────
hdr "Quick Config"
echo -e "  ${CYAN}Enter your Unraid IP address${RESET} (shown in next-steps at the end)"
echo -e "  ${YELLOW}Press Enter to skip${RESET}"
echo ""
read -rp "  Unraid IP: " TB_UNRAID_IP < /dev/tty
echo ""

echo -e "  ${CYAN}Seed storage path on this Pi${RESET}"
echo -e "  ${YELLOW}Press Enter to use default: /mnt/seeds${RESET}"
echo ""
read -rp "  Seed path [/mnt/seeds]: " SEED_INPUT < /dev/tty
[[ -n "$SEED_INPUT" ]] && SEED_ROOT="$SEED_INPUT"
echo ""

echo -e "${BOLD}  Ready to install with:${RESET}"
echo -e "  • Seed directory : $SEED_ROOT"
echo -e "  • WebUI port     : $QBIT_WEB_PORT"
[[ -n "$TB_UNRAID_IP" ]] && echo -e "  • Unraid IP      : $TB_UNRAID_IP"
echo ""
read -rp "  Press ENTER to begin installation..." _ < /dev/tty
echo ""

# =============================================================================
hdr "1 / 7  System update"
log "Updating package lists..."
apt-get update -qq
log "Upgrading packages (may take a few minutes)..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "System up to date"

# =============================================================================
hdr "2 / 7  Install packages"
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
hdr "3 / 7  Kill stale processes + free port"
pkill -9 qbittorrent-nox 2>/dev/null || true
sleep 2

if ss -tlnp | grep -q ":${QBIT_WEB_PORT}"; then
    STALE_PID=$(ss -tlnp | grep ":${QBIT_WEB_PORT}" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    [[ -n "$STALE_PID" ]] && kill -9 "$STALE_PID" 2>/dev/null || true
    sleep 2
fi

ss -tlnp | grep -q ":${QBIT_WEB_PORT}" && err "Port $QBIT_WEB_PORT still in use. Reboot and re-run."
ok "Port $QBIT_WEB_PORT is free"

# =============================================================================
hdr "4 / 7  Configure storage"
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
ok "Seed directory: $SEED_ROOT"

# =============================================================================
hdr "5 / 7  Configure qBittorrent"

# Write full config — use adminadmin as default, user changes it via WebUI
cat > "$QBIT_CONFIG_DIR/qBittorrent.conf" << EOF
[LegalNotice]
Accepted=true

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
ok "qBittorrent config written"

# =============================================================================
hdr "6 / 7  Start qBittorrent + set password"

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

log "Waiting for WebUI to respond..."
WAITED=0
until curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1; do
    sleep 2; WAITED=$((WAITED+2))
    if [[ $WAITED -ge 40 ]]; then
        warn "WebUI taking a long time — checking logs..."
        journalctl -u qbittorrent-nox --no-pager -n 10
        break
    fi
    log "  ${WAITED}s..."
done

if ! curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1; then
    warn "WebUI not responding — skipping password setup. Check after reboot."
else
    ok "WebUI is up"

    # qBit 5.x generates a random temp password on first run — find it
    TEMP_PASS=$(journalctl -u qbittorrent-nox --no-pager 2>/dev/null | \
        grep -oP '(?<=temporary password is: )\S+' | tail -1 || true)

    # Try logging in: temp password first, then classic defaults
    SESSION_COOKIE=""
    for TRY_PASS in "$TEMP_PASS" "adminadmin" "admin" ""; do
        [[ -z "$TRY_PASS" ]] && continue
        RESP=$(curl -s -c /tmp/qbit_cookies.txt \
            -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/auth/login" \
            -d "username=$QBIT_WEBUI_USER&password=$TRY_PASS" 2>/dev/null || true)
        if [[ "$RESP" == "Ok." ]]; then
            SESSION_COOKIE="/tmp/qbit_cookies.txt"
            log "Logged in (used: ${TRY_PASS:0:3}***)"
            break
        fi
    done

    if [[ -n "$SESSION_COOKIE" ]]; then
        # Set password to "admin" via API
        curl -s -b "$SESSION_COOKIE" \
            -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/app/setPreferences" \
            -d "json={\"web_ui_password\":\"$QBIT_WEBUI_PASS\"}" > /dev/null 2>&1 || true
        rm -f "$SESSION_COOKIE"

        # Verify the new password works
        VERIFY=$(curl -s \
            -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/auth/login" \
            -d "username=$QBIT_WEBUI_USER&password=$QBIT_WEBUI_PASS" 2>/dev/null || true)
        if [[ "$VERIFY" == "Ok." ]]; then
            ok "Password set and verified — login: admin / admin"
        else
            warn "Password API call sent but could not verify — try admin / admin in browser"
            warn "If that fails, check: journalctl -u qbittorrent-nox | grep -i password"
        fi
    else
        warn "Could not log in to set password automatically"
        warn "Check the temp password: journalctl -u qbittorrent-nox | grep -i password"
    fi
fi

# =============================================================================
hdr "7 / 7  SSH + system tuning"

systemctl enable ssh > /dev/null 2>&1
systemctl start ssh > /dev/null 2>&1
SSH_DIR="$REAL_HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$REAL_USER:$REAL_USER" "$SSH_DIR"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^PubkeyAuthentication" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
systemctl reload ssh > /dev/null 2>&1
ok "SSH configured"

# ── Optional: paste Unraid public key directly ────────────────────────────────
echo ""
echo -e "  ${CYAN}━━━  SSH Key Setup  ━━━${RESET}"
echo -e "  TorrentBridge needs SSH access to this Pi to transfer files."
echo ""
echo -e "  ${BOLD}Option A — Paste your Unraid public key now (easiest):${RESET}"
echo -e "  On your Unraid terminal run:"
echo -e "  ${CYAN}cat /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub${RESET}"
echo -e "  Then paste the output below and press ENTER, or press ENTER to skip."
echo ""
read -rp "  Paste public key (or press ENTER to skip): " PUBKEY < /dev/tty
echo ""

if [[ -n "$PUBKEY" ]]; then
    # Validate it looks like an SSH public key
    if echo "$PUBKEY" | grep -qE "^(ssh-ed25519|ssh-rsa|ecdsa-sha2) "; then
        echo "$PUBKEY" >> "$SSH_DIR/authorized_keys"
        chown "$REAL_USER:$REAL_USER" "$SSH_DIR/authorized_keys"
        ok "Public key added to authorized_keys"
        log "TorrentBridge on Unraid can now SSH into this Pi"
    else
        warn "That doesn't look like a valid SSH public key — skipping"
        warn "You can add it manually later: echo 'YOUR_KEY' >> $SSH_DIR/authorized_keys"
    fi
else
    echo -e "  ${YELLOW}Skipped — run this on Unraid terminal after setup:${RESET}"
    echo -e "  ${CYAN}ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub $REAL_USER@$(hostname -I | awk '{print $1}')${RESET}"
    echo ""
    read -rp "  Press ENTER to continue..." _ < /dev/tty
fi

# Kernel network tuning
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
ok "File limits set"

# Disable SD swap
dphys-swapfile swapoff 2>/dev/null || true
dphys-swapfile uninstall 2>/dev/null || true
systemctl disable dphys-swapfile 2>/dev/null || true
ok "SD swap disabled"

# zram
modprobe zram 2>/dev/null || true
if lsmod | grep -q zram; then
    echo "zram" > /etc/modules-load.d/zram.conf
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zram-tools 2>/dev/null || true
    printf 'ALGO=lz4\nPERCENT=50\n' > /etc/default/zramswap
    systemctl enable zramswap 2>/dev/null || true
    systemctl start zramswap 2>/dev/null && ok "zram swap enabled" || warn "zram failed — not critical"
else
    warn "zram not available on this kernel — skipping"
fi

# =============================================================================
hdr "Setup Complete!"

PI_IP=$(hostname -I | awk '{print $1}')
QBIT_STATUS=$(systemctl is-active qbittorrent-nox 2>/dev/null || echo "unknown")

echo ""
echo -e "${GREEN}${BOLD}  ╔════════════════════════════════════════╗"
echo -e "  ║         Pi Seeder Node Ready!          ║"
echo -e "  ╚════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Pi IP        :${RESET} $PI_IP"
echo -e "  ${BOLD}qBit WebUI   :${RESET} http://$PI_IP:$QBIT_WEB_PORT"
echo -e "  ${BOLD}Username     :${RESET} admin"
echo -e "  ${BOLD}Password     :${RESET} admin"
echo -e "  ${BOLD}Service      :${RESET} $QBIT_STATUS"
echo -e "  ${BOLD}Seed dir     :${RESET} $SEED_ROOT"
echo ""
echo -e "  ${RED}${BOLD}⚠  IMPORTANT: Change the default password!${RESET}"
echo -e "  Open the WebUI → Settings → Web UI → Password"
echo ""
echo -e "  ${YELLOW}━━━  Next Steps  ━━━${RESET}"
echo ""
echo -e "  ${BOLD}1. Generate SSH key on Unraid (if not done yet):${RESET}"
echo -e "     ${CYAN}mkdir -p /mnt/user/appdata/torrentbridge/ssh${RESET}"
echo -e "     ${CYAN}ssh-keygen -t ed25519 -f /mnt/user/appdata/torrentbridge/ssh/id_migrate -N \"\" -C \"torrentbridge@unraid\"${RESET}"
echo -e "     ${CYAN}chmod 600 /mnt/user/appdata/torrentbridge/ssh/id_migrate${RESET}"
echo ""
# Check if key was already added during setup
if grep -q "ssh-" "$SSH_DIR/authorized_keys" 2>/dev/null; then
echo -e "  ${GREEN}✓ SSH key already authorized on this Pi${RESET}"
echo ""
echo -e "  ${BOLD}2. Test the key works from Unraid terminal:${RESET}"
echo -e "     ${CYAN}ssh -i /mnt/user/appdata/torrentbridge/ssh/id_migrate $REAL_USER@$PI_IP 'echo OK'${RESET}"
else
echo -e "  ${BOLD}2. Authorize key on this Pi — run on Unraid terminal:${RESET}"
echo -e "     ${CYAN}ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub $REAL_USER@$PI_IP${RESET}"
echo ""
echo -e "  ${BOLD}3. Test the key works:${RESET}"
echo -e "     ${CYAN}ssh -i /mnt/user/appdata/torrentbridge/ssh/id_migrate $REAL_USER@$PI_IP 'echo OK'${RESET}"
fi
echo ""
if [[ -n "$TB_UNRAID_IP" ]]; then
echo -e "  ${BOLD}4. Open TorrentBridge on Unraid:${RESET}"
echo -e "     ${CYAN}http://$TB_UNRAID_IP:7474${RESET}"
echo ""
fi
echo -e "  ${BOLD}Reboot to apply all settings.${RESET}"
echo ""
read -rp "  Press ENTER to reboot now, or Ctrl+C to skip: " _ < /dev/tty
reboot
