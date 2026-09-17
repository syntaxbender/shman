#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../../lib/config.sh
source "$REPO_ROOT/lib/config.sh"

SERVER_IP=""
TARGET_CONFIG="/etc/nginx/sites-available/default"
ENABLED_CONFIG="/etc/nginx/sites-enabled/default"
CONFIG_BACKUP=""
TEMP_CONFIG=""
TEMP_IMAGE=""
TEMP_INDEX=""
CONFIG_EXISTED=0
ENABLED_EXISTED=0

detect_server_ip() {
  SERVER_IP="$(curl -fsSL checkip.amazonaws.com)"
  [[ -n "$SERVER_IP" ]] || die "Sunucu IP adresi belirlenemedi."
}

prepare_web_assets() {
  TEMP_IMAGE="$(mktemp /tmp/nginx-nothing.XXXXXX.jpg)"
  TEMP_INDEX="$(mktemp /tmp/nginx-index.XXXXXX.html)"

  wget -q -O "$TEMP_IMAGE" \
    https://raw.githubusercontent.com/syntaxbender/linux-infrastructure/refs/heads/main/data/nginx/var_html/nothing.jpg
  wget -q -O "$TEMP_INDEX" \
    https://raw.githubusercontent.com/syntaxbender/linux-infrastructure/refs/heads/main/data/nginx/var_html/index.html

  if [[ -f /var/www/html/nothing.jpg ]]; then
    backup_file /var/www/html/nothing.jpg /var/backups/shman/nginx-html >/dev/null
  fi
  if [[ -f /var/www/html/index.html ]]; then
    backup_file /var/www/html/index.html /var/backups/shman/nginx-html >/dev/null
  fi

  install -m 0644 "$TEMP_IMAGE" /var/www/html/nothing.jpg
  install -m 0644 "$TEMP_INDEX" /var/www/html/index.html
}

prepare_fallback_certificate() {
  install -d -m 0755 /etc/nginx/ssl

  if [[ -f /etc/nginx/ssl/nginx.key && -f /etc/nginx/ssl/nginx.crt ]]; then
    echo "Fallback TLS sertifikası zaten mevcut."
    return 0
  fi

  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/nginx.key \
    -out /etc/nginx/ssl/nginx.crt \
    -subj "/C=/ST=/L=/O=/OU=/CN=/emailAddress="
  chmod 0600 /etc/nginx/ssl/nginx.key
}

capture_existing_config() {
  if [[ -f "$TARGET_CONFIG" ]]; then
    CONFIG_EXISTED=1
    CONFIG_BACKUP="$(backup_file "$TARGET_CONFIG" /etc/nginx/sites-available/deadsites)"
  fi

  if [[ -e "$ENABLED_CONFIG" || -L "$ENABLED_CONFIG" ]]; then
    ENABLED_EXISTED=1
  fi
}

render_default_config() {
  TEMP_CONFIG="$(mktemp /etc/nginx/sites-available/.default.XXXXXX)"

  cat >"$TEMP_CONFIG" <<EOF
server {
    listen 80;
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;
    server_name $SERVER_IP;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\.ht {
        deny all;
    }
}

server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;
    return 404;
}
EOF
}

restore_previous_config() {
  if [[ "$CONFIG_EXISTED" -eq 1 ]]; then
    restore_file_backup "$CONFIG_BACKUP" "$TARGET_CONFIG"
  else
    rm -f -- "$TARGET_CONFIG"
  fi

  [[ "$ENABLED_EXISTED" -eq 1 ]] || rm -f -- "$ENABLED_CONFIG"
}

install_default_config() {
  install -m 0644 "$TEMP_CONFIG" "$TARGET_CONFIG"
  ln -sfn "$TARGET_CONFIG" "$ENABLED_CONFIG"

  if ! nginx -t; then
    restore_previous_config
    die "Nginx doğrulaması başarısız; önceki default config geri yüklendi."
  fi

  systemctl reload nginx || systemctl restart nginx
  echo "Nginx default config uygulandı."
}

cleanup() {
  if [[ -n "$TEMP_CONFIG" ]]; then rm -f -- "$TEMP_CONFIG"; fi
  if [[ -n "$TEMP_IMAGE" ]]; then rm -f -- "$TEMP_IMAGE"; fi
  if [[ -n "$TEMP_INDEX" ]]; then rm -f -- "$TEMP_INDEX"; fi
}

main() {
  require_root
  require_command_or_install nginx "sudo ./server/install.sh --nginx"
  require_command_or_install curl "sudo ./server/install.sh --nginx"
  require_command_or_install wget "sudo ./server/install.sh --nginx"
  require_command_or_install openssl "sudo ./server/install.sh --nginx"
  require_commands mktemp install chmod systemctl ln cp grep sed basename date mkdir
  detect_server_ip
  prepare_web_assets
  prepare_fallback_certificate
  capture_existing_config
  render_default_config
  install_default_config
}

trap cleanup EXIT
main "$@"
