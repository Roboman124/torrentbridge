#!/usr/bin/env bash
# =============================================================================
#  TorrentBridge — Raspberry Pi 4 Setup Script v0.6.0
#  Supports: AirVPN WireGuard + kill switch, ufw firewall, CGNAT detection
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
QBIT_WEBUI_PASS="admin"
SEED_ROOT="/mnt/seeds"
TB_UNRAID_IP=""
VPN_ENABLED=false
AIRVPN_PORT=6881          # updated if user sets a forwarded port
QBIT_LISTEN_PORT=6881
WG_CONF_PATH="/etc/wireguard/wg0.conf"

QBIT_CONFIG_DIR="$REAL_HOME/.config/qBittorrent"
QBIT_DATA_DIR="$REAL_HOME/.local/share/qBittorrent"

# =============================================================================
clear
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║    TorrentBridge Pi Setup  v0.6.0        ║"
echo "  ║    Raspberry Pi 4 — Seeder Node          ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${YELLOW}This script will install and configure:${RESET}"
echo "    • qBittorrent-nox (headless seeder)"
echo "    • AirVPN WireGuard (optional, recommended)"
echo "    • ufw firewall with kill switch"
echo "    • SSH access for TorrentBridge"
echo "    • System tuning for seeding"
echo ""
read -rp "  Press ENTER to start or Ctrl+C to cancel..." _ < /dev/tty
echo ""

# ── Quick config ──────────────────────────────────────────────────────────────
hdr "Quick Config"

echo -e "  ${CYAN}Unraid IP address${RESET} (shown in next-steps at the end)"
echo -e "  ${YELLOW}Press Enter to skip${RESET}"
read -rp "  Unraid IP: " TB_UNRAID_IP < /dev/tty
echo ""

echo -e "  ${CYAN}Seed storage path${RESET}"
read -rp "  Seed path [/mnt/seeds]: " SEED_INPUT < /dev/tty
[[ -n "$SEED_INPUT" ]] && SEED_ROOT="$SEED_INPUT"
echo ""

# ── AirVPN prompt (early, so user can prepare) ────────────────────────────────
echo -e "  ${CYAN}Do you want to set up AirVPN WireGuard?${RESET}"
echo -e "  ${YELLOW}Strongly recommended — routes seeding through VPN with kill switch${RESET}"
echo ""
read -rp "  Set up AirVPN? [Y/n]: " VPN_ANSWER < /dev/tty
echo ""
if [[ "${VPN_ANSWER,,}" != "n" && "${VPN_ANSWER,,}" != "no" ]]; then
    VPN_ENABLED=true
    echo -e "  ${BOLD}Before continuing, do these steps on your phone/computer:${RESET}"
    echo ""
    echo -e "  ${BOLD}Step A — Get your WireGuard config from AirVPN:${RESET}"
    echo -e "  1. Go to ${CYAN}https://airvpn.org${RESET} → login"
    echo -e "  2. Client Area → ${CYAN}Config Generator${RESET}"
    echo -e "  3. Select: ${BOLD}Linux${RESET} · ${BOLD}WireGuard${RESET}"
    echo -e "  4. Pick a server (choose one close to you)"
    echo -e "  5. Click ${BOLD}Generate${RESET} — keep this page open"
    echo ""
    echo -e "  ${BOLD}Step B — Forward a port in AirVPN (for seeding):${RESET}"
    echo -e "  1. Client Area → ${CYAN}Ports${RESET}"
    echo -e "  2. Click ${BOLD}Add port${RESET} — note the port number"
    echo -e "  This port will be your qBittorrent listen port"
    echo ""
    echo -e "  ${YELLOW}Take your time — this setup will wait for you.${RESET}"
    echo ""
    read -rp "  Press ENTER when you have both the config and the port number ready..." _ < /dev/tty
fi

echo ""
echo -e "${BOLD}  Ready to install:${RESET}"
echo -e "  • Seed directory : $SEED_ROOT"
echo -e "  • WebUI port     : $QBIT_WEB_PORT"
echo -e "  • AirVPN VPN     : $( [[ "$VPN_ENABLED" == true ]] && echo "Yes (WireGuard)" || echo "No" )"
[[ -n "$TB_UNRAID_IP" ]] && echo -e "  • Unraid IP      : $TB_UNRAID_IP"
echo ""
read -rp "  Press ENTER to begin installation..." _ < /dev/tty
echo ""

