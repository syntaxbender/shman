#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../../lib/config.sh
source "$REPO_ROOT/lib/config.sh"

PROXY_PASS=""
DOMAIN=""
WWW_REDIRECT=0
WEBSOCKET_PASS=0
SSL_DISABLED=0

TARGET_CONFIG=""
ENABLED_CONFIG=""
BACKUP_FILE=""
TEMP_CONFIG=""
CONFIG_EXISTED=0
ENABLED_EXISTED=0

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--proxy-pass)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "--proxy-pass değer gerektirir."
        PROXY_PASS="$2"
        shift 2
        ;;
      -d|--domain)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "--domain değer gerektirir."
        DOMAIN="$2"
        shift 2
        ;;
      -ws|--websocket)
        WEBSOCKET_PASS=1
        shift
        ;;
      -r|--www-redirect)
        WWW_REDIRECT=1
        shift
        ;;
      -dssl|--disable-ssl)
        SSL_DISABLED=1
        shift
        ;;
      *) die "Bilinmeyen seçenek: $1" ;;
    esac
  done
}

validate_inputs() {
  local proxy_regex='^https?://[^[:space:];]+$'

  [[ -n "$PROXY_PASS" && -n "$DOMAIN" ]] ||
    die "--proxy-pass ve --domain zorunludur."
  [[ "$DOMAIN" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]{2,63}$ ]] ||
    die "Geçersiz domain: $DOMAIN"
  [[ "$PROXY_PASS" =~ $proxy_regex ]] ||
    die "Geçersiz proxy adresi: $PROXY_PASS"

  TARGET_CONFIG="/etc/nginx/sites-available/${DOMAIN}.conf"
  ENABLED_CONFIG="/etc/nginx/sites-enabled/${DOMAIN}.conf"
}

capture_existing_config() {
  if [[ -f "$TARGET_CONFIG" ]]; then
    CONFIG_EXISTED=1
    BACKUP_FILE="$(backup_file "$TARGET_CONFIG" /etc/nginx/sites-available/deadsites)"
    echo "Önceki config yedeklendi: $BACKUP_FILE"
  fi

  if [[ -e "$ENABLED_CONFIG" || -L "$ENABLED_CONFIG" ]]; then
    ENABLED_EXISTED=1
  fi
}

render_config() {
  local server_name_line
  local websocket_line=""
  local listen_line
  local ssl_lines=""

  if [[ "$WWW_REDIRECT" -eq 1 ]]; then
    server_name_line="server_name www.$DOMAIN;"
  else
    server_name_line="server_name $DOMAIN;"
  fi

  if [[ "$WEBSOCKET_PASS" -eq 1 ]]; then
    websocket_line='proxy_set_header Connection $http_connection;
      proxy_set_header Upgrade $http_upgrade;'
  fi

  if [[ "$SSL_DISABLED" -eq 1 ]]; then
    listen_line="listen 80;"
  else
    listen_line="listen 443 ssl;"
    ssl_lines="ssl_certificate         /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include                 /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam             /etc/letsencrypt/ssl-dhparams.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/chain.pem;
    ssl_stapling on;
    ssl_stapling_verify on;"
  fi

  TEMP_CONFIG="$(mktemp /etc/nginx/sites-available/.${DOMAIN}.XXXXXX.conf)"

  PROXY_PASS="$PROXY_PASS" \
  DOMAIN="$DOMAIN" \
  SERVER_NAME_LINE="$server_name_line" \
  WEBSOCKET_LINE="$websocket_line" \
  LISTEN_LINE="$listen_line" \
  SSL_LINES="$ssl_lines" \
    envsubst '${LISTEN_LINE} ${SERVER_NAME_LINE} ${PROXY_PASS} ${WEBSOCKET_LINE} ${SSL_LINES}' \
    <"$REPO_ROOT/templates/nginx/site.template" >"$TEMP_CONFIG"

  if [[ "$WWW_REDIRECT" -eq 1 ]]; then
    DOMAIN="$DOMAIN" LISTEN_LINE="$listen_line" SSL_LINES="$ssl_lines" \
      envsubst '${LISTEN_LINE} ${DOMAIN} ${SSL_LINES}' \
      <"$REPO_ROOT/templates/nginx/site_redirect.template" >>"$TEMP_CONFIG"
  fi
}

restore_previous_config() {
  if [[ "$CONFIG_EXISTED" -eq 1 ]]; then
    restore_file_backup "$BACKUP_FILE" "$TARGET_CONFIG"
  else
    rm -f -- "$TARGET_CONFIG"
  fi

  if [[ "$ENABLED_EXISTED" -eq 0 ]]; then
    rm -f -- "$ENABLED_CONFIG"
  fi
}

install_and_verify_config() {
  install -m 0644 "$TEMP_CONFIG" "$TARGET_CONFIG"
  ln -sfn "$TARGET_CONFIG" "$ENABLED_CONFIG"

  if ! nginx -t; then
    restore_previous_config
    die "Nginx doğrulaması başarısız; önceki config geri yüklendi."
  fi

  systemctl reload nginx || systemctl restart nginx
  echo "Nginx config uygulandı: $TARGET_CONFIG"
}

cleanup() {
  if [[ -n "$TEMP_CONFIG" ]]; then
    rm -f -- "$TEMP_CONFIG"
  fi
}

main() {
  require_root
  require_command_or_install nginx "sudo ./server/install.sh --nginx"
  require_command_or_install envsubst "sudo ./server/install.sh --nginx"
  require_commands mktemp install ln systemctl cp grep sed basename date mkdir
  parse_arguments "$@"
  validate_inputs
  capture_existing_config
  render_config
  install_and_verify_config
}

trap cleanup EXIT
main "$@"
