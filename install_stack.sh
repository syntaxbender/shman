#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export DEBIAN_FRONTEND=noninteractive

INSTALL_DEPENDENCIES=0
INSTALL_POSTGRES=0
INSTALL_MYSQL=0
INSTALL_NGINX=0
INSTALL_APACHE=0
INSTALL_CERTBOT=0
INSTALL_PODMAN=0
INSTALL_PHP=0
INSTALL_NODE=0
INSTALL_FORGEJO=0

MYSQL_ROOT_PASSWORD=""
MYSQL_ROOT_PASSWORD_AGAIN=""
FORGEJO_LOOPBACK_PORT=6010
FORGEJO_DOMAIN="git.example.com"

log() {
  local message="$1"
  local type="${2:-info}"
  local timestamp
  local color
  local endcolor="\033[0m"

  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$type" in
    info) color="\033[38;5;79m" ;;
    success) color="\033[1;32m" ;;
    error) color="\033[1;31m" ;;
    *) color="\033[1;34m" ;;
  esac

  echo -e "${color}${timestamp} - ${message}${endcolor}"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -dep|--dependencies) INSTALL_DEPENDENCIES=1 ;;
      -psql|--postgresql) INSTALL_POSTGRES=1 ;;
      --mysql) INSTALL_MYSQL=1 ;;
      --nginx) INSTALL_NGINX=1 ;;
      --apache) INSTALL_APACHE=1 ;;
      --certbot) INSTALL_CERTBOT=1 ;;
      --podman) INSTALL_PODMAN=1 ;;
      --php) INSTALL_PHP=1 ;;
      --node) INSTALL_NODE=1 ;;
      --forgejo) INSTALL_FORGEJO=1 ;;
      *) die "Bilinmeyen seçenek: $1" ;;
    esac
    shift
  done
}

apt_update() {
  apt-get update
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

run_needrestart() {
  if command -v needrestart >/dev/null 2>&1; then
    needrestart -r a
  else
    log "needrestart kurulu değil; servis kontrolü atlandı." "info"
  fi
}

collect_mysql_password() {
  [[ "$INSTALL_MYSQL" -eq 1 ]] || return 0

  require_command debconf-set-selections
  log "MySQL root parolası hazırlanıyor." "info"

  read -rsp "MySQL root şifresini girin: " MYSQL_ROOT_PASSWORD
  echo
  read -rsp "MySQL root şifresini tekrar girin: " MYSQL_ROOT_PASSWORD_AGAIN
  echo

  [[ "$MYSQL_ROOT_PASSWORD" == "$MYSQL_ROOT_PASSWORD_AGAIN" ]] ||
    die "MySQL şifreleri uyuşmuyor."

  printf '%s\n' "mysql-server mysql-server/root_password password $MYSQL_ROOT_PASSWORD" |
    debconf-set-selections
  printf '%s\n' "mysql-server mysql-server/root_password_again password $MYSQL_ROOT_PASSWORD" |
    debconf-set-selections
}

install_dependencies() {
  [[ "$INSTALL_DEPENDENCIES" -eq 1 ]] || return 0

  log "Dependency installations are started!" "info"
  apt-get upgrade -y
  apt_install \
    curl wget gnupg gnupg2 net-tools dnsutils debconf-utils build-essential \
    git nano vim git-lfs lsb-release ca-certificates software-properties-common \
    openssl uuid-runtime iproute2 iputils-ping netcat-openbsd lsof htop unzip \
    needrestart traceroute tcpdump jq tree zip tar rsync
  run_needrestart
  log "Dependency installations are done!" "success"
}

install_node() {
  local setup_script

  [[ "$INSTALL_NODE" -eq 1 ]] || return 0

  log "Node installation started!" "info"
  setup_script="$(mktemp /tmp/nodesource.XXXXXX.sh)"
  wget -q https://deb.nodesource.com/setup_20.x -O "$setup_script"
  chmod 0700 "$setup_script"
  bash "$setup_script"
  rm -f -- "$setup_script"
  apt_update
  apt_install nodejs
  run_needrestart
  log "Node installation done!" "success"
}

install_postgresql() {
  [[ "$INSTALL_POSTGRES" -eq 1 ]] || return 0

  log "PostgreSQL installation started!" "info"
  install -d /usr/share/postgresql-common/pgdg
  curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
  # shellcheck source=/etc/os-release
  source /etc/os-release
  printf '%s\n' \
    "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" \
    >/etc/apt/sources.list.d/pgdg.list
  apt_update
  apt_install postgresql-contrib-17 postgresql-17
  run_needrestart
  log "PostgreSQL installation done!" "success"
}

install_mysql() {
  local mysql_version
  local package_file

  [[ "$INSTALL_MYSQL" -eq 1 ]] || return 0

  log "MySQL installation started!" "info"
  mysql_version="$(
    curl -fsSL "https://dev.mysql.com/downloads/file/?id=541905" |
      sed -n 's/.*href=".*mysql-apt-config_\([0-9.-]\+\)_all\.deb.*/\1/p; T; q'
  )"
  [[ -n "$mysql_version" ]] || die "MySQL APT paket sürümü belirlenemedi."

  package_file="$(mktemp /tmp/mysql-apt-config.XXXXXX.deb)"
  wget -O "$package_file" \
    "https://dev.mysql.com/get/mysql-apt-config_${mysql_version}_all.deb"
  dpkg -i "$package_file"
  rm -f -- "$package_file"
  apt_update
  apt_install mysql-server
  run_needrestart
  log "MySQL installation done!" "success"
}