# =============================================================================
hdr "1 / 9  System update"
log "Updating package lists..."
apt-get update -qq
log "Upgrading packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "System up to date"

# =============================================================================
hdr "2 / 9  Install packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    qbittorrent-nox \
    wireguard-tools \
    rsync \
    curl \
    jq \
    htop \
    openssh-server \
    ca-certificates \
    avahi-daemon \
    ufw \
    procps \
    net-tools \
    resolvconf

QBIT_VER=$(qbittorrent-nox --version 2>/dev/null | head -1 || echo "unknown")
ok "Packages installed — $QBIT_VER"

# resolvconf must be running before WireGuard tries to set DNS
systemctl enable resolvconf > /dev/null 2>&1 || true
systemctl start  resolvconf > /dev/null 2>&1 || true

# =============================================================================
hdr "3 / 9  Kill stale processes"
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
hdr "4 / 9  Configure storage"
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
ok "Seed directory ready: $SEED_ROOT"

# =============================================================================
hdr "5 / 9  AirVPN WireGuard setup"

if [[ "$VPN_ENABLED" == true ]]; then

    # ── Collect WireGuard config ──────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Paste your AirVPN WireGuard config below.${RESET}"
    echo -e "  Copy the full config from airvpn.org Config Generator."
    echo -e "  ${YELLOW}When done, type ${BOLD}END${RESET}${YELLOW} on a new line and press ENTER.${RESET}"
    echo ""

    WG_LINES=()
    while IFS= read -r line < /dev/tty; do
        [[ "$line" == "END" ]] && break
        WG_LINES+=("$line")
    done
    WG_CONFIG=$(printf '%s\n' "${WG_LINES[@]}")

    # Validate it looks like a WireGuard config
    if ! echo "$WG_CONFIG" | grep -q "\[Interface\]"; then
        err "That doesn't look like a valid WireGuard config (missing [Interface] section). Re-run the script."
    fi
    if ! echo "$WG_CONFIG" | grep -q "PrivateKey"; then
        err "Config missing PrivateKey. Make sure you copied the full config."
    fi
    ok "WireGuard config received"

    # ── Get AirVPN forwarded port ─────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Enter the port number you forwarded in AirVPN Client Area → Ports${RESET}"
    echo -e "  ${YELLOW}This will be your qBittorrent listen port.${RESET}"
    echo -e "  ${YELLOW}Press Enter to use default 6881 (only if you have no forwarded port)${RESET}"
    echo ""
    read -rp "  AirVPN forwarded port: " PORT_INPUT < /dev/tty
    if [[ -n "$PORT_INPUT" ]] && [[ "$PORT_INPUT" =~ ^[0-9]+$ ]]; then
        AIRVPN_PORT="$PORT_INPUT"
        QBIT_LISTEN_PORT="$PORT_INPUT"
        ok "Forwarded port: $AIRVPN_PORT"
    else
        warn "No port entered — using 6881 (seeding may be limited without a forwarded port)"
    fi

    # ── Write WireGuard config ────────────────────────────────────────────────
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    # Extract the VPN endpoint IP so we can allow it through the kill switch
    VPN_ENDPOINT_IP=$(echo "$WG_CONFIG" | grep "^Endpoint" | grep -oP '[\d.]+' | head -1 || true)

    # Write the config with kill switch PostUp/PreDown rules
    # Kill switch: block all non-VPN traffic except:
    # - loopback
    # - local LAN (for SSH from Unraid)
    # - the WireGuard endpoint itself (so WireGuard can reconnect)
    LOCAL_SUBNET=$(ip route | grep -v default | grep -oP '[\d.]+/[\d]+' | grep -v '127\.' | head -1 || echo "192.168.0.0/16")

    cat > "$WG_CONF_PATH" << WGEOF
$WG_CONFIG
WGEOF

    # Append kill switch rules at end of [Interface] section
    # We do this by rewriting with PostUp/PreDown added
    python3 - << PYEOF
import re

with open('$WG_CONF_PATH', 'r') as f:
    cfg = f.read()

