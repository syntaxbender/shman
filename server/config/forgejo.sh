#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../../lib/config.sh
source "$REPO_ROOT/lib/config.sh"

FORGEJO_DOMAIN=""
FORGEJO_LOOPBACK_PORT=6010
SSL_DISABLED=0
APP_INI_STAGE=""
SERVICE_STAGE=""

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--domain)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "--domain değer gerektirir."
        FORGEJO_DOMAIN="$2"
        shift 2
        ;;
      -p|--port)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "--port değer gerektirir."
        FORGEJO_LOOPBACK_PORT="$2"
        shift 2
        ;;
      -dssl|--disable-ssl)
        SSL_DISABLED=1
        shift
        ;;
      *) die "Bilinmeyen seçenek: $1" ;;
    esac
  done
}

collect_inputs() {
  if [[ -z "$FORGEJO_DOMAIN" ]]; then
    read -rp "Forgejo domain [git.example.com]: " FORGEJO_DOMAIN
    FORGEJO_DOMAIN="${FORGEJO_DOMAIN:-git.example.com}"
  fi
}

validate_inputs() {
  [[ "$FORGEJO_DOMAIN" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]{2,63}$ ]] ||
    die "Geçersiz domain: $FORGEJO_DOMAIN"
  [[ "$FORGEJO_LOOPBACK_PORT" =~ ^[0-9]{1,5}$ ]] &&
    ((10#$FORGEJO_LOOPBACK_PORT >= 1 && 10#$FORGEJO_LOOPBACK_PORT <= 65535)) ||
    die "Geçersiz port: $FORGEJO_LOOPBACK_PORT"
  FORGEJO_LOOPBACK_PORT="$((10#$FORGEJO_LOOPBACK_PORT))"
}

validate_dependencies() {
  require_command_or_install forgejo "sudo ./server/install.sh --forgejo"
  require_command_or_install nginx "sudo ./server/install.sh --nginx"
  require_command_or_install envsubst "sudo ./server/install.sh --forgejo"
  require_commands \
    id wget openssl systemd-analyze systemctl install chown chmod mktemp rm \
    tr awk mkdir cp date basename

  id git >/dev/null 2>&1 ||
    die "git sistem kullanıcısı bulunamadı. Önce çalıştır: sudo ./server/install.sh --forgejo"
  [[ -d /var/lib/forgejo && -d /etc/forgejo ]] ||
    die "Forgejo dizinleri bulunamadı. Önce çalıştır: sudo ./server/install.sh --forgejo"
}

render_app_config() {
  local forgejo_secret_key
  local forgejo_root_url
  local protocol="https"

  [[ "$SSL_DISABLED" -eq 0 ]] || protocol="http"
  forgejo_root_url="${protocol}://${FORGEJO_DOMAIN}/"
  forgejo_secret_key=""
  if [[ -f /etc/forgejo/app.ini ]]; then
    forgejo_secret_key="$(
      awk -F= '
        $1 ~ /^[[:space:]]*SECRET_KEY[[:space:]]*$/ {
          value=$2
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          print value
          exit
        }
      ' /etc/forgejo/app.ini
    )"
  fi
  [[ -n "$forgejo_secret_key" ]] || forgejo_secret_key="$(openssl rand -hex 64 | tr -d '\n')"
  [[ -n "$forgejo_secret_key" ]] || die "Forgejo secret key üretilemedi."

  APP_INI_STAGE="$(mktemp /tmp/forgejo-app.XXXXXX.ini)"
  FORGEJO_DOMAIN="$FORGEJO_DOMAIN" \
  FORGEJO_LOOPBACK_PORT="$FORGEJO_LOOPBACK_PORT" \
  FORGEJO_ROOT_URL="$forgejo_root_url" \
  FORGEJO_SECRET_KEY="$forgejo_secret_key" \
    envsubst '${FORGEJO_DOMAIN} ${FORGEJO_LOOPBACK_PORT} ${FORGEJO_ROOT_URL} ${FORGEJO_SECRET_KEY}' \
    <"$REPO_ROOT/templates/forgejo/app.ini.template" >"$APP_INI_STAGE"
}

install_app_config() {
  if [[ -f /etc/forgejo/app.ini ]]; then
    echo "Önceki app.ini yedeklendi: $(backup_file /etc/forgejo/app.ini /var/backups/shman/forgejo)"
  fi

  install -m 0660 -o root -g git "$APP_INI_STAGE" /etc/forgejo/app.ini
}

prepare_service_unit() {
  SERVICE_STAGE="$(mktemp /tmp/forgejo-service.XXXXXX.service)"
  wget -q -O "$SERVICE_STAGE" \
    https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/contrib/systemd/forgejo.service
  systemd-analyze verify "$SERVICE_STAGE"
}

install_service_unit() {
  if [[ -f /etc/systemd/system/forgejo.service ]]; then
    echo "Önceki service unit yedeklendi: $(backup_file /etc/systemd/system/forgejo.service /var/backups/shman/forgejo)"
  fi

  install -m 0644 "$SERVICE_STAGE" /etc/systemd/system/forgejo.service
  systemctl daemon-reload
  systemctl enable --now forgejo.service
}

configure_nginx_site() {
  local nginx_args=(
    --proxy-pass "http://127.0.0.1:${FORGEJO_LOOPBACK_PORT}"
    --domain "$FORGEJO_DOMAIN"
    --websocket
  )

  [[ "$SSL_DISABLED" -eq 0 ]] || nginx_args+=(--disable-ssl)
  "$REPO_ROOT/server/config/nginx_site.sh" "${nginx_args[@]}"
}

finalize_permissions() {
  chmod 0640 /etc/forgejo/app.ini
  chmod 0750 /etc/forgejo
}

print_completion_summary() {
  echo
  echo "Forgejo yapılandırıldı:"
  echo "  Domain        : $FORGEJO_DOMAIN"
  echo "  Loopback port : $FORGEJO_LOOPBACK_PORT"
  echo "  Config        : /etc/forgejo/app.ini"
  echo "  Service       : forgejo.service"
}

cleanup() {
  [[ -z "$APP_INI_STAGE" ]] || rm -f -- "$APP_INI_STAGE"
  [[ -z "$SERVICE_STAGE" ]] || rm -f -- "$SERVICE_STAGE"
}

main() {
  require_root
  parse_arguments "$@"
  collect_inputs
  validate_inputs
  validate_dependencies
  render_app_config
  prepare_service_unit
  install_app_config
  install_service_unit
  configure_nginx_site
  finalize_permissions
  print_completion_summary
}

trap cleanup EXIT
main "$@"
