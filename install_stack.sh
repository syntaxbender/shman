#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

# Logger Function from node installation file xd
log() {
  local message="$1"
  local type="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local color
  local endcolor="\033[0m"

  case "$type" in
    "info") color="\033[38;5;79m" ;;
    "success") color="\033[1;32m" ;;
    "error") color="\033[1;31m" ;;
    *) color="\033[1;34m" ;;
  esac

  echo -e "${color}${timestamp} - ${message}${endcolor}"
}

INSTALL_POSTGRES=false
INSTALL_MYSQL=false
INSTALL_NGINX=false
INSTALL_APACHE=false
INSTALL_CERTBOT=false
INSTALL_PHP=false
INSTALL_NODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -psql|--postgresql)
      INSTALL_POSTGRES=true
      ;;
    --mysql)
      INSTALL_MYSQL=true
      ;;
    --nginx)
      INSTALL_NGINX=true
      ;;
    --apache)
      INSTALL_APACHE=true
      ;;
    --php)
      INSTALL_PHP=true
      ;;
    --node)
      INSTALL_NODE=true
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

log "Default installations are started!" "info"

if [ "$INSTALL_MYSQL" = true ]; then
  log "Set MySQL Password!" "info"
  read -s -p "MySQL root şifresini girin: " MYSQL_ROOT_PASSWORD
  echo
  read -s -p "MySQL root şifresini tekrar girin: " MYSQL_ROOT_PASSWORD_AGAIN
  echo
  if [ "$MYSQL_ROOT_PASSWORD" != "$MYSQL_ROOT_PASSWORD_AGAIN" ]; then
    echo "Hata: Şifreler uyuşmuyor."
    exit 1
  fi
  echo "mysql-server mysql-server/root_password password $MYSQL_ROOT_PASSWORD" | sudo debconf-set-selections
  echo "mysql-server mysql-server/root_password_again password $MYSQL_ROOT_PASSWORD" | sudo debconf-set-selections
fi

# Eşleşme kontrolü
if [ "$MYSQL_ROOT_PASSWORD" != "$MYSQL_ROOT_PASSWORD_AGAIN" ]; then
    echo "Hata: Şifreler uyuşmuyor."
    exit 1
fi


apt update && apt upgrade -y
needrestart -r a
apt install -y curl gnupg2 wget net-tools dnsutils debconf-utils build-essential git gnupg lsb-release ca-certificates software-properties-common openssl uuid-runtime certbot 
needrestart -r a
log "Default installations are done!" "info"
if [ "$INSTALL_NODE" = true ]; then
  log "Node installation started!" "info"
  wget -q https://deb.nodesource.com/setup_20.x -O ./nodesource.sh && \
  chmod +x ./nodesource.sh && \
  ./nodesource.sh && \
  apt update
  apt install -y nodejs && \
  rm ./nodesource.sh
  needrestart -r a
  log "Node installation done!" "info"
fi

if [ "$INSTALL_POSTGRES" = true ]; then
  log "PostgreSQL installation started!" "info"
  install -d /usr/share/postgresql-common/pgdg && \
  curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
  . /etc/os-release && \
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
  apt update && \
  apt -y install postgresql-contrib-17 postgresql-17 
  needrestart -r a
  log "PostgreSQL installation done!" "info"
fi
if [ "$INSTALL_MYSQL" = true ]; then
  log "MySQL installation started!" "info"
  MYSQL_VERSION=$(curl -s "https://dev.mysql.com/downloads/file/?id=541905" | sed -n 's/.*href=".*mysql-apt-config_\([0-9.-]\+\)_all\.deb.*/\1/p')
  wget https://dev.mysql.com/get/mysql-apt-config_${MYSQL_VERSION}_all.deb
  dpkg -i mysql-apt-config_${MYSQL_VERSION}_all.deb
  apt update
  apt install -y mysql-server
  needrestart -r a
  log "MySQL installation done!" "info"
fi
if [ "$INSTALL_PHP" = true ]; then
  log "PHP installation started!" "info"
  apt install -y curl php8.1 php8.1-mysql php8.1-curl php8.1-mbstring php8.1-fpm
  log "PHP installation done!" "info"
fi

if [ "$INSTALL_NGINX" = true ]; then
  log "Nginx installation started!" "info"
  apt install -y nginx python3-certbot-nginx
  log "Nginx installation done!" "info"
  ./nginx_default.sh
fi

if [ "$INSTALL_APACHE" = true ]; then
  log "Apache2 installation started!" "info"
  apt install -y apache2 python3-certbot-apache
  log "Apache2 installation done!" "info"
fi