kill_switch = """PostUp   = iptables -I OUTPUT ! -o wg0 -m mark ! --mark \$(wg show wg0 fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
PostUp   = iptables -I OUTPUT -d $LOCAL_SUBNET -j ACCEPT
PostUp   = ip6tables -I OUTPUT ! -o wg0 -m mark ! --mark \$(wg show wg0 fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
PreDown  = iptables -D OUTPUT ! -o wg0 -m mark ! --mark \$(wg show wg0 fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
PreDown  = iptables -D OUTPUT -d $LOCAL_SUBNET -j ACCEPT
PreDown  = ip6tables -D OUTPUT ! -o wg0 -m mark ! --mark \$(wg show wg0 fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
"""

# Insert after [Interface] block's last existing line before [Peer]
cfg = cfg.replace('[Peer]', kill_switch + '\n[Peer]', 1)
with open('$WG_CONF_PATH', 'w') as f:
    f.write(cfg)
print('Kill switch rules added')
PYEOF

    chmod 600 "$WG_CONF_PATH"
    ok "WireGuard config written to $WG_CONF_PATH"

    # ── Start WireGuard ───────────────────────────────────────────────────────
    log "Enabling WireGuard kernel module..."
    modprobe wireguard 2>/dev/null || true

    log "Starting WireGuard tunnel (wg0)..."
    if wg-quick up wg0 2>&1; then
        ok "WireGuard tunnel up"
    else
        warn "WireGuard failed to start — check your config"
        warn "You can debug with: sudo wg-quick up wg0"
        warn "Continuing without VPN — fix it after setup"
        VPN_ENABLED=false
    fi

    # Enable WireGuard on boot
    systemctl enable wg-quick@wg0
    ok "WireGuard enabled on boot"

    # ── Verify VPN is working ─────────────────────────────────────────────────
    sleep 3
    VPN_IP=$(ip addr show wg0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || echo "")
    PUBLIC_IP_VPN=$(curl -s --max-time 8 --interface wg0 ifconfig.me 2>/dev/null || echo "")

    if [[ -n "$VPN_IP" ]]; then
        ok "WireGuard interface: wg0 ($VPN_IP)"
        if [[ -n "$PUBLIC_IP_VPN" ]]; then
            ok "VPN public IP: $PUBLIC_IP_VPN"
        fi
    else
        warn "wg0 interface not found — VPN may not be working correctly"
    fi

else
    ok "AirVPN skipped — using direct connection"
fi

# =============================================================================
hdr "6 / 9  Configure qBittorrent"

# Determine network interface for qBit to bind to
if [[ "$VPN_ENABLED" == true ]]; then
    QBIT_INTERFACE="wg0"
    log "qBittorrent will bind to VPN interface (wg0)"
    log "Listen port: $QBIT_LISTEN_PORT (AirVPN forwarded port)"
else
    QBIT_INTERFACE=""
    log "qBittorrent will use default interface"
fi

cat > "$QBIT_CONFIG_DIR/qBittorrent.conf" << EOF
[LegalNotice]
Accepted=true

[BitTorrent]
Session\DefaultSavePath=$SEED_ROOT
Session\MaxActiveCheckingTorrents=1
Session\MaxActiveDownloads=0
Session\MaxActiveTorrents=2000
Session\MaxActiveUploads=2000
Session\MaxConnections=400
Session\MaxConnectionsPerTorrent=8
Session\MaxUploads=-1
Session\MaxUploadsPerTorrent=-1
Session\Port=$QBIT_LISTEN_PORT
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

# Bind to VPN interface if configured
if [[ -n "$QBIT_INTERFACE" ]]; then
    cat >> "$QBIT_CONFIG_DIR/qBittorrent.conf" << EOF
Connection\Interface=$QBIT_INTERFACE
Connection\InterfaceAddress=
Connection\InterfaceName=$QBIT_INTERFACE
EOF
fi

chown "$REAL_USER:$REAL_USER" "$QBIT_CONFIG_DIR/qBittorrent.conf"
ok "qBittorrent config written"

# =============================================================================
hdr "7 / 9  Start qBittorrent + set password"

# Service file — if VPN enabled, start after wg0 is up
if [[ "$VPN_ENABLED" == true ]]; then
    AFTER_LINE="After=network-online.target wg-quick@wg0.service"
    WANTS_LINE="Wants=network-online.target wg-quick@wg0.service"
else
    AFTER_LINE="After=network-online.target"
    WANTS_LINE="Wants=network-online.target"
fi

cat > /etc/systemd/system/qbittorrent-nox.service << EOF
[Unit]
Description=qBittorrent-nox (TorrentBridge Seeder)
$AFTER_LINE
$WANTS_LINE

