#!/usr/bin/env bash
# GTX Panel Professional Installer
# Repository: https://github.com/Arinjay001/GTX-Installer
# Run: bash <(curl -fsSL https://raw.githubusercontent.com/Arinjay001/GTX-Installer/main/install.sh)

set -Eeuo pipefail

GTX_VERSION="1.0.0"
GTX_BRAND="GTX Panel"
GTX_REPO_DEFAULT="https://github.com/Arinjay001/GTX-panel.git"
GTX_INSTALL_DIR_DEFAULT="/var/www/gtx-panel"
GTX_SERVICE="gtx-panel"
GTX_PORT_DEFAULT="3000"
GTX_LOG_DIR="/var/log/gtx-installer"
GTX_LOG_FILE="$GTX_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
GTX_OS_ID=""
GTX_OS_VERSION=""
GTX_PANEL_DOMAIN=""
GTX_ADMIN_EMAIL=""
GTX_ADMIN_PASSWORD=""
GTX_INSTALL_DIR="$GTX_INSTALL_DIR_DEFAULT"
GTX_PANEL_REPO="$GTX_REPO_DEFAULT"
GTX_PANEL_PORT="$GTX_PORT_DEFAULT"
GTX_SSL_MODE="none"
GTX_DB_MODE="sqlite"
GTX_RUN_NPM_BUILD="yes"
GTX_PRIVATE_REPO="no"
GTX_GITHUB_TOKEN=""
GTX_LICENSE_KEY=""
GTX_LICENSE_URL=""
GTX_PUBLIC_IP=""
GTX_NONINTERACTIVE="no"

mkdir -p "$GTX_LOG_DIR"
touch "$GTX_LOG_FILE"
exec > >(tee -a "$GTX_LOG_FILE") 2>&1

trap 'on_error $LINENO "$BASH_COMMAND"' ERR

