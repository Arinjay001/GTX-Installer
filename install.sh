#!/usr/bin/env bash
set -e

clear
echo "======================================"
echo "        GTX Panel Installer"
echo "======================================"

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo su"
  exit 1
fi

apt update -y
apt install -y curl bash

curl -fsSL https://raw.githubusercontent.com/Arinjay001/GTX-Installer/main/scripts/setup.sh -o /tmp/gtx-setup.sh
chmod +x /tmp/gtx-setup.sh
bash /tmp/gtx-setup.sh
