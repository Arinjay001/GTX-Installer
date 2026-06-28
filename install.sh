#!/usr/bin/env bash
set -Eeuo pipefail

GTX_VERSION="1.1.1"
GTX_REPO_DEFAULT="https://github.com/Arinjay001/GTX-panel.git"
GTX_INSTALL_DIR_DEFAULT="/var/www/gtx-panel"
GTX_SERVICE="gtx-panel"
GTX_PORT_DEFAULT="3000"
GTX_LOG_DIR="/var/log/gtx-installer"
GTX_LOG_FILE="$GTX_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"

GTX_INSTALL_DIR="$GTX_INSTALL_DIR_DEFAULT"
GTX_PANEL_REPO="$GTX_REPO_DEFAULT"
GTX_PANEL_PORT="$GTX_PORT_DEFAULT"
GTX_SSL_MODE="nginx"
GTX_DB_MODE="sqlite"
GTX_PRIVATE_REPO="no"
GTX_GITHUB_TOKEN=""
GTX_LICENSE_SERVER_URL=""
GTX_PUBLIC_IP=""
GTX_ADMIN_EMAIL=""
GTX_ADMIN_PASSWORD=""

mkdir -p "$GTX_LOG_DIR"
touch "$GTX_LOG_FILE"
exec > >(tee -a "$GTX_LOG_FILE") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

red(){ echo -e "${RED}$1${NC}"; }
green(){ echo -e "${GREEN}$1${NC}"; }
yellow(){ echo -e "${YELLOW}$1${NC}"; }
cyan(){ echo -e "${CYAN}$1${NC}"; }
bold(){ echo -e "${BOLD}$1${NC}"; }
line(){ echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"; }

on_error() {
red "Installation failed at line $1"
yellow "Command: $2"
yellow "Log file: $GTX_LOG_FILE"
exit 1
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

logo() {
clear || true
cyan "   ____ _______  __  _____                  *"
cyan "  / __*|*   *\ \/ / |  _ \ __ _ _ __   __*| |"
cyan " | |  _  | |  \  /  | |*) / *` | '* \ / _ \ |"
cyan " | |*| | | |  /  \  |  __/ (*| | | | |  **/ |"
cyan "  \****| |*| /*/\*\ |*|   \**,*|*| |*|\***|_|"
echo
bold "              GTX Panel Installer v$GTX_VERSION"
line
}

ask() {
local prompt="$1"
local default="${2:-}"
local var
if [[ -n "$default" ]]; then
read -rp "$prompt [$default]: " var
echo "${var:-$default}"
else
read -rp "$prompt: " var
echo "$var"
fi
}

ask_secret() {
local prompt="$1"
local var
read -rsp "$prompt: " var
echo >&2
echo "$var"
}

confirm() {
local ans
read -rp "$1 [y/N]: " ans
[[ "$ans" =~ ^[Yy]$ ]]
}

require_root() {
if [[ "$EUID" -ne 0 ]]; then
red "Run as root: sudo su"
exit 1
fi
}

check_os() {
logo
if [[ ! -f /etc/os-release ]]; then
red "Unsupported OS."
exit 1
fi

source /etc/os-release
echo "Detected: $PRETTY_NAME"

case "$ID" in
ubuntu|debian) green "OS supported." ;;
*) red "Only Ubuntu/Debian supported."; exit 1 ;;
esac
}

system_report() {
logo
bold "System report"
line
echo "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
echo "CPU: $(nproc) cores"
echo "RAM: $(free -h | awk '/Mem:/ {print $2}')"
echo "Disk: $(df -h / | awk 'NR==2 {print $4 " free / " $2 " total"}')"
GTX_PUBLIC_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "127.0.0.1")
echo "Public IP: $GTX_PUBLIC_IP"
line
}

