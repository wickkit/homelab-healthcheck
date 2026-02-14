#!/usr/bin/env bash
set -euo pipefail

# homelab-healthcheck uninstaller

HC_USER="healthcheck"
INSTALL_DIR="/opt/homelab-healthcheck"
SUDOERS_FILE="/etc/sudoers.d/healthcheck"
STATE_DIR="/var/lib/homelab-healthcheck"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Must be run as root (use sudo)" >&2
    exit 1
fi

echo ""
echo -e "${YELLOW}This will remove:${NC}"
echo "  - User: $HC_USER (and home directory)"
echo "  - Sudoers: $SUDOERS_FILE"
echo "  - Scripts: $INSTALL_DIR"
echo "  - State: $STATE_DIR"
echo ""
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Remove user
if id "$HC_USER" &>/dev/null; then
    userdel -r "$HC_USER" 2>/dev/null || userdel "$HC_USER"
    echo -e "${GREEN}[OK]${NC} User '$HC_USER' removed"
else
    echo -e "${YELLOW}[SKIP]${NC} User '$HC_USER' does not exist"
fi

# Remove sudoers
if [[ -f "$SUDOERS_FILE" ]]; then
    rm -f "$SUDOERS_FILE"
    echo -e "${GREEN}[OK]${NC} Sudoers entry removed"
fi

# Remove installed scripts
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}[OK]${NC} Scripts removed from $INSTALL_DIR"
fi

# Remove state
if [[ -d "$STATE_DIR" ]]; then
    rm -rf "$STATE_DIR"
    echo -e "${GREEN}[OK]${NC} State directory removed"
fi

echo ""
echo -e "${GREEN}Uninstall complete.${NC}"
echo "Note: smartmontools and jq were not removed (may be used by other software)."
echo ""
