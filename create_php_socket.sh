#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

USERNAME=""
PHP_VERSION=""
PHP_VERSIONS=()
POOL_CONF_FILE=""
POOL_CONF_STAGE=""

read_target_user() {
  read -rp "Hangi kullanıcı için pool oluşturulsun? (örn: myuser): " USERNAME
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] ||
    die "Geçerli bir Linux kullanıcı adı girilmelidir."
  id "$USERNAME" >/dev/null 2>&1 || die "Kullanıcı bulunamadı: $USERNAME"
}

collect_php_versions() {
  [[ -d /etc/php ]] || die "/etc/php dizini bulunamadı."

  mapfile -t PHP_VERSIONS < <(ls /etc/php/ | grep -E '^[0-9]+\.[0-9]+$')
  [[ "${#PHP_VERSIONS[@]}" -gt 0 ]] || die "Hiçbir PHP sürümü bulunamadı."
}

select_php_version() {
  echo "Mevcut PHP sürümleri:"
  select PHP_VERSION in "${PHP_VERSIONS[@]}"; do
    if [[ -n "$PHP_VERSION" ]]; then
      return 0
    fi
    echo "Lütfen geçerli bir seçim yapın."
  done
}

write_pool_config() {
  local pool_conf_dir="/etc/php/${PHP_VERSION}/fpm/pool.d"

  [[ -d "$pool_conf_dir" ]] || die "PHP-FPM pool dizini bulunamadı: $pool_conf_dir"
  POOL_CONF_FILE="${pool_conf_dir}/${USERNAME}.conf"
  POOL_CONF_STAGE="$(mktemp)"

  cat >"$POOL_CONF_STAGE" <<EOF
[${USERNAME}]
listen = /run/php/${USERNAME}.sock
listen.owner = ${USERNAME}
listen.group = ${USERNAME}
listen.mode = 0660

user = ${USERNAME}
group = ${USERNAME}

pm = dynamic
pm.max_children = 20
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 4
EOF
}

validate_and_reload_fpm() {
  local fpm_command="php-fpm${PHP_VERSION}"
  local fpm_service="php${PHP_VERSION}-fpm.service"

  require_commands "$fpm_command" systemctl

  if ! install_validated_config \
    "$POOL_CONF_STAGE" "$POOL_CONF_FILE" 0644 \
    "$fpm_command" -t; then
    die "PHP-FPM yapılandırması geçersiz; pool değişikliği geri alındı."
  fi

  systemctl reload-or-restart "$fpm_service"
  echo "PHP-FPM pool oluşturuldu ve servis yeniden yüklendi: $POOL_CONF_FILE"
}

cleanup() {
  if [[ -n "$POOL_CONF_STAGE" ]]; then
    rm -f -- "$POOL_CONF_STAGE"
  fi
}

main() {
  require_root
  require_commands id ls grep mktemp cp install rm
  read_target_user
  collect_php_versions
  select_php_version
  write_pool_config
  validate_and_reload_fpm
}

trap cleanup EXIT
main "$@"