preflight_checks() {
bold "Running preflight checks"
line

local ram_mb disk_gb
ram_mb=$(free -m | awk '/Mem:/ {print $2}')
disk_gb=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')

if (( ram_mb < 900 )); then yellow "RAM low. Recommended 2GB+."; else green "RAM OK."; fi
if (( disk_gb < 5 )); then red "Need at least 5GB free disk."; exit 1; else green "Disk OK."; fi
command -v systemctl >/dev/null 2>&1 || { red "systemd not found."; exit 1; }

green "Preflight complete."
}

install_base_packages() {
logo
bold "Installing base packages"
line

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git unzip zip tar ca-certificates gnupg lsb-release software-properties-common 
build-essential python3 make g++ nano openssl ufw jq nginx redis-server

systemctl enable --now redis-server || true
systemctl enable --now nginx || true

green "Base packages installed."
}

install_nodejs() {
logo
bold "Installing Node.js 22"
line

if command -v node >/dev/null 2>&1; then
local major
major=$(node -v | sed 's/v//' | cut -d. -f1)
if (( major >= 22 )); then
green "Node.js $(node -v) already installed."
npm install -g npm@11 || true
return 0
fi
fi

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g npm@11 || true

node -v
npm -v
}

install_docker() {
logo
bold "Installing Docker"
line

if command -v docker >/dev/null 2>&1; then
green "Docker already installed."
systemctl enable --now docker || true
return 0
fi

apt-get install -y docker.io docker-compose docker-compose-v2 || apt-get install -y docker.io docker-compose
systemctl enable --now docker
docker --version || true
}

collect_install_details() {
logo
bold "GTX Panel configuration"
line

GTX_INSTALL_DIR=$(ask "Install directory" "$GTX_INSTALL_DIR_DEFAULT")
GTX_PANEL_REPO=$(ask "GTX Panel repository" "$GTX_REPO_DEFAULT")
GTX_PANEL_PORT=$(ask "Panel internal port" "$GTX_PORT_DEFAULT")
GTX_PANEL_DOMAIN=$(ask "Panel domain or IP" "${GTX_PUBLIC_IP:-127.0.0.1}")
GTX_ADMIN_EMAIL=$(ask "Admin email" "[admin@gtxpanel.local](mailto:admin@gtxpanel.local)")

while [[ -z "$GTX_ADMIN_PASSWORD" ]]; do
GTX_ADMIN_PASSWORD=$(ask_secret "Admin password")
if [[ ${#GTX_ADMIN_PASSWORD} -lt 8 ]]; then
red "Password must be at least 8 characters."
GTX_ADMIN_PASSWORD=""
fi
done

echo
echo "SSL mode:"
echo "1) Direct port only"
echo "2) Nginx reverse proxy HTTP"
echo "3) Let's Encrypt SSL"
read -rp "Choose [2]: " ssl_choice

case "${ssl_choice:-2}" in
1) GTX_SSL_MODE="none" ;;
2) GTX_SSL_MODE="nginx" ;;
3) GTX_SSL_MODE="letsencrypt" ;;
*) GTX_SSL_MODE="nginx" ;;
esac

GTX_LICENSE_SERVER_URL=$(ask "License server URL" "http://127.0.0.1:8080")

if confirm "Is GTX-panel repository private?"; then
GTX_PRIVATE_REPO="yes"
GTX_GITHUB_TOKEN=$(ask_secret "GitHub Personal Access Token")
fi
}

clone_panel() {
logo
bold "Downloading GTX Panel"
line

mkdir -p "$(dirname "$GTX_INSTALL_DIR")"

if [[ -e "$GTX_INSTALL_DIR" ]]; then
local backup="${GTX_INSTALL_DIR}.backup.$(date +%s)"
yellow "Install dir exists. Moving to $backup"
mv "$GTX_INSTALL_DIR" "$backup"
fi

if [[ "$GTX_PRIVATE_REPO" == "yes" ]]; then
clean_url="${GTX_PANEL_REPO#https://}"
git clone "https://${GTX_GITHUB_TOKEN}@${clean_url}" "$GTX_INSTALL_DIR"
else
git clone "$GTX_PANEL_REPO" "$GTX_INSTALL_DIR"
fi

green "GTX Panel downloaded."
}

