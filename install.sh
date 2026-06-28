#!/usr/bin/env bash

set -e

clear

echo "========================================================"
echo "              GTX Panel Installer"
echo "========================================================"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

echo "[1/6] Checking operating system..."

if [ ! -f /etc/os-release ]; then
    echo "Unsupported operating system."
    exit 1
fi

source /etc/os-release

echo "Detected: $PRETTY_NAME"

if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    echo "Only Ubuntu and Debian are currently supported."
    exit 1
fi

echo ""
echo "[2/6] Updating packages..."
apt update

echo ""
echo "[3/6] Installing curl..."
apt install -y curl

echo ""
echo "[4/6] Downloading GTX Installer..."

curl -fsSL https://raw.githubusercontent.com/Arinjay001/GTX-Installer/main/scripts/setup.sh -o /tmp/setup.sh

chmod +x /tmp/setup.sh

echo ""
echo "[5/6] Starting installer..."

bash /tmp/setup.sh

echo ""
echo "[6/6] Installation completed."
