#!/usr/bin/env bash
set -e

PANEL_REPO="https://github.com/Arinjay001/GTX-panel.git"
INSTALL_DIR="/var/www/gtx-panel"

logo() {
clear
cat << "EOF"
   ____ _______  __  _____                  _
  / ___|_   _\ \/ / |  _ \ __ _ _ __   ___| |
 | |  _  | |  \  /  | |_) / _` | '_ \ / _ \ |
 | |_| | | |  /  \  |  __/ (_| | | | |  __/ |
  \____| |_| /_/\_\ |_|   \__,_|_| |_|\___|_|

        Premium Hosting Control Panel
EOF
echo ""
}

pause() {
  read -rp "Press Enter to continue..."
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
  fi
}

install_dependencies() {
  logo
  echo "[1/7] Installing dependencies..."
  apt update -y
  apt install -y curl wget git unzip software-properties-common ca-certificates gnupg lsb-release nginx redis-server
  pause
}

install_node() {
  logo
  echo "[2/7] Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt install -y nodejs
  node -v
  npm -v
  pause
}

install_docker() {
  logo
  echo "[3/7] Installing Docker..."
  apt install -y docker.io docker-compose
  systemctl enable --now docker
  pause
}

get_details() {
  logo
  echo "[4/7] GTX Panel setup"
  read -rp "Enter panel domain/IP: " PANEL_DOMAIN
  read -rp "Enter admin email: " ADMIN_EMAIL
  read -rsp "Enter admin password: " ADMIN_PASSWORD
  echo ""
}

download_panel() {
  logo
  echo "[5/7] Downloading GTX Panel..."

  mkdir -p /var/www
  rm -rf "$INSTALL_DIR"

  git clone "$PANEL_REPO" "$INSTALL_DIR"

  cd "$INSTALL_DIR"
  npm install || true

  if [ -d "server" ]; then
    cd server
    npm install
    cd ..
  fi

  if [ -d "client" ]; then
    cd client
    npm install
    npm run build || true
    cd ..
  fi

  pause
}

create_env() {
  logo
  echo "[6/7] Creating environment files..."

  cat > "$INSTALL_DIR/.env" <<EOF
APP_NAME="GTX Panel"
APP_URL="http://$PANEL_DOMAIN"
ADMIN_EMAIL="$ADMIN_EMAIL"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
NODE_ENV="production"
PORT=3000
REDIS_URL="redis://127.0.0.1:6379"
EOF

  if [ -d "$INSTALL_DIR/server" ]; then
    cat > "$INSTALL_DIR/server/.env" <<EOF
APP_NAME="GTX Panel"
APP_URL="http://$PANEL_DOMAIN"
ADMIN_EMAIL="$ADMIN_EMAIL"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
NODE_ENV="production"
PORT=3000
DATABASE_URL="file:./dev.db"
REDIS_URL="redis://127.0.0.1:6379"
LICENSE_REQUIRED=true
EOF
  fi

  pause
}

create_service() {
  logo
  echo "[7/7] Creating GTX Panel service..."

  cat > /etc/systemd/system/gtx-panel.service <<EOF
[Unit]
Description=GTX Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable gtx-panel
  systemctl restart gtx-panel || true

  echo ""
  echo "======================================"
  echo " GTX Panel installed successfully!"
  echo " Open: http://$PANEL_DOMAIN"
  echo " Service: systemctl status gtx-panel"
  echo "======================================"
}

main_menu() {
  logo
  echo "1) Install GTX Panel"
  echo "2) Install dependencies only"
  echo "3) Install Docker only"
  echo "4) Exit"
  echo ""
  read -rp "Select option: " option

  case $option in
    1)
      install_dependencies
      install_node
      install_docker
      get_details
      download_panel
      create_env
      create_service
      ;;
    2)
      install_dependencies
      install_node
      ;;
    3)
      install_docker
      ;;
    4)
      exit 0
      ;;
    *)
      echo "Invalid option"
      sleep 1
      main_menu
      ;;
  esac
}

check_root
main_menu