[Service]
Type=simple
User=$REAL_USER
Group=$REAL_USER
UMask=0002
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$QBIT_WEB_PORT
Restart=on-failure
RestartSec=15
TimeoutStopSec=30
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable qbittorrent-nox
systemctl start qbittorrent-nox

log "Waiting for WebUI..."
WAITED=0
until curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1; do
    sleep 2; WAITED=$((WAITED+2))
    [[ $WAITED -ge 40 ]] && { warn "WebUI slow — check: systemctl status qbittorrent-nox"; break; }
done

if curl -sf "http://localhost:$QBIT_WEB_PORT" > /dev/null 2>&1; then
    ok "WebUI is up"
    # Set password via API
    TEMP_PASS=$(journalctl -u qbittorrent-nox --no-pager 2>/dev/null | \
        grep -oP '(?<=temporary password is: )\S+' | tail -1 || true)
    SESSION=""
    for TRY_PASS in "$TEMP_PASS" "adminadmin" "admin"; do
        [[ -z "$TRY_PASS" ]] && continue
        RESP=$(curl -s -c /tmp/qbit_cookies.txt \
            -X POST "http://localhost:$QBIT_WEB_PORT/api/v2/auth/login" \
            -d "username=$QBIT_WEBUI_USER&password=$TRY_PASS" 2>/dev/null || true)
        if [[ "$RESP" == "Ok." ]]; then
            SESSION="/tmp/qbit_cookies.txt"; break
        fi
    done
    if [[ -n "$SESSION" ]]; then
        curl -s -b "$SESSION" -X POST \
            "http://localhost:$QBIT_WEB_PORT/api/v2/app/setPreferences" \
            -d "json={\"web_ui_password\":\"$QBIT_WEBUI_PASS\"}" > /dev/null 2>&1 || true
        rm -f "$SESSION"
        ok "Password set — login: admin / admin"
    else
        warn "Could not set password — try: admin / adminadmin in browser"
    fi
else
    warn "WebUI not responding — check after reboot: systemctl status qbittorrent-nox"
fi

# =============================================================================
hdr "8 / 9  SSH + system tuning"

systemctl enable ssh > /dev/null 2>&1
systemctl start ssh > /dev/null 2>&1

SSH_DIR="$REAL_HOME/.ssh"
mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"; chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$REAL_USER:$REAL_USER" "$SSH_DIR"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^PubkeyAuthentication" /etc/ssh/sshd_config || \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
systemctl reload ssh > /dev/null 2>&1
ok "SSH configured"

# ── Paste Unraid public key ───────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}━━━  SSH Key Setup  ━━━${RESET}"
echo -e "  Paste your Unraid SSH public key to authorize TorrentBridge."
echo -e "  On Unraid terminal: ${CYAN}cat /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub${RESET}"
echo -e "  ${YELLOW}Press ENTER to skip${RESET}"
echo ""
read -rp "  Paste public key: " PUBKEY < /dev/tty
echo ""

if [[ -n "$PUBKEY" ]]; then
    if echo "$PUBKEY" | grep -qE "^(ssh-ed25519|ssh-rsa|ecdsa-sha2) "; then
        echo "$PUBKEY" >> "$SSH_DIR/authorized_keys"
        chown "$REAL_USER:$REAL_USER" "$SSH_DIR/authorized_keys"
        ok "SSH key authorized"
    else
        warn "Doesn't look like a valid SSH key — skipping"
    fi
else
    PI_IP_TEMP=$(hostname -I | awk '{print $1}')
    warn "Skipped — run this on Unraid later:"
    echo -e "  ${CYAN}ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub $REAL_USER@$PI_IP_TEMP${RESET}"
fi

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
ok "Kernel tuned"

cat > /etc/security/limits.d/99-torrentbridge.conf << EOF
$REAL_USER  soft  nofile  65536
$REAL_USER  hard  nofile  65536
EOF
ok "File limits set"

dphys-swapfile swapoff 2>/dev/null || true
dphys-swapfile uninstall 2>/dev/null || true
systemctl disable dphys-swapfile 2>/dev/null || true
ok "SD swap disabled"

modprobe zram 2>/dev/null || true
if lsmod | grep -q zram; then
    echo "zram" > /etc/modules-load.d/zram.conf
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zram-tools 2>/dev/null || true
    printf 'ALGO=lz4\nPERCENT=50\n' > /etc/default/zramswap
    systemctl enable zramswap 2>/dev/null || true
    systemctl start zramswap 2>/dev/null && ok "zram enabled" || warn "zram failed — not critical"
