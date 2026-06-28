#!/usr/bin/env bash
# GTX Panel Professional Installer
# Supports: Ubuntu 22.04/24.04, Debian 12
# Features: OS checks, resource checks, Docker, Redis, Database, Domain, SSL, Admin setup,
# Panel build, systemd, Nginx, License prompt, Update/Repair/Uninstall/Status

set -Eeuo pipefail

VERSION="1.1.0"
APP_NAME="GTX Panel"
SERVICE_NAME="gtx-panel"
INSTALL_DIR="/var/www/gtx-panel"
REPO_URL="https://github.com/Arinjay001/GTX-panel.git"
LOG_FILE="/var/log/gtx-panel-installer.log"
ENV_FILE="$INSTALL_DIR/.env"
SERVER_ENV_FILE="$INSTALL_DIR/server/.env"
NGINX_SITE="/etc/nginx/sites-available/gtx-panel.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/gtx-panel.conf"
NODE_VERSION="20"
PANEL_PORT="3000"
DB_NAME="gtxpanel"
DB_USER="gtxpanel"
DB_PASS=""
PANEL_DOMAIN=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
LICENSE_KEY=""
SSL_MODE="none"
PUBLIC_IP=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

trap 'on_error $LINENO "$BASH_COMMAND"' ERR

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" 2>/dev/null || true

log() { echo -e "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${CYAN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
fail() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }

on_error() {
  local line="$1" cmd="$2"
  echo "" | tee -a "$LOG_FILE"
  echo -e "${RED}Installer failed at line $line:${NC} $cmd" | tee -a "$LOG_FILE"
  echo -e "${YELLOW}Log saved at: $LOG_FILE${NC}"
  exit 1
}

pause() { echo ""; read -rp "Press Enter to continue..." _; }