write_env_files() {
logo
bold "Writing environment files"
line

local app_url="http://$GTX_PANEL_DOMAIN"
if [[ "$GTX_SSL_MODE" == "letsencrypt" ]]; then
app_url="https://$GTX_PANEL_DOMAIN"
fi

cat > "$GTX_INSTALL_DIR/.env" <<EOF
APP_NAME="GTX Panel"
APP_URL="$app_url"
NODE_ENV="production"
PORT="$GTX_PANEL_PORT"
REDIS_URL="redis://127.0.0.1:6379"
LICENSE_REQUIRED="true"
LICENSE_ACTIVATED="false"
LICENSE_SERVER_URL="$GTX_LICENSE_SERVER_URL"
EOF

if [[ -d "$GTX_INSTALL_DIR/server" ]]; then
cat > "$GTX_INSTALL_DIR/server/.env" <<EOF
APP_NAME="GTX Panel"
APP_URL="$app_url"
NODE_ENV="production"
PORT="$GTX_PANEL_PORT"
DATABASE_URL="file:./dev.db"
REDIS_URL="redis://127.0.0.1:6379"
ADMIN_EMAIL="$GTX_ADMIN_EMAIL"
ADMIN_PASSWORD="$GTX_ADMIN_PASSWORD"
LICENSE_REQUIRED="true"
LICENSE_ACTIVATED="false"
LICENSE_SERVER_URL="$GTX_LICENSE_SERVER_URL"
EOF
fi

if [[ -d "$GTX_INSTALL_DIR/client" ]]; then
cat > "$GTX_INSTALL_DIR/client/.env" <<EOF
VITE_APP_NAME="GTX Panel"
VITE_API_URL="$app_url"
VITE_LICENSE_REQUIRED="true"
EOF
fi

chmod 600 "$GTX_INSTALL_DIR/.env" || true
chmod 600 "$GTX_INSTALL_DIR/server/.env" 2>/dev/null || true
}

npm_clean_install_here() {
rm -rf node_modules
rm -f package-lock.json
npm cache clean --force || true
npm install --no-package-lock
}

install_panel_dependencies() {
logo
bold "Installing project dependencies"
line

cd "$GTX_INSTALL_DIR"
[[ -f package.json ]] && npm_clean_install_here

if [[ -d server && -f server/package.json ]]; then
cd "$GTX_INSTALL_DIR/server"
npm_clean_install_here
fi

if [[ -d client && -f client/package.json ]]; then
cd "$GTX_INSTALL_DIR/client"
npm_clean_install_here
fi
}

run_database_tasks() {
logo
bold "Running database tasks"
line

if [[ -d "$GTX_INSTALL_DIR/server" ]]; then
cd "$GTX_INSTALL_DIR/server"
if [[ -f prisma/schema.prisma ]]; then
npx prisma generate || true
npx prisma db push || true
npx prisma db seed || true
fi
fi
}

build_panel() {
logo
bold "Building GTX Panel"
line

if [[ -d "$GTX_INSTALL_DIR/client" ]]; then
cd "$GTX_INSTALL_DIR/client"
npm run build || yellow "Client build failed, continuing."
fi

if [[ -d "$GTX_INSTALL_DIR/server" ]]; then
cd "$GTX_INSTALL_DIR/server"
npm run build || yellow "Server build failed, continuing."
fi
}

create_service() {
logo
bold "Creating systemd service"
line

cat > "/etc/systemd/system/$GTX_SERVICE.service" <<EOF
[Unit]
Description=GTX Panel
After=network.target redis-server.service docker.service
Wants=redis-server.service docker.service

[Service]
Type=simple
User=root
WorkingDirectory=$GTX_INSTALL_DIR
ExecStart=/bin/bash -lc 'cd $GTX_INSTALL_DIR/server && npm start'
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=$GTX_PANEL_PORT
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$GTX_SERVICE"
systemctl restart "$GTX_SERVICE" || true
sleep 3
systemctl status "$GTX_SERVICE" --no-pager || true
}