else
    warn "zram not available — skipping"
fi

# =============================================================================
hdr "9 / 9  Firewall"

PI_IP=$(hostname -I | awk '{print $1}')
LOCAL_NET=$(echo "$PI_IP" | cut -d. -f1-3).0/24

ufw --force reset > /dev/null 2>&1
ufw default deny incoming  > /dev/null 2>&1

if [[ "$VPN_ENABLED" == true ]]; then
    # ── VPN kill switch mode ──────────────────────────────────────────────────
    # Default: deny ALL outgoing (kill switch)
    ufw default deny outgoing > /dev/null 2>&1

    # Allow loopback
    ufw allow in  on lo > /dev/null 2>&1
    ufw allow out on lo > /dev/null 2>&1

    # Allow all traffic through the VPN tunnel
    ufw allow in  on wg0 > /dev/null 2>&1
    ufw allow out on wg0 > /dev/null 2>&1

    # Allow WireGuard UDP (so tunnel can establish/reconnect)
    VPN_ENDPOINT=$(grep "^Endpoint" "$WG_CONF_PATH" | awk '{print $3}' | cut -d: -f1 || echo "")
    VPN_ENDPOINT_PORT=$(grep "^Endpoint" "$WG_CONF_PATH" | awk '{print $3}' | cut -d: -f2 || echo "1637")
    if [[ -n "$VPN_ENDPOINT" ]]; then
        ufw allow out to "$VPN_ENDPOINT" port "$VPN_ENDPOINT_PORT" proto udp > /dev/null 2>&1
        log "WireGuard endpoint allowed: $VPN_ENDPOINT:$VPN_ENDPOINT_PORT"
    fi

    # Allow SSH from local network only (so Unraid can rsync)
    ufw allow in  from "$LOCAL_NET" to any port 22   proto tcp
    ufw allow out to   "$LOCAL_NET" > /dev/null 2>&1
    ufw allow in  from "$LOCAL_NET" to any port "$QBIT_WEB_PORT" proto tcp > /dev/null 2>&1

    ufw --force enable
    echo ""
    ok "Firewall enabled with VPN kill switch"
    echo -e "  ${YELLOW}All traffic blocked except through VPN tunnel${RESET}"
    echo -e "  ${YELLOW}qBittorrent only works when AirVPN is connected${RESET}"
else
    # ── Standard mode (no VPN) ────────────────────────────────────────────────
    ufw default allow outgoing > /dev/null 2>&1
    ufw allow 22/tcp   comment 'SSH'
    ufw allow "$QBIT_WEB_PORT"/tcp comment 'qBittorrent WebUI'
    ufw allow 6881/tcp comment 'BitTorrent TCP'
    ufw allow 6881/udp comment 'BitTorrent UDP (DHT)'
    ufw --force enable

    # ── CGNAT check ───────────────────────────────────────────────────────────
    echo ""
    log "Checking for CGNAT..."
    PUBLIC_IP=$(curl -s --max-time 6 ifconfig.me 2>/dev/null || echo "")
    GATEWAY_IP=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1 || echo "")
    CGNAT=false
    if [[ -n "$GATEWAY_IP" ]]; then
        if echo "$GATEWAY_IP" | grep -qE '^100\.(6[4-9]|[7-9][0-9]|1[0-2][0-9])\.|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.'; then
            CGNAT=true
        fi
    fi

    echo ""
    if [[ "$CGNAT" == "true" ]]; then
        echo -e "${YELLOW}${BOLD}  ⚠  CGNAT detected — port forwarding will NOT work${RESET}"
        echo -e "${YELLOW}  Consider running this script again and choosing AirVPN.${RESET}"
    else
        echo -e "${GREEN}  ✓ No CGNAT — add this port forward to your router:${RESET}"
        echo ""
        echo -e "  ┌──────────────────────────────────────────────┐"
        echo -e "  │  External port : ${CYAN}6881${RESET}                          │"
        echo -e "  │  Internal IP   : ${CYAN}$PI_IP${RESET}                  │"
        echo -e "  │  Internal port : ${CYAN}6881${RESET}                          │"
        echo -e "  │  Protocol      : ${CYAN}TCP + UDP${RESET} (both!)             │"
        echo -e "  └──────────────────────────────────────────────┘"
        echo ""
        echo -e "  Test: ${CYAN}https://canyouseeme.org${RESET} → port 6881"
    fi
