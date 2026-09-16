#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SVC_NAME=""
TARGET_USER=""
EXEC_NPM=""
PORT=""
DESCRIPTION=""
ENV_FILE=0
TEMP_UNIT=""

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -sn|--svc-name)
        [[ $# -ge 2 ]] || die "--svc-name değer gerektirir."
        SVC_NAME="$2"
        shift 2
        ;;
      -u|--user)
        [[ $# -ge 2 ]] || die "--user değer gerektirir."
        TARGET_USER="$2"
        shift 2
        ;;
      -enpm|--exec-npm)
        [[ $# -ge 2 ]] || die "--exec-npm değer gerektirir."
        EXEC_NPM="$2"
        shift 2
        ;;
      -p|--port)
        [[ $# -ge 2 ]] || die "--port değer gerektirir."
        PORT="$2"
        shift 2
        ;;
      -d|--description)
        [[ $# -ge 2 ]] || die "--description değer gerektirir."
        DESCRIPTION="$2"
        shift 2
        ;;
      -envf|--env-file)
        ENV_FILE=1
        shift
        ;;
      *) die "Bilinmeyen seçenek: $1" ;;
    esac
  done
}

validate_inputs() {
  [[ -n "$SVC_NAME" && -n "$TARGET_USER" && -n "$EXEC_NPM" && -n "$DESCRIPTION" ]] ||
    die "--user, --exec-npm, --description ve --svc-name zorunludur."
  [[ "$SVC_NAME" =~ ^[a-zA-Z0-9_.@-]+$ ]] || die "Geçersiz servis adı."
  [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "Geçersiz kullanıcı adı."
  id "$TARGET_USER" >/dev/null 2>&1 || die "Kullanıcı bulunamadı: $TARGET_USER"
  [[ "$EXEC_NPM" != *$'\n'* && "$DESCRIPTION" != *$'\n'* ]] ||
    die "Exec veya açıklama yeni satır içeremez."

  if [[ -n "$PORT" ]]; then
    [[ "$PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$PORT >= 1 && 10#$PORT <= 65535)) ||
      die "Geçersiz port: $PORT"
  fi
}

render_unit() {
  local port_line=""
  local env_file_line=""

  [[ -n "$PORT" ]] && port_line="Environment=PORT=$PORT"
  [[ "$ENV_FILE" -eq 1 ]] && env_file_line="EnvironmentFile=/home/${TARGET_USER}/app/.env"

  TEMP_UNIT="$(mktemp "/tmp/${SVC_NAME}.XXXXXX.service")"
  USER="$TARGET_USER" \
  EXEC_NPM="$EXEC_NPM" \
  DESC="$DESCRIPTION" \
  PORT_LINE="$port_line" \
  ENV_FILE_LINE="$env_file_line" \
    envsubst <"$SCRIPT_DIR/templates/systemd/service.template" >"$TEMP_UNIT"
}

install_unit() {
  local destination="/etc/systemd/system/${SVC_NAME}.service"

  systemd-analyze verify "$TEMP_UNIT"
  install -m 0644 "$TEMP_UNIT" "$destination"
  systemctl daemon-reload
  echo "Service file created at $destination"
}

cleanup() {
  if [[ -n "$TEMP_UNIT" ]]; then
    rm -f -- "$TEMP_UNIT"
  fi
}

main() {
  require_root
  require_commands id envsubst mktemp systemd-analyze install systemctl rm
  parse_arguments "$@"
  validate_inputs
  render_unit
  install_unit
}

trap cleanup EXIT
main "$@"
