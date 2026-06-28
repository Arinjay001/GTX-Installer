#!/usr/bin/env bash
# GTX Panel Professional Single-File Installer
# Tailored for GTX-panel repo structure:
# root/package.json -> npm start runs server
# server/.env -> PORT=3000, DATABASE_URL=file:./dev.db
# client -> Vite build

set -Eeuo pipefail

APP_NAME="GTX Panel"
APP_SLUG="gtx-panel"
APP_DIR="/var/www/gtx-panel"
REPO_URL="https://github.com/Arinjay001/GTX-panel.git"
BRANCH="main"
SERVICE_NAME="gtx-panel"
APP_PORT="3000"
LOG_FILE="/var/log/gtx-panel-installer.log"
NODE_MAJOR="20"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

trap 'echo -e "\n${RED}Installer failed. Check log: '"$LOG_FILE"'${NC}"; exit 1' ERR

log(){ echo -e "$1" | tee -a "$LOG_FILE"; }
ok(){ log "${GREEN}[OK]${NC} $1"; }
warn(){ log "${YELLOW}[WARN]${NC} $1"; }
fail(){ log "${RED}[ERROR]${NC} $1"; exit 1; }
step(){ log "\n${CYAN}==>${NC} ${BOLD}$1${NC}"; }

logo(){
clear
cat << "EOF"
   ____ _______  __  _____                  _
  / ___|_   _\ \/ / |  _ \ __ _ _ __   ___| |
 | |  _  | |  \  /  | |_) / _` | '_ \ / _ \ |
 | |_| | | |  /  \  |  __/ (_| | | | |  __/ |
  \____| |_| /_/\_\ |_|   \__,_|_| |_|\___|_|

        Premium Hosting Control Panel Installer
EOF
echo -e "${CYAN}                    Version 1.0.0${NC}\n"
}

need_root(){
  if [ "$EUID" -ne 0 ]; then
    fail "Run as root: sudo su"
  fi
}

detect_os(){
  step "Detecting OS"
  if [ ! -f /etc/os-release ]; then
    fail "Unsupported OS"
  fi
  source /etc/os-release
  OS_ID="${ID}"
  OS_VER="${VERSION_ID}"
  ok "Detected: ${PRETTY_NAME}"
  case "$OS_ID" in
    ubuntu|debian) ;;
    *) fail "Only Ubuntu/Debian supported" ;;
  esac
}

system_checks(){
  step "Checking CPU/RAM/Disk"
  CPU="$(nproc || echo 1)"
  RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  DISK_GB="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')"

  log "CPU cores: $CPU"
  log "RAM: ${RAM_MB} MB"
  log "Free disk: ${DISK_GB} GB"

  if [ "$CPU" -lt 1 ]; then fail "Minimum 1 CPU required"; fi
  if [ "$RAM_MB" -lt 900 ]; then warn "Recommended RAM: 2GB+"; fi
  if [ "$DISK_GB" -lt 5 ]; then fail "Minimum 5GB free disk required"; fi
  ok "System check complete"
}

install_base(){
  step "Installing base dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget git unzip tar ca-certificates gnupg lsb-release software-properties-common apt-transport-https ufw jq openssl build-essential python3
  ok "Base dependencies installed"
}

install_node(){
  step "Installing Node.js ${NODE_MAJOR}"
  if ! command -v node >/dev/null 2>&1 || ! node -v | grep -q "v${NODE_MAJOR}\."; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
  fi
  ok "Node: $(node -v), npm: $(npm -v)"
}

install_docker(){
  step "Installing Docker"
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker
  ok "Docker installed"
}

install_services(){
  step "Installing Redis, MariaDB and Nginx"
  apt-get install -y redis-server mariadb-server nginx
  systemctl enable --now redis-server || systemctl enable --now redis || true
  systemctl enable --now mariadb
  systemctl enable --now nginx
  ok "Redis/MariaDB/Nginx ready"
}

ask_config(){
  step "Configuration"
  read -rp "Panel domain or server IP: " PANEL_DOMAIN
  if [ -z "$PANEL_DOMAIN" ]; then fail "Domain/IP required"; fi

  read -rp "Admin email: " ADMIN_EMAIL
  if [ -z "$ADMIN_EMAIL" ]; then ADMIN_EMAIL="admin@gtx.local"; fi

  read -rsp "Admin password: " ADMIN_PASSWORD
  echo
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD="$(openssl rand -base64 18)"
    warn "Random admin password generated: $ADMIN_PASSWORD"
  fi

  read -rp "Use SSL with Let's Encrypt? (y/N): " USE_SSL
  read -rp "License key option? Enter key or leave blank to skip: " LICENSE_KEY
}

download_panel(){
  step "Downloading GTX Panel"
  mkdir -p "$(dirname "$APP_DIR")"
  rm -rf "$APP_DIR"

  if ! git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"; then
    fail "Git clone failed. If GTX-panel is private, make it public for testing or add token-based download."
  fi
  ok "Panel downloaded"
}

create_env(){
  step "Creating environment files"
  mkdir -p "$APP_DIR/server"

  cat > "$APP_DIR/server/.env" <<EOF
APP_NAME="GTX Panel"
APP_URL="http://${PANEL_DOMAIN}"
NODE_ENV="production"
PORT=${APP_PORT}
DATABASE_URL="file:./dev.db"
JWT_SECRET="$(openssl rand -hex 32)"
REDIS_URL="redis://127.0.0.1:6379"
ADMIN_EMAIL="${ADMIN_EMAIL}"
ADMIN_PASSWORD="${ADMIN_PASSWORD}"
LICENSE_KEY="${LICENSE_KEY}"
LICENSE_REQUIRED=false
EOF

  cat > "$APP_DIR/.env" <<EOF
APP_NAME="GTX Panel"
APP_URL="http://${PANEL_DOMAIN}"
NODE_ENV="production"
PORT=${APP_PORT}
EOF

  ok ".env created"
}

build_panel(){
  step "Installing dependencies and building panel"
  cd "$APP_DIR"

  npm install
  npm run db:generate || true
  npm run db:push || true

  if [ -d "$APP_DIR/server" ]; then
    cd "$APP_DIR/server"
    npm install
    npx prisma generate || true
    npx prisma db push || true
    npm run build || true
  fi

  if [ -d "$APP_DIR/client" ]; then
    cd "$APP_DIR/client"
    npm install
    npm run build || true
  fi

  cd "$APP_DIR"
  npm run build || true

  ok "Build complete"
}

create_service(){
  step "Creating systemd service"
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=GTX Panel
After=network.target redis-server.service mariadb.service

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment=NODE_ENV=production
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME" || true
  ok "Service created"
}

configure_nginx(){
  step "Configuring Nginx"
  cat > "/etc/nginx/sites-available/${APP_SLUG}" <<EOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf "/etc/nginx/sites-available/${APP_SLUG}" "/etc/nginx/sites-enabled/${APP_SLUG}"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
  ok "Nginx configured"
}

setup_ssl(){
  if [[ "${USE_SSL,,}" == "y" ]]; then
    step "Installing SSL"
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" || warn "SSL failed. Make sure domain points to this VPS."
  fi
}

firewall(){
  step "Configuring firewall"
  ufw allow 22/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw allow 2022/tcp || true
  ufw --force enable || true
  ok "Firewall configured"
}

install_all(){
  logo
  need_root
  detect_os
  system_checks
  install_base
  install_node
  install_docker
  install_services
  ask_config
  download_panel
  create_env
  build_panel
  create_service
  configure_nginx
  setup_ssl
  firewall

  logo
  ok "GTX Panel installed!"
  echo "Open: http://${PANEL_DOMAIN}"
  if [[ "${USE_SSL,,}" == "y" ]]; then echo "SSL: https://${PANEL_DOMAIN}"; fi
  echo "Internal port: ${APP_PORT}"
  echo "Status: systemctl status ${SERVICE_NAME}"
  echo "Logs: journalctl -u ${SERVICE_NAME} -f"
}

update_panel(){
  need_root
  step "Updating GTX Panel"
  cd "$APP_DIR"
  git pull origin "$BRANCH"
  npm install
  npm run build || true
  if [ -d "$APP_DIR/server" ]; then cd "$APP_DIR/server" && npm install && npx prisma db push || true; fi
  if [ -d "$APP_DIR/client" ]; then cd "$APP_DIR/client" && npm install && npm run build || true; fi
  systemctl restart "$SERVICE_NAME"
  ok "Updated"
}

repair_panel(){
  need_root
  step "Repairing GTX Panel"
  install_base
  install_node
  install_docker
  install_services
  if [ ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then create_service; fi
  systemctl restart "$SERVICE_NAME" || true
  nginx -t && systemctl reload nginx || true
  ok "Repair done"
}

uninstall_panel(){
  need_root
  read -rp "This will remove GTX Panel files. Type DELETE: " x
  if [ "$x" != "DELETE" ]; then exit 0; fi
  systemctl disable --now "$SERVICE_NAME" || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  rm -f "/etc/nginx/sites-enabled/${APP_SLUG}" "/etc/nginx/sites-available/${APP_SLUG}"
  rm -rf "$APP_DIR"
  systemctl daemon-reload
  systemctl reload nginx || true
  ok "Uninstalled"
}

status_panel(){
  echo "Service:"
  systemctl status "$SERVICE_NAME" --no-pager || true
  echo
  echo "Ports:"
  ss -tulpn | grep -E ":80|:443|:${APP_PORT}" || true
}

menu(){
  logo
  echo "1) Install GTX Panel"
  echo "2) Update GTX Panel"
  echo "3) Repair GTX Panel"
  echo "4) Uninstall GTX Panel"
  echo "5) Install dependencies only"
  echo "6) Install Docker only"
  echo "7) Show status"
  echo "8) Exit"
  echo
  read -rp "Select option: " opt

  case "$opt" in
    1) install_all ;;
    2) update_panel ;;
    3) repair_panel ;;
    4) uninstall_panel ;;
    5) need_root; detect_os; system_checks; install_base; install_node; install_services ;;
    6) need_root; install_docker ;;
    7) status_panel ;;
    8) exit 0 ;;
    *) echo "Invalid option"; sleep 1; menu ;;
  esac
}

menu