logo() {
  clear
  echo -e "${CYAN}"
cat <<'LOGO'
   ____ _______  __  _____                  _ 
  / ___|_   _\ \/ / |  _ \ __ _ _ __   ___| |
 | |  _  | |  \  /  | |_) / _` | '_ \ / _ \ |
 | |_| | | |  /  \  |  __/ (_| | | | |  __/ |
  \____| |_| /_/\_\ |_|   \__,_|_| |_|\___|_|
LOGO
  echo -e "${NC}${BOLD}        Premium Hosting Control Panel Installer${NC}"
  echo -e "${DIM}                 Version $VERSION${NC}"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Run as root: sudo su"
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

run_apt() {
  DEBIAN_FRONTEND=noninteractive apt-get "$@" | tee -a "$LOG_FILE"
}

get_public_ip() {
  PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}' || echo "127.0.0.1")
}

check_os() {
  logo
  info "Checking operating system..."
  [[ -f /etc/os-release ]] || fail "Unsupported OS: /etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release
  info "Detected: ${PRETTY_NAME:-unknown}"

  case "${ID:-}" in
    ubuntu)
      case "${VERSION_ID:-}" in
        22.04|24.04) success "Ubuntu ${VERSION_ID} supported" ;;
        *) warn "Ubuntu ${VERSION_ID} is not officially tested. Continuing..." ;;
      esac
      ;;
    debian)
      case "${VERSION_ID:-}" in
        12) success "Debian 12 supported" ;;
        *) warn "Debian ${VERSION_ID} is not officially tested. Continuing..." ;;
      esac
      ;;
    *) fail "Only Ubuntu/Debian supported right now" ;;
  esac
}

check_resources() {
  info "Checking CPU/RAM/Disk..."
  local cpu ram disk
  cpu=$(nproc || echo 1)
  ram=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
  disk=$(df -BG / | awk 'NR==2 {gsub("G", "", $4); print $4}')
  info "CPU cores: $cpu"
  info "RAM: ${ram}GB"
  info "Free disk: ${disk}GB"
  (( cpu >= 2 )) || warn "Recommended CPU: 2+ cores"
  (( ram >= 2 )) || warn "Recommended RAM: 2GB+"
  (( disk >= 10 )) || warn "Recommended free disk: 10GB+"
  success "Resource check completed"
}

install_base_dependencies() {
  logo
  info "Installing base dependencies..."
  run_apt update -y
  run_apt install -y curl wget git unzip zip tar ca-certificates gnupg lsb-release software-properties-common apt-transport-https build-essential nginx redis-server openssl ufw jq
  systemctl enable --now redis-server || true
  systemctl enable --now nginx || true
  success "Base dependencies installed"
}

install_nodejs() {
  logo
  info "Installing Node.js $NODE_VERSION..."
  if command_exists node; then
    local current
    current=$(node -v || true)
    info "Current Node.js: $current"
  fi
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - | tee -a "$LOG_FILE"
  run_apt install -y nodejs
  command_exists node || fail "Node.js installation failed"
  command_exists npm || fail "npm installation failed"
  success "Node.js $(node -v) and npm $(npm -v) installed"
}

install_docker() {
  logo
  info "Installing Docker..."
  if command_exists docker; then
    success "Docker already installed: $(docker --version)"
  else
    run_apt install -y docker.io docker-compose-plugin docker-compose
  fi
  systemctl enable --now docker
  docker info >/dev/null 2>&1 || warn "Docker daemon check failed; it may still be starting"
  success "Docker installed"
}

install_database() {
  logo
  info "Installing MariaDB database server..."
  run_apt install -y mariadb-server mariadb-client
  systemctl enable --now mariadb

  if [[ -z "$DB_PASS" ]]; then
    DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
  fi

  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
  success "Database ready: $DB_NAME"
}

ask_questions() {
  logo
  get_public_ip
  echo -e "${BOLD}GTX Panel Setup Questions${NC}"
  echo ""
  read -rp "Panel domain or IP [$PUBLIC_IP]: " PANEL_DOMAIN
  PANEL_DOMAIN=${PANEL_DOMAIN:-$PUBLIC_IP}

  read -rp "Panel internal port [$PANEL_PORT]: " input_port
  PANEL_PORT=${input_port:-$PANEL_PORT}

  read -rp "Admin email: " ADMIN_EMAIL
  [[ -n "$ADMIN_EMAIL" ]] || fail "Admin email is required"

  while true; do
    read -rsp "Admin password: " ADMIN_PASSWORD; echo ""
    [[ ${#ADMIN_PASSWORD} -ge 8 ]] && break
    warn "Password should be at least 8 characters"
  done

  read -rp "License key (leave empty to activate later): " LICENSE_KEY

  echo "SSL mode:"
  echo "1) No SSL / HTTP only"
  echo "2) Let's Encrypt SSL"
  read -rp "Select [1]: " ssl_choice
  case "${ssl_choice:-1}" in
    2) SSL_MODE="letsencrypt" ;;
    *) SSL_MODE="none" ;;
  esac

  if [[ "$SSL_MODE" == "letsencrypt" ]]; then
    [[ "$PANEL_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && fail "Let's Encrypt needs a domain, not raw IP"
  fi
}

download_panel() {
  logo
  info "Downloading GTX Panel from GitHub..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Existing install found. Pulling latest changes..."
    git -C "$INSTALL_DIR" pull --rebase | tee -a "$LOG_FILE"
  else
    [[ -d "$INSTALL_DIR" ]] && mv "$INSTALL_DIR" "${INSTALL_DIR}.backup.$(date +%s)"
    git clone "$REPO_URL" "$INSTALL_DIR" | tee -a "$LOG_FILE"
  fi
  success "Panel downloaded to $INSTALL_DIR"
}

create_env_files() {
  logo
  info "Creating environment files..."
  local db_url_mysql="mysql://$DB_USER:$DB_PASS@127.0.0.1:3306/$DB_NAME"
  local app_url="http://$PANEL_DOMAIN"
  [[ "$SSL_MODE" == "letsencrypt" ]] && app_url="https://$PANEL_DOMAIN"

  cat > "$ENV_FILE" <<ENV
APP_NAME="GTX Panel"
APP_URL="$app_url"
NODE_ENV="production"
PORT="$PANEL_PORT"
REDIS_URL="redis://127.0.0.1:6379"
DATABASE_URL="$db_url_mysql"
ADMIN_EMAIL="$ADMIN_EMAIL"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
LICENSE_KEY="$LICENSE_KEY"
LICENSE_REQUIRED="true"
ENV

  if [[ -d "$INSTALL_DIR/server" ]]; then
    cat > "$SERVER_ENV_FILE" <<ENV
APP_NAME="GTX Panel"
APP_URL="$app_url"
NODE_ENV="production"
PORT="$PANEL_PORT"
REDIS_URL="redis://127.0.0.1:6379"
DATABASE_URL="$db_url_mysql"
ADMIN_EMAIL="$ADMIN_EMAIL"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
LICENSE_KEY="$LICENSE_KEY"
LICENSE_REQUIRED="true"
JWT_SECRET="$(openssl rand -hex 32)"
SESSION_SECRET="$(openssl rand -hex 32)"
ENV
  fi
  chmod 600 "$ENV_FILE" "$SERVER_ENV_FILE" 2>/dev/null || true
  success "Environment files created"
}

build_panel() {
  logo
  info "Installing npm dependencies and building panel..."
  cd "$INSTALL_DIR"

  if [[ -f package-lock.json ]]; then npm ci || npm install; elif [[ -f package.json ]]; then npm install; fi

  if [[ -d server ]]; then
    cd "$INSTALL_DIR/server"
    if [[ -f package-lock.json ]]; then npm ci || npm install; elif [[ -f package.json ]]; then npm install; fi
    if [[ -f prisma/schema.prisma ]]; then
      npx prisma generate || true
      npx prisma migrate deploy || true
      npx prisma db push || true
      [[ -f prisma/seed.ts ]] && npx prisma db seed || true
    fi
    npm run build || true
  fi

  if [[ -d "$INSTALL_DIR/client" ]]; then
    cd "$INSTALL_DIR/client"
    if [[ -f package-lock.json ]]; then npm ci || npm install; elif [[ -f package.json ]]; then npm install; fi
    npm run build || true
  fi

  success "Panel build completed"
}

find_start_command() {
  if [[ -f "$INSTALL_DIR/server/package.json" ]]; then
    echo "/usr/bin/npm start --prefix $INSTALL_DIR/server"
  elif [[ -f "$INSTALL_DIR/package.json" ]]; then
    echo "/usr/bin/npm start --prefix $INSTALL_DIR"
  else
    echo "/bin/bash -lc 'cd $INSTALL_DIR && node server/src/index.js'"
  fi
}

create_systemd_service() {
  logo
  info "Creating systemd service..."
  local start_cmd
  start_cmd=$(find_start_command)
  cat > "/etc/systemd/system/$SERVICE_NAME.service" <<SERVICE
[Unit]
Description=GTX Panel
After=network.target mariadb.service redis-server.service docker.service
Wants=mariadb.service redis-server.service docker.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-$ENV_FILE
EnvironmentFile=-$SERVER_ENV_FILE
ExecStart=$start_cmd
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME" || warn "Service start failed. Check: journalctl -u $SERVICE_NAME -xe"
  success "Service created: $SERVICE_NAME"
}

create_nginx_config() {
  logo
  info "Creating Nginx reverse proxy..."
  cat > "$NGINX_SITE" <<NGINX
server {
    listen 80;
    server_name $PANEL_DOMAIN;

    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
NGINX
  ln -sf "$NGINX_SITE" "$NGINX_ENABLED"
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t
  systemctl reload nginx
  success "Nginx configured on port 80 → 127.0.0.1:$PANEL_PORT"
}

setup_ssl() {
  [[ "$SSL_MODE" != "letsencrypt" ]] && return 0
  logo
  info "Installing Let's Encrypt SSL..."
  run_apt install -y certbot python3-certbot-nginx
  certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect | tee -a "$LOG_FILE"
  systemctl reload nginx
  success "SSL enabled for https://$PANEL_DOMAIN"
}

configure_firewall() {
  logo
  info "Configuring firewall..."
  if command_exists ufw; then
    ufw allow OpenSSH || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow 2022/tcp || true
    ufw --force enable || true
  fi
  success "Firewall configured"
}

license_activation_note() {
  logo
  echo -e "${BOLD}License Activation${NC}"
  if [[ -n "$LICENSE_KEY" ]]; then
    success "License key saved in environment. Panel should verify it on first boot when license API is added."
  else
    warn "No license key entered. Panel should show activation page after install once license UI/API is added."
  fi
  echo ""
  echo "Next coding step in GTX-panel: add Activation page + /api/license/verify endpoint."
}

install_all() {
  need_root
  check_os
  check_resources
  ask_questions
  install_base_dependencies
  install_nodejs
  install_docker
  install_database
  download_panel
  create_env_files
  build_panel
  create_systemd_service
  create_nginx_config
  setup_ssl
  configure_firewall
  license_activation_note
  final_message
}

update_panel() {
  logo
  [[ -d "$INSTALL_DIR/.git" ]] || fail "GTX Panel not installed at $INSTALL_DIR"
  info "Updating GTX Panel..."
  git -C "$INSTALL_DIR" pull --rebase | tee -a "$LOG_FILE"
  build_panel
  systemctl restart "$SERVICE_NAME"
  success "GTX Panel updated"
  pause
}

repair_panel() {
  logo
  info "Repairing GTX Panel..."
  install_base_dependencies
  install_nodejs
  install_docker
  [[ -d "$INSTALL_DIR" ]] && build_panel || warn "Install directory not found; skipping build"
  create_systemd_service
  [[ -n "${PANEL_DOMAIN:-}" ]] || PANEL_DOMAIN=$(hostname -I | awk '{print $1}')
  create_nginx_config
  systemctl restart "$SERVICE_NAME" || true
  success "Repair completed"
  pause
}

uninstall_panel() {
  logo
  warn "This will remove GTX Panel service, Nginx config, and files at $INSTALL_DIR"
  read -rp "Type DELETE to continue: " confirm
  [[ "$confirm" == "DELETE" ]] || { warn "Cancelled"; pause; return; }
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME.service"
  systemctl daemon-reload
  rm -f "$NGINX_ENABLED" "$NGINX_SITE"
  systemctl reload nginx || true
  mv "$INSTALL_DIR" "${INSTALL_DIR}.removed.$(date +%s)" 2>/dev/null || true
  success "GTX Panel removed"
  pause
}

status_panel() {
  logo
  echo -e "${BOLD}GTX Panel Status${NC}"
  echo "Install dir: $INSTALL_DIR"
  echo "Log file: $LOG_FILE"
  echo ""
  systemctl status "$SERVICE_NAME" --no-pager || true
  echo ""
  echo "Ports:"
  ss -tulpn | grep -E ':80|:443|:3000' || true
  pause
}

install_deps_only() {
  need_root
  check_os
  check_resources
  install_base_dependencies
  install_nodejs
  success "Dependencies installed"
  pause
}

install_docker_only() {
  need_root
  install_docker
  pause
}

final_message() {
  logo
  local url="http://$PANEL_DOMAIN"
  [[ "$SSL_MODE" == "letsencrypt" ]] && url="https://$PANEL_DOMAIN"
  echo -e "${GREEN}${BOLD}GTX Panel installation completed!${NC}"
  echo ""
  echo "Panel URL: $url"
  echo "Internal app: http://127.0.0.1:$PANEL_PORT"
  echo "Service: systemctl status $SERVICE_NAME"
  echo "Logs: journalctl -u $SERVICE_NAME -f"
  echo "Installer log: $LOG_FILE"
  echo ""
  echo -e "${YELLOW}Important:${NC} If panel does not open, run option 7 Show status and check logs."
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
    read -rp "Select option: " option
    case "$option" in
      1) install_all ;;
      2) update_panel ;;
      3) repair_panel ;;
      4) uninstall_panel ;;
      5) install_deps_only ;;
      6) install_docker_only ;;
      7) status_panel ;;
      8) exit 0 ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

need_root
main_menu
