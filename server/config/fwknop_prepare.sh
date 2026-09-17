#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

PROFILE=""
SERVER_USER=""
SERVER_GPG_PASS=""
ROOT_GPG_HOME="/root/.gnupg"
SERVER_HOME=""
SERVER_GPG_NAME=""
SERVER_GPG_EMAIL=""
SERVER_PUB_OUT=""
HMAC_FILE=""
EXISTING_SERVER_KEY_FPR=""
SERVER_KEY_EXISTS=""
SERVER_PUB_EXISTS=""
HMAC_EXISTS=""
SERVER_KEY_SPEC_FILE=""
SERVER_KEY_ID=""

collect_inputs() {
  read -rp "Profile adı, örn mail-prod: " PROFILE
  [[ -n "$PROFILE" ]] || die "Profile boş olamaz."

  read -rp "Server SSH kullanıcısı [${SUDO_USER:-ubuntu}]: " SERVER_USER
  SERVER_USER="${SERVER_USER:-${SUDO_USER:-ubuntu}}"

  read -rsp "Server GPG passphrase (boş olabilir): " SERVER_GPG_PASS
  echo
}

derive_paths() {
  SERVER_HOME="$(eval echo "~$SERVER_USER")"
  [[ -d "$SERVER_HOME" ]] || die "Kullanıcı home dizini bulunamadı: $SERVER_HOME"

  SERVER_GPG_NAME="server-${PROFILE}"
  SERVER_GPG_EMAIL="server-${PROFILE}@fwknop.local"
  SERVER_PUB_OUT="$SERVER_HOME/fwknop-${PROFILE}-server-pub.asc"
  HMAC_FILE="$SERVER_HOME/fwknop-${PROFILE}-hmac.key"
}

print_derived_values() {
  info "Türetilen değerler:"
  echo "  Server GPG UID: $SERVER_GPG_NAME <$SERVER_GPG_EMAIL>"
  echo "  Server public key: $SERVER_PUB_OUT"
  echo "  HMAC key: $HMAC_FILE"
}

prepare_gpg_home() {
  mkdir -p "$ROOT_GPG_HOME"
  chmod 700 "$ROOT_GPG_HOME"
}

detect_existing_artifacts() {
  info "Çakışma kontrolleri yapılıyor..."

  EXISTING_SERVER_KEY_FPR="$(
    gpg --homedir "$ROOT_GPG_HOME" --with-colons --list-secret-keys "$SERVER_GPG_EMAIL" 2>/dev/null |
      awk -F: '/^fpr:/ {print $10; exit}' || true
  )"

  [[ -n "$EXISTING_SERVER_KEY_FPR" ]] && SERVER_KEY_EXISTS="yes"
  [[ -e "$SERVER_PUB_OUT" ]] && SERVER_PUB_EXISTS="yes"
  [[ -e "$HMAC_FILE" ]] && HMAC_EXISTS="yes"
}

remove_existing_artifacts() {
  local overwrite_prepare

  if [[ -z "$SERVER_KEY_EXISTS" && -z "$SERVER_PUB_EXISTS" && -z "$HMAC_EXISTS" ]]; then
    return 0
  fi

  warn "Bu profile ait mevcut key/dosyalar bulundu."
  [[ -n "$SERVER_KEY_EXISTS" ]] && echo "  - Server secret key: $SERVER_GPG_EMAIL"
  [[ -n "$SERVER_PUB_EXISTS" ]] && echo "  - Server public key dosyası: $SERVER_PUB_OUT"
  [[ -n "$HMAC_EXISTS" ]] && echo "  - HMAC dosyası: $HMAC_FILE"
  echo

  read -rp "Overwrite edilsin mi? [y/N]: " overwrite_prepare
  overwrite_prepare="${overwrite_prepare:-N}"
  [[ "$overwrite_prepare" =~ ^[Yy]$ ]] || die "Kullanıcı iptal etti. Overwrite yapılmadı."

  if [[ -n "$SERVER_KEY_EXISTS" ]]; then
    gpg --homedir "$ROOT_GPG_HOME" --batch --yes --delete-secret-and-public-key "$EXISTING_SERVER_KEY_FPR"
  fi
  [[ -n "$SERVER_PUB_EXISTS" ]] && rm -f "$SERVER_PUB_OUT"
  [[ -n "$HMAC_EXISTS" ]] && rm -f "$HMAC_FILE"
}

