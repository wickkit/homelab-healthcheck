#!/usr/bin/env bash
set -euo pipefail

# homelab-healthcheck installer
# Creates a dedicated user with minimal read-only permissions

INSTALL_DIR="/opt/homelab-healthcheck"
HC_USER="healthcheck"
SUDOERS_FILE="/etc/sudoers.d/healthcheck"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Pre-flight checks ---

if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root (use sudo)"
    exit 1
fi

if ! command -v apt-get &>/dev/null; then
    error "This installer requires apt-get (Debian/Ubuntu)"
    exit 1
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     homelab-healthcheck installer        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""

# --- Install dependencies ---

info "Installing dependencies..."
apt-get update -qq
for pkg in smartmontools jq curl; do
    if dpkg -s "$pkg" &>/dev/null; then
        ok "$pkg already installed"
    else
        apt-get install -y -qq "$pkg"
        ok "$pkg installed"
    fi
done

# --- Create user ---

if id "$HC_USER" &>/dev/null; then
    ok "User '$HC_USER' already exists"
else
    info "Creating system user '$HC_USER'..."
    useradd --system --create-home --home-dir "/home/$HC_USER" --shell /bin/bash "$HC_USER"
    ok "User '$HC_USER' created"
fi

# --- Group membership ---

for group in docker disk; do
    if getent group "$group" &>/dev/null; then
        if id -nG "$HC_USER" | grep -qw "$group"; then
            ok "$HC_USER already in '$group' group"
        else
            usermod -aG "$group" "$HC_USER"
            ok "Added $HC_USER to '$group' group"
        fi
    else
        warn "Group '$group' does not exist — skipping (install Docker first for 'docker' group)"
    fi
done

# --- Sudoers (restricted commands only) ---

info "Configuring sudoers for read-only commands..."
cat > "$SUDOERS_FILE" << 'EOF'
# homelab-healthcheck: restricted read-only commands
healthcheck ALL=(root) NOPASSWD: /usr/sbin/smartctl --health *
healthcheck ALL=(root) NOPASSWD: /usr/sbin/smartctl -a *
healthcheck ALL=(root) NOPASSWD: /usr/sbin/smartctl --scan
healthcheck ALL=(root) NOPASSWD: /usr/bin/apt-get update -qq
healthcheck ALL=(root) NOPASSWD: /usr/bin/journalctl --no-pager -p emerg+crit --since *
healthcheck ALL=(root) NOPASSWD: /usr/lib/update-notifier/apt-check *
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" &>/dev/null && ok "Sudoers configured" || { error "Sudoers syntax error"; rm -f "$SUDOERS_FILE"; exit 1; }

# --- Install script ---

info "Installing healthcheck script to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Find source directory (handles both clone and curl|bash)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/healthcheck.sh" ]]; then
    cp "$SCRIPT_DIR/healthcheck.sh" "$INSTALL_DIR/healthcheck.sh"
    cp "$SCRIPT_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true
else
    # Download from GitHub if running via curl|bash
    info "Downloading healthcheck.sh from GitHub..."
    curl -fsSL "https://raw.githubusercontent.com/wickkit/homelab-healthcheck/main/healthcheck.sh" -o "$INSTALL_DIR/healthcheck.sh"
    curl -fsSL "https://raw.githubusercontent.com/wickkit/homelab-healthcheck/main/uninstall.sh" -o "$INSTALL_DIR/uninstall.sh"
fi

chmod 755 "$INSTALL_DIR/healthcheck.sh"
chmod 755 "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true
chown -R "$HC_USER:$HC_USER" "$INSTALL_DIR"
ok "Scripts installed to $INSTALL_DIR"

# --- SSH key ---

SSH_DIR="/home/$HC_USER/.ssh"
KEY_FILE="$SSH_DIR/id_ed25519"

if [[ -f "$KEY_FILE" ]]; then
    ok "SSH key already exists"
else
    info "Generating SSH key pair..."
    mkdir -p "$SSH_DIR"
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "healthcheck@$(hostname)" -q
    chown -R "$HC_USER:$HC_USER" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$KEY_FILE"
    chmod 644 "$KEY_FILE.pub"
    ok "SSH key generated"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Public key (add to remote authorized_keys):${NC}"
echo ""
cat "$KEY_FILE.pub"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# --- Optionally accept an authorized key ---

echo ""
read -rp "Paste an SSH public key to authorize for remote access (or press Enter to skip): " AUTH_KEY
if [[ -n "$AUTH_KEY" ]]; then
    AUTHKEYS="$SSH_DIR/authorized_keys"
    echo "$AUTH_KEY" >> "$AUTHKEYS"
    chown "$HC_USER:$HC_USER" "$AUTHKEYS"
    chmod 600 "$AUTHKEYS"
    ok "Authorized key added"
fi

# --- State directory ---

STATE_DIR="/var/lib/homelab-healthcheck"
mkdir -p "$STATE_DIR"
chown "$HC_USER:$HC_USER" "$STATE_DIR"

# --- Done ---

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Installation complete!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  Run a health check:"
echo "    sudo -u $HC_USER $INSTALL_DIR/healthcheck.sh"
echo ""
echo "  Via SSH:"
echo "    ssh $HC_USER@$(hostname) $INSTALL_DIR/healthcheck.sh"
echo ""
echo "  Uninstall:"
echo "    sudo bash $INSTALL_DIR/uninstall.sh"
echo ""