on_error() {
  local line="$1"
  local cmd="$2"
  echo ""
  red "Installation failed at line $line"
  yellow "Command: $cmd"
  yellow "Log file: $GTX_LOG_FILE"
  echo ""
  exit 1
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

echo_c() { echo -e "$1$2${NC}"; }
red() { echo_c "$RED" "$1"; }
green() { echo_c "$GREEN" "$1"; }
yellow() { echo_c "$YELLOW" "$1"; }
blue() { echo_c "$BLUE" "$1"; }
cyan() { echo_c "$CYAN" "$1"; }
magenta() { echo_c "$MAGENTA" "$1"; }
bold() { echo_c "$BOLD" "$1"; }

line() { echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"; }

logo() {
  clear || true
  echo -e "${CYAN}"
  cat <<'ASCII'
   ____ _______  __  _____                  _
  / ___|_   _\ \/ / |  _ \ __ _ _ __   ___| |
 | |  _  | |  \  /  | |_) / _` | '_ \ / _ \ |
 | |_| | | |  /  \  |  __/ (_| | | | |  __/ |
  \____| |_| /_/\_\ |_|   \__,_|_| |_|\___|_|
ASCII
  echo -e "${NC}"
  bold "              Premium Hosting Control Panel Installer"
  cyan "                         Version $GTX_VERSION"
  line
}

spinner() {
  local pid=$1
  local msg=$2
  local spin='|/-\\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\r${YELLOW}%s ${spin:$i:1}${NC}" "$msg"
    sleep .1
  done
  printf "\r${GREEN}%s done.${NC}\n" "$msg"
}

run_step() {
  local msg="$1"
  shift
  yellow "▶ $msg"
  "$@"
  green "✓ $msg"
}

pause() {
  if [[ "$GTX_NONINTERACTIVE" == "yes" ]]; then return 0; fi
  echo ""
  read -rp "Press Enter to continue..." _
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
  echo "" >&2
  echo "$var"
}

confirm() {
  local prompt="$1"
  local ans
  read -rp "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    red "Please run as root. Use: sudo su"
    exit 1
  fi
}

load_os() {
  if [[ ! -f /etc/os-release ]]; then
    red "Unsupported operating system: /etc/os-release not found."
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  GTX_OS_ID="$ID"
  GTX_OS_VERSION="$VERSION_ID"
}

check_os() {
  logo
  load_os
  bold "Checking operating system..."
  echo "Detected: $PRETTY_NAME"
  case "$GTX_OS_ID" in
    ubuntu)
      case "$GTX_OS_VERSION" in
        20.04|22.04|24.04|26.04) green "Ubuntu $GTX_OS_VERSION supported." ;;
        *) yellow "Ubuntu version not officially tested, continuing anyway." ;;
      esac
      ;;
    debian)
      case "$GTX_OS_VERSION" in
        11|12|13) green "Debian $GTX_OS_VERSION supported." ;;
        *) yellow "Debian version not officially tested, continuing anyway." ;;
      esac
      ;;
    *)
      red "Only Ubuntu/Debian are supported."
      exit 1
      ;;
  esac
}

system_report() {
  logo
  bold "System report"
  line
  echo "OS:        $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
  echo "Kernel:    $(uname -r)"
  echo "CPU Cores: $(nproc)"
  echo "RAM:       $(free -h | awk '/Mem:/ {print $2}')"
  echo "Disk:      $(df -h / | awk 'NR==2 {print $4 " free / " $2 " total"}')"
  GTX_PUBLIC_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "unknown")
  echo "Public IP: $GTX_PUBLIC_IP"
  line
  pause
}

preflight_checks() {
  logo
  bold "Running preflight checks"
  line
  local ram_mb disk_gb
  ram_mb=$(free -m | awk '/Mem:/ {print $2}')
  disk_gb=$(df -BG / | awk 'NR==2 {gsub("G", "", $4); print $4}')
  if (( ram_mb < 1024 )); then yellow "RAM is under 1GB. GTX Panel may be slow."; else green "RAM check OK."; fi
  if (( disk_gb < 5 )); then red "Need at least 5GB free disk."; exit 1; else green "Disk check OK."; fi
  if command -v systemctl >/dev/null 2>&1; then green "systemd found."; else red "systemd not found."; exit 1; fi
  if ping -c 1 github.com >/dev/null 2>&1; then green "Internet OK."; else yellow "Ping failed; continuing because curl may still work."; fi
  pause
}

apt_update() {
  DEBIAN_FRONTEND=noninteractive apt-get update -y
}

install_base_packages() {
  logo
  bold "Installing base packages"
  line
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget git unzip zip tar ca-certificates gnupg lsb-release software-properties-common \
    build-essential python3 make g++ nano openssl ufw jq nginx redis-server
  systemctl enable --now redis-server || true
  systemctl enable --now nginx || true
}

install_nodejs() {
  logo
  bold "Installing Node.js 20"
  line
  if command -v node >/dev/null 2>&1; then
    local major
    major=$(node -v | sed 's/v//' | cut -d. -f1)
    if (( major >= 20 )); then
      green "Node.js $(node -v) already installed."
      return 0
    fi
  fi
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  npm install -g npm@latest
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
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose docker-compose-v2 || DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose
  systemctl enable --now docker
  docker --version || true
}

setup_firewall() {
  logo
  bold "Firewall setup"
  line
  if ! command -v ufw >/dev/null 2>&1; then
    yellow "UFW not installed, skipping."
    return 0
  fi
  ufw allow OpenSSH || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw allow "$GTX_PANEL_PORT/tcp" || true
  if confirm "Enable UFW firewall now?"; then
    ufw --force enable
  else
    yellow "Firewall enable skipped."
  fi
}

collect_install_details() {
  logo
  bold "GTX Panel configuration"
  line
  GTX_INSTALL_DIR=$(ask "Install directory" "$GTX_INSTALL_DIR_DEFAULT")
  GTX_PANEL_REPO=$(ask "GTX Panel repository" "$GTX_REPO_DEFAULT")
  GTX_PANEL_PORT=$(ask "Panel port" "$GTX_PORT_DEFAULT")
  GTX_PANEL_DOMAIN=$(ask "Panel domain or IP" "${GTX_PUBLIC_IP:-127.0.0.1}")
  GTX_ADMIN_EMAIL=$(ask "Admin email" "admin@gtxpanel.local")
  while [[ -z "$GTX_ADMIN_PASSWORD" ]]; do
    GTX_ADMIN_PASSWORD=$(ask_secret "Admin password")
    if [[ ${#GTX_ADMIN_PASSWORD} -lt 8 ]]; then
      red "Password must be at least 8 characters."
      GTX_ADMIN_PASSWORD=""
    fi
  done
  echo ""
  echo "Database mode:"
  echo "1) SQLite (easy/testing)"
  echo "2) PostgreSQL (later)"
  local db_choice
  read -rp "Choose [1]: " db_choice
  case "${db_choice:-1}" in
    1) GTX_DB_MODE="sqlite" ;;
    2) GTX_DB_MODE="postgres" ;;
    *) GTX_DB_MODE="sqlite" ;;
  esac
  echo ""
  echo "SSL mode:"
  echo "1) No SSL / local HTTP"
  echo "2) Nginx reverse proxy HTTP only"
  echo "3) Let's Encrypt SSL"
  local ssl_choice
  read -rp "Choose [1]: " ssl_choice
  case "${ssl_choice:-1}" in
    1) GTX_SSL_MODE="none" ;;
    2) GTX_SSL_MODE="nginx" ;;
    3) GTX_SSL_MODE="letsencrypt" ;;
    *) GTX_SSL_MODE="none" ;;
  esac
  echo ""
  if confirm "Is GTX-panel repository private?"; then
    GTX_PRIVATE_REPO="yes"
    GTX_GITHUB_TOKEN=$(ask_secret "GitHub Personal Access Token with repo read access")
  fi
  echo ""
  if confirm "Ask license key during install?"; then
    GTX_LICENSE_KEY=$(ask "License key" "")
    GTX_LICENSE_URL=$(ask "License verify URL" "https://license.example.com/api/verify")
  fi
}

verify_license_optional() {
  if [[ -z "$GTX_LICENSE_KEY" || -z "$GTX_LICENSE_URL" ]]; then
    return 0
  fi
  logo
  bold "Verifying license"
  line
  local machine_id payload resp valid
  machine_id=$(cat /etc/machine-id 2>/dev/null || hostname)
  payload=$(jq -n --arg key "$GTX_LICENSE_KEY" --arg machine "$machine_id" --arg ip "$GTX_PUBLIC_IP" '{key:$key,machine_id:$machine,ip:$ip,product:"GTX Panel"}')
  resp=$(curl -fsSL -X POST "$GTX_LICENSE_URL" -H "Content-Type: application/json" -d "$payload" || echo '{}')
  echo "$resp" | jq . || true
  valid=$(echo "$resp" | jq -r '.valid // false' 2>/dev/null || echo false)
  if [[ "$valid" != "true" ]]; then
    red "License invalid. Installation stopped."
    exit 1
  fi
  green "License valid."
}

clone_panel() {
  logo
  bold "Downloading GTX Panel"
  line
  mkdir -p "$(dirname "$GTX_INSTALL_DIR")"
  if [[ -d "$GTX_INSTALL_DIR/.git" ]]; then
    yellow "Existing installation found. Pulling latest changes..."
    cd "$GTX_INSTALL_DIR"
    git pull --ff-only || true
    return 0
  fi
  if [[ -e "$GTX_INSTALL_DIR" ]]; then
    local backup="${GTX_INSTALL_DIR}.backup.$(date +%s)"
    yellow "Install dir exists. Moving to $backup"
    mv "$GTX_INSTALL_DIR" "$backup"
  fi
  if [[ "$GTX_PRIVATE_REPO" == "yes" ]]; then
    local clean_url token_url
    clean_url="${GTX_PANEL_REPO#https://}"
    token_url="https://${GTX_GITHUB_TOKEN}@${clean_url}"
    git clone "$token_url" "$GTX_INSTALL_DIR"
  else
    git clone "$GTX_PANEL_REPO" "$GTX_INSTALL_DIR"
  fi
}

write_env_files() {
  logo
  bold "Writing environment files"
  line
  local app_url="http://$GTX_PANEL_DOMAIN"
  if [[ "$GTX_SSL_MODE" == "letsencrypt" ]]; then app_url="https://$GTX_PANEL_DOMAIN"; fi
  cat > "$GTX_INSTALL_DIR/.env" <<EOFENV
APP_NAME="GTX Panel"
APP_URL="$app_url"
NODE_ENV="production"
PORT="$GTX_PANEL_PORT"
REDIS_URL="redis://127.0.0.1:6379"
LICENSE_REQUIRED="true"
LICENSE_KEY="$GTX_LICENSE_KEY"
EOFENV
  if [[ -d "$GTX_INSTALL_DIR/server" ]]; then
    local db_url="file:./dev.db"
    if [[ "$GTX_DB_MODE" == "postgres" ]]; then
      db_url="postgresql://gtx_panel:password@127.0.0.1:5432/gtx_panel"
    fi
    cat > "$GTX_INSTALL_DIR/server/.env" <<EOFENV
APP_NAME="GTX Panel"
APP_URL="$app_url"
NODE_ENV="production"
PORT="$GTX_PANEL_PORT"
DATABASE_URL="$db_url"
REDIS_URL="redis://127.0.0.1:6379"
ADMIN_EMAIL="$GTX_ADMIN_EMAIL"
ADMIN_PASSWORD="$GTX_ADMIN_PASSWORD"
LICENSE_REQUIRED="true"
LICENSE_KEY="$GTX_LICENSE_KEY"
LICENSE_VERIFY_URL="$GTX_LICENSE_URL"
EOFENV
  fi
  if [[ -d "$GTX_INSTALL_DIR/client" ]]; then
    cat > "$GTX_INSTALL_DIR/client/.env" <<EOFENV
VITE_APP_NAME="GTX Panel"
VITE_API_URL="$app_url"
EOFENV
  fi
  chmod 600 "$GTX_INSTALL_DIR/.env" || true
  chmod 600 "$GTX_INSTALL_DIR/server/.env" 2>/dev/null || true
}

install_panel_dependencies() {
  logo
  bold "Installing project dependencies"
  line
  cd "$GTX_INSTALL_DIR"
  if [[ -f package-lock.json ]]; then npm ci || npm install; elif [[ -f package.json ]]; then npm install; fi
  if [[ -d server && -f server/package.json ]]; then
    cd "$GTX_INSTALL_DIR/server"
    if [[ -f package-lock.json ]]; then npm ci || npm install; else npm install; fi
  fi
  if [[ -d client && -f client/package.json ]]; then
    cd "$GTX_INSTALL_DIR/client"
    if [[ -f package-lock.json ]]; then npm ci || npm install; else npm install; fi
  fi
}

run_database_tasks() {
  logo
  bold "Running database tasks"
  line
  if [[ -d "$GTX_INSTALL_DIR/server" && -f "$GTX_INSTALL_DIR/server/package.json" ]]; then
    cd "$GTX_INSTALL_DIR/server"
    if [[ -f prisma/schema.prisma ]]; then
      npx prisma generate || true
      npx prisma migrate deploy || npx prisma db push || true
      if [[ -f prisma/seed.ts ]]; then npx prisma db seed || true; fi
    fi
  fi
}

build_panel() {
  logo
  bold "Building GTX Panel"
  line
  if [[ "$GTX_RUN_NPM_BUILD" != "yes" ]]; then yellow "Build skipped."; return 0; fi
  if [[ -d "$GTX_INSTALL_DIR/client" && -f "$GTX_INSTALL_DIR/client/package.json" ]]; then
    cd "$GTX_INSTALL_DIR/client"
    npm run build || yellow "Client build failed or no build script. Continuing."
  fi
  if [[ -d "$GTX_INSTALL_DIR/server" && -f "$GTX_INSTALL_DIR/server/package.json" ]]; then
    cd "$GTX_INSTALL_DIR/server"
    npm run build || yellow "Server build failed or no build script. Continuing."
  fi
}

find_start_command() {
  local wd="$1"
  if [[ -f "$wd/server/package.json" ]]; then
    echo "cd $wd/server && npm start"
  elif [[ -f "$wd/package.json" ]]; then
    echo "cd $wd && npm start"
  else
    echo "cd $wd && node server.js"
  fi
}

create_systemd_service() {
  logo
  bold "Creating systemd service"
  line
  local start_cmd
  start_cmd=$(find_start_command "$GTX_INSTALL_DIR")
  cat > "/etc/systemd/system/$GTX_SERVICE.service" <<EOFSVC
[Unit]
Description=GTX Panel
After=network.target redis-server.service docker.service
Wants=redis-server.service docker.service

[Service]
Type=simple
User=root
WorkingDirectory=$GTX_INSTALL_DIR
ExecStart=/bin/bash -lc '$start_cmd'
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=$GTX_PANEL_PORT
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOFSVC
  systemctl daemon-reload
  systemctl enable "$GTX_SERVICE"
  systemctl restart "$GTX_SERVICE" || true
  sleep 2
  systemctl status "$GTX_SERVICE" --no-pager || true
}

setup_nginx() {
  if [[ "$GTX_SSL_MODE" == "none" ]]; then return 0; fi
  logo
  bold "Configuring Nginx"
  line
  cat > /etc/nginx/sites-available/gtx-panel <<EOFNGINX
server {
    listen 80;
    server_name $GTX_PANEL_DOMAIN;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:$GTX_PANEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOFNGINX
  ln -sf /etc/nginx/sites-available/gtx-panel /etc/nginx/sites-enabled/gtx-panel
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
}

setup_letsencrypt() {
  if [[ "$GTX_SSL_MODE" != "letsencrypt" ]]; then return 0; fi
  logo
  bold "Installing Let's Encrypt SSL"
  line
  DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
  certbot --nginx -d "$GTX_PANEL_DOMAIN" --non-interactive --agree-tos -m "$GTX_ADMIN_EMAIL" --redirect || yellow "SSL failed. Check DNS and try certbot manually."
}

finish_screen() {
  logo
  green "GTX Panel installation completed!"
  line
  local url="http://$GTX_PANEL_DOMAIN"
  if [[ "$GTX_SSL_MODE" == "letsencrypt" ]]; then url="https://$GTX_PANEL_DOMAIN"; fi
  echo "Panel URL:       $url"
  echo "Panel Port:      $GTX_PANEL_PORT"
  echo "Install Dir:     $GTX_INSTALL_DIR"
  echo "Service:         $GTX_SERVICE"
  echo "Log file:        $GTX_LOG_FILE"
  echo ""
  echo "Useful commands:"
  echo "  systemctl status $GTX_SERVICE"
  echo "  journalctl -u $GTX_SERVICE -f"
  echo "  systemctl restart $GTX_SERVICE"
  line
}

install_all() {
  require_root
  check_os
  system_report
  preflight_checks
  collect_install_details
  verify_license_optional
  install_base_packages
  install_nodejs
  install_docker
  clone_panel
  write_env_files
  install_panel_dependencies
  run_database_tasks
  build_panel
  create_systemd_service
  setup_nginx
  setup_letsencrypt
  setup_firewall
  finish_screen
}

update_panel() {
  require_root
  logo
  bold "Updating GTX Panel"
  line
  if [[ ! -d "$GTX_INSTALL_DIR_DEFAULT/.git" ]]; then
    GTX_INSTALL_DIR=$(ask "Install directory" "$GTX_INSTALL_DIR_DEFAULT")
  fi
  if [[ ! -d "$GTX_INSTALL_DIR/.git" ]]; then
    red "No git installation found in $GTX_INSTALL_DIR"
    exit 1
  fi
  cd "$GTX_INSTALL_DIR"
  git pull
  install_panel_dependencies
  run_database_tasks
  build_panel
  systemctl restart "$GTX_SERVICE" || true
  green "Update complete."
}

uninstall_panel() {
  require_root
  logo
  red "GTX Panel uninstall"
  line
  GTX_INSTALL_DIR=$(ask "Install directory" "$GTX_INSTALL_DIR_DEFAULT")
  if ! confirm "This will remove service and files at $GTX_INSTALL_DIR. Continue?"; then exit 0; fi
  systemctl stop "$GTX_SERVICE" 2>/dev/null || true
  systemctl disable "$GTX_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$GTX_SERVICE.service"
  systemctl daemon-reload
  rm -f /etc/nginx/sites-enabled/gtx-panel /etc/nginx/sites-available/gtx-panel
  systemctl reload nginx 2>/dev/null || true
  local backup="${GTX_INSTALL_DIR}.removed.$(date +%s)"
  if [[ -e "$GTX_INSTALL_DIR" ]]; then
    mv "$GTX_INSTALL_DIR" "$backup"
    yellow "Files moved to: $backup"
  fi
  green "Uninstall complete."
}

repair_panel() {
  require_root
  logo
  bold "Repair GTX Panel"
  line
  GTX_INSTALL_DIR=$(ask "Install directory" "$GTX_INSTALL_DIR_DEFAULT")
  install_base_packages
  install_nodejs
  install_docker
  install_panel_dependencies
  run_database_tasks
  build_panel
  create_systemd_service
  green "Repair complete."
}

show_status() {
  logo
  bold "GTX Panel status"
  line
  systemctl status "$GTX_SERVICE" --no-pager || true
  echo ""
  docker --version 2>/dev/null || true
  node -v 2>/dev/null || true
  npm -v 2>/dev/null || true
  nginx -v 2>&1 || true
  redis-cli ping 2>/dev/null || true
  pause
}

main_menu() {
  while true; do
    logo
    echo "1) Install GTX Panel"
    echo "2) Update GTX Panel"
    echo "3) Repair GTX Panel"
    echo "4) Uninstall GTX Panel"
    echo "5) Install dependencies only"
    echo "6) Install Docker only"
    echo "7) Show status"
    echo "8) Exit"
    echo ""
    read -rp "Select option: " opt
    case "$opt" in
      1) install_all; pause ;;
      2) update_panel; pause ;;
      3) repair_panel; pause ;;
      4) uninstall_panel; pause ;;
      5) require_root; check_os; install_base_packages; install_nodejs; pause ;;
      6) require_root; check_os; install_docker; pause ;;
      7) show_status ;;
      8) exit 0 ;;
      *) red "Invalid option"; sleep 1 ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install) GTX_NONINTERACTIVE="yes"; shift ;;
      --dir) GTX_INSTALL_DIR="$2"; shift 2 ;;
      --repo) GTX_PANEL_REPO="$2"; shift 2 ;;
      --domain) GTX_PANEL_DOMAIN="$2"; shift 2 ;;
      --port) GTX_PANEL_PORT="$2"; shift 2 ;;
      --help|-h)
        echo "GTX Panel Installer"
        echo "Usage: bash install.sh"
        exit 0
        ;;
      *) shift ;;
    esac
  done
}

parse_args "$@"
main_menu