validate_dependencies() {
  local package
  local status

  require_commands gpg openssl awk mktemp tr chown chmod rm dpkg-query

  for package in fwknop-server fwknop-client gnupg iptables-persistent netfilter-persistent openssl; do
    status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
    [[ "$status" == "install ok installed" ]] ||
      die "$package kurulu değil. Önce çalıştır: sudo ./server/install.sh --fwknop"
  done
}

disable_ufw() {
  if command -v ufw >/dev/null 2>&1; then
    info "UFW kapatılıyor..."
    ufw disable || true
  else
    info "UFW kurulu değil; kapatma adımı atlandı."
  fi

  info "iptables/IPv6 yönetimi yapılmıyor."
  info "Firewall kuralları bu script tarafından oluşturulmaz."
}

create_server_gpg_key() {
  info "Server GPG key root keyring altında oluşturuluyor (RSA/RSA 2048, 1y)."
  SERVER_KEY_SPEC_FILE="$(mktemp)"
  cat >"$SERVER_KEY_SPEC_FILE" <<EOF
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: $SERVER_GPG_NAME
Name-Email: $SERVER_GPG_EMAIL
Expire-Date: 1y
EOF

  if [[ -z "$SERVER_GPG_PASS" ]]; then
    echo "%no-protection" >>"$SERVER_KEY_SPEC_FILE"
  fi
  echo "%commit" >>"$SERVER_KEY_SPEC_FILE"

  if [[ -n "$SERVER_GPG_PASS" ]]; then
    gpg --homedir "$ROOT_GPG_HOME" --batch --pinentry-mode loopback --passphrase "$SERVER_GPG_PASS" \
      --generate-key "$SERVER_KEY_SPEC_FILE"
  else
    gpg --homedir "$ROOT_GPG_HOME" --batch --pinentry-mode loopback \
      --generate-key "$SERVER_KEY_SPEC_FILE"
  fi
  rm -f -- "$SERVER_KEY_SPEC_FILE"
  SERVER_KEY_SPEC_FILE=""

  SERVER_KEY_ID="$(
    gpg --homedir "$ROOT_GPG_HOME" --list-secret-keys --with-colons "$SERVER_GPG_EMAIL" |
      awk -F: '/^sec:/ {print $5; exit}'
  )"
  [[ -n "$SERVER_KEY_ID" ]] || die "Server GPG key ID bulunamadı."
}

export_server_public_key() {
  info "Server public key export ediliyor..."
  gpg --homedir "$ROOT_GPG_HOME" --armor --export "$SERVER_KEY_ID" >"$SERVER_PUB_OUT"
  chown "$SERVER_USER:$SERVER_USER" "$SERVER_PUB_OUT"
  chmod 644 "$SERVER_PUB_OUT"
}

create_hmac_key() {
  local hmac_key

  info "Profile bazlı HMAC key üretiliyor..."
  hmac_key="$(openssl rand -base64 64 | tr -d '\r\n')"
  [[ -n "$hmac_key" ]] || die "HMAC key üretilemedi."
  printf '%s' "$hmac_key" >"$HMAC_FILE"
  chown "$SERVER_USER:$SERVER_USER" "$HMAC_FILE"
  chmod 600 "$HMAC_FILE"
}

print_completion_summary() {
  cat <<EOF

========================================
SERVER PREPARE OK
========================================

Profile:
  $PROFILE

Server GPG UID:
  $SERVER_GPG_EMAIL

Server GPG key ID:
  $SERVER_KEY_ID

Server public key:
  $SERVER_PUB_OUT

HMAC key:
  $HMAC_FILE

Sonraki adım client tarafında:
  ./client/config/fwknop_exchange.sh

Client exchange sırasında aynı profile adını kullan.
Server finalize adımında interface ve SPA port bilgisi istenecek.

EOF
}

cleanup() {
  if [[ -n "$SERVER_KEY_SPEC_FILE" ]]; then
    rm -f -- "$SERVER_KEY_SPEC_FILE"
  fi
}

main() {
  require_root
  validate_dependencies
  collect_inputs
  derive_paths
  print_derived_values
  prepare_gpg_home
  detect_existing_artifacts
  remove_existing_artifacts
  disable_ufw
  create_server_gpg_key
  export_server_public_key
  create_hmac_key
  print_completion_summary
}

trap cleanup EXIT
main "$@"