fi

echo ""
ok "Firewall configured"
ufw status verbose
echo ""

# =============================================================================
hdr "Setup Complete!"

QBIT_STATUS=$(systemctl is-active qbittorrent-nox 2>/dev/null || echo "unknown")
WG_STATUS=$( [[ "$VPN_ENABLED" == true ]] && \
    (wg show wg0 2>/dev/null | grep -q "latest handshake" && echo "connected" || echo "check needed") \
    || echo "not configured" )

echo ""
echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════╗"
echo -e "  ║         Pi Seeder Node Ready!            ║"
echo -e "  ╚══════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Pi IP        :${RESET} $PI_IP"
echo -e "  ${BOLD}qBit WebUI   :${RESET} http://$PI_IP:$QBIT_WEB_PORT"
echo -e "  ${BOLD}Username     :${RESET} admin"
echo -e "  ${BOLD}Password     :${RESET} admin"
echo -e "  ${BOLD}qBit service :${RESET} $QBIT_STATUS"
echo -e "  ${BOLD}Listen port  :${RESET} $QBIT_LISTEN_PORT"
echo -e "  ${BOLD}Seed dir     :${RESET} $SEED_ROOT"
echo -e "  ${BOLD}AirVPN       :${RESET} $WG_STATUS"
echo ""

if [[ "$VPN_ENABLED" == true ]]; then
    echo -e "  ${GREEN}${BOLD}✓ AirVPN WireGuard configured${RESET}"
    if [[ -n "${AIRVPN_PORT:-}" ]] && [[ "$AIRVPN_PORT" != "6881" ]]; then
        echo -e "  ${GREEN}✓ Forwarded port $AIRVPN_PORT set in qBittorrent${RESET}"
    else
        echo -e "  ${YELLOW}⚠  Remember to set your forwarded port in qBittorrent:${RESET}"
        echo -e "     WebUI → Settings → Connection → Listening Port"
    fi
    echo ""
    echo -e "  ${CYAN}VPN status commands:${RESET}"
    echo -e "  ${CYAN}sudo wg show${RESET}                    — show VPN connection"
    echo -e "  ${CYAN}curl --interface wg0 ifconfig.me${RESET} — check VPN IP"
    echo -e "  ${CYAN}sudo systemctl status wg-quick@wg0${RESET} — service status"
    echo ""
fi

echo -e "  ${RED}${BOLD}⚠  Change the default password!${RESET}"
echo -e "  WebUI → Settings → Web UI → Password"
echo ""
echo -e "  ${YELLOW}━━━  SSH Key for TorrentBridge  ━━━${RESET}"
echo ""
if grep -q "ssh-" "$SSH_DIR/authorized_keys" 2>/dev/null; then
    echo -e "  ${GREEN}✓ SSH key already authorized${RESET}"
    echo ""
    echo -e "  ${BOLD}Test from Unraid terminal:${RESET}"
    echo -e "  ${CYAN}ssh -i /mnt/user/appdata/torrentbridge/ssh/id_migrate $REAL_USER@$PI_IP 'echo OK'${RESET}"
else
    echo -e "  ${BOLD}1. Generate key on Unraid (if not done):${RESET}"
    echo -e "  ${CYAN}mkdir -p /mnt/user/appdata/torrentbridge/ssh${RESET}"
    echo -e "  ${CYAN}ssh-keygen -t ed25519 -f /mnt/user/appdata/torrentbridge/ssh/id_migrate -N \"\"${RESET}"
    echo ""
    echo -e "  ${BOLD}2. Authorize on this Pi:${RESET}"
    echo -e "  ${CYAN}ssh-copy-id -i /mnt/user/appdata/torrentbridge/ssh/id_migrate.pub $REAL_USER@$PI_IP${RESET}"
fi
echo ""
[[ -n "$TB_UNRAID_IP" ]] && echo -e "  ${BOLD}TorrentBridge UI:${RESET} ${CYAN}http://$TB_UNRAID_IP:7474${RESET}" && echo ""

echo -e "  ${BOLD}Reboot to apply all settings.${RESET}"
echo ""
read -rp "  Press ENTER to reboot now, or Ctrl+C to skip: " _ < /dev/tty
reboot