setup_nginx() {
if [[ "$GTX_SSL_MODE" == "none" ]]; then
return 0
fi

logo
bold "Configuring Nginx"
line

cat > /etc/nginx/sites-available/gtx-panel <<EOF
server {
listen 80;
server_name $GTX_PANEL_DOMAIN;

```
client_max_body_size 100m;

location / {
    proxy_pass http://127.0.0.1:$GTX_PANEL_PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_cache_bypass \$http_upgrade;
}
```

}
EOF

ln -sf /etc/nginx/sites-available/gtx-panel /etc/nginx/sites-enabled/gtx-panel
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx
}

setup_ssl() {
if [[ "$GTX_SSL_MODE" != "letsencrypt" ]]; then
return 0
fi

logo
bold "Installing SSL"
line

apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "$GTX_PANEL_DOMAIN" --non-interactive --agree-tos -m "$GTX_ADMIN_EMAIL" --redirect || yellow "SSL failed."
}

setup_firewall() {
logo
bold "Firewall setup"
line

ufw allow OpenSSH || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw allow "$GTX_PANEL_PORT/tcp" || true

if confirm "Enable UFW firewall now?"; then
ufw --force enable
fi
}

finish_screen() {
logo
green "GTX Panel installation completed!"
line

local url="http://$GTX_PANEL_DOMAIN"
if [[ "$GTX_SSL_MODE" == "letsencrypt" ]]; then
url="https://$GTX_PANEL_DOMAIN"
fi

echo "Panel URL: $url"
echo "Internal Port: $GTX_PANEL_PORT"
echo "Install Dir: $GTX_INSTALL_DIR"
echo "Service: $GTX_SERVICE"
echo "Log File: $GTX_LOG_FILE"
echo
yellow "License Activation Required"
echo "Open the panel. It should redirect to /activate-license"
echo
echo "Commands:"
echo "systemctl status $GTX_SERVICE"
echo "journalctl -u $GTX_SERVICE -f"
echo "systemctl restart $GTX_SERVICE"
line
}

install_all() {
require_root
check_os
system_report
preflight_checks
install_base_packages
install_nodejs
install_docker
collect_install_details
clone_panel
write_env_files
install_panel_dependencies
run_database_tasks
build_panel
create_service
setup_nginx
setup_ssl
setup_firewall
finish_screen
}

status_panel() {
logo
systemctl status "$GTX_SERVICE" --no-pager || true
ss -tulpn | grep -E ":80|:443|:$GTX_PANEL_PORT" || true
}

uninstall_panel() {
require_root
logo
if ! confirm "Remove GTX Panel?"; then exit 0; fi
systemctl stop "$GTX_SERVICE" 2>/dev/null || true
systemctl disable "$GTX_SERVICE" 2>/dev/null || true
rm -f "/etc/systemd/system/$GTX_SERVICE.service"
rm -f /etc/nginx/sites-enabled/gtx-panel /etc/nginx/sites-available/gtx-panel
systemctl daemon-reload
systemctl reload nginx 2>/dev/null || true
mv "$GTX_INSTALL_DIR_DEFAULT" "${GTX_INSTALL_DIR_DEFAULT}.removed.$(date +%s)" 2>/dev/null || true
green "Uninstalled."
}

menu() {
while true; do
logo
echo "1) Install GTX Panel"
echo "2) Show status"
echo "3) Uninstall GTX Panel"
echo "4) Exit"
echo
read -rp "Select option: " opt

```
case "$opt" in
  1) install_all; read -rp "Press Enter..." _ ;;
  2) status_panel; read -rp "Press Enter..." _ ;;
  3) uninstall_panel; read -rp "Press Enter..." _ ;;
  4) exit 0 ;;
  *) red "Invalid option"; sleep 1 ;;
esac
```

done
}

menu