install_php() {
  [[ "$INSTALL_PHP" -eq 1 ]] || return 0

  log "PHP installation started!" "info"
  apt_install curl php8.1 php8.1-mysql php8.1-curl php8.1-mbstring php8.1-fpm
  log "PHP installation done!" "success"
}

install_podman() {
  [[ "$INSTALL_PODMAN" -eq 1 ]] || return 0

  log "Podman dependencies installation started!" "info"
  apt_install podman uidmap slirp4netns fuse-overlayfs apparmor apparmor-utils

  if apt-cache show passt >/dev/null 2>&1; then
    apt_install passt
  else
    log "passt package not found in repositories, skipping passt." "info"
  fi

  run_needrestart
  log "Podman dependencies installation done!" "success"
}

install_nginx() {
  [[ "$INSTALL_NGINX" -eq 1 ]] || return 0

  log "Nginx installation started!" "info"
  apt_install nginx

  if [[ -d /etc/nginx/sites-enabled ]]; then
    find /etc/nginx/sites-enabled -maxdepth 1 \( -type f -o -type l \) -exec rm -f {} +
    log "Disabled nginx configs in /etc/nginx/sites-enabled" "info"
  fi

  nginx -t || die "Nginx yapılandırması geçersiz."
  systemctl reload nginx || systemctl restart nginx
  log "Nginx installation done!" "success"
}

install_apache() {
  [[ "$INSTALL_APACHE" -eq 1 ]] || return 0

  log "Apache2 installation started!" "info"
  apt_install apache2
  log "Apache2 installation done!" "success"
}

install_certbot() {
  [[ "$INSTALL_CERTBOT" -eq 1 ]] || return 0

  log "Certbot installation started!" "info"
  apt_install certbot

  if [[ "$INSTALL_NGINX" -eq 1 ]]; then
    apt_install python3-certbot-nginx
    install -d -m 0755 /etc/letsencrypt
    install -m 0644 \
      /usr/lib/python3/dist-packages/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
      /etc/letsencrypt/options-ssl-nginx.conf
    install -m 0644 \
      /usr/lib/python3/dist-packages/certbot/ssl-dhparams.pem \
      /etc/letsencrypt/ssl-dhparams.pem
  fi

  if [[ "$INSTALL_APACHE" -eq 1 ]]; then
    apt_install python3-certbot-apache
  fi

  run_needrestart
  log "Certbot installation done!" "success"
}

install_forgejo() {
  local forgejo_version
  local forgejo_secret_key

  [[ "$INSTALL_FORGEJO" -eq 1 ]] || return 0

  log "Forgejo installation started!" "info"
  forgejo_version="$(
    curl -fsSL https://codeberg.org/forgejo/forgejo/releases |
      grep -m1 -oP 'forgejo/releases/download/v\K[0-9.]+'
  )"
  [[ -n "$forgejo_version" ]] || die "Forgejo sürümü belirlenemedi."

  wget -O /usr/local/bin/forgejo \
    "https://codeberg.org/forgejo/forgejo/releases/download/v${forgejo_version}/forgejo-${forgejo_version}-linux-amd64"
  chmod 0755 /usr/local/bin/forgejo

  if ! id git &>/dev/null; then
    adduser --system --shell /bin/bash --gecos 'Git Version Control' \
      --group --disabled-password --home /home/git git
  fi

  install -d -m 0750 -o git -g git /var/lib/forgejo
  install -d -m 0750 -o root -g git /etc/forgejo

  forgejo_secret_key="$(openssl rand -hex 64 | tr -d '\n')"
  export FORGEJO_DOMAIN FORGEJO_LOOPBACK_PORT
  FORGEJO_SECRET_KEY="$forgejo_secret_key" \
    envsubst '${FORGEJO_DOMAIN} ${FORGEJO_LOOPBACK_PORT} ${FORGEJO_SECRET_KEY}' \
    <"$SCRIPT_DIR/templates/forgejo/app.ini.template" \
    > /etc/forgejo/app.ini
  chown root:git /etc/forgejo/app.ini
  chmod 0660 /etc/forgejo/app.ini

  wget -O /etc/systemd/system/forgejo.service \
    https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/contrib/systemd/forgejo.service

  "$SCRIPT_DIR/nginx_config_gen.sh" \
    -p "http://127.0.0.1:${FORGEJO_LOOPBACK_PORT}" \
    -d "$FORGEJO_DOMAIN" -ws

  systemctl daemon-reload
  systemctl enable --now forgejo.service
  log "Waiting 5 seconds for run forgejo service..." "info"
  sleep 5
  chmod 0640 /etc/forgejo/app.ini
  chmod 0750 /etc/forgejo
  log "Forgejo installation done!" "success"
}

main() {
  require_root
  require_commands apt-get date
  parse_arguments "$@"
  collect_mysql_password
  apt_update
  install_dependencies
  install_node
  install_postgresql
  install_mysql
  install_php
  install_podman
  install_nginx
  install_apache
  install_certbot
  install_forgejo
}

main "$@"
