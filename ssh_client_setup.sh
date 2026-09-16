#!/usr/bin/env bash
set -euo pipefail

KEY_NAME=""
PRIVATE_KEY=""
PUBLIC_KEY=""
REMOTE_USER=""
REMOTE_HOST=""
SSH_PORT=""

die() {
  echo "Hata: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Gerekli komut bulunamadı: $1"
}

require_dependencies() {
  local command_name

  for command_name in ssh ssh-keygen ssh-copy-id install chmod; do
    require_command "$command_name"
  done
}

read_key_name() {
  while true; do
    read -rp "SSH anahtar adı: " KEY_NAME

    if [[ "$KEY_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      return 0
    fi

    echo "Anahtar adı yalnızca harf, rakam, nokta, alt çizgi ve tire içerebilir."
  done
}

prepare_key_paths() {
  local ssh_dir

  [[ -n "${HOME:-}" ]] || die "HOME ortam değişkeni bulunamadı."

  ssh_dir="$HOME/.ssh"
  install -d -m 0700 "$ssh_dir"

  PRIVATE_KEY="$ssh_dir/$KEY_NAME"
  PUBLIC_KEY="$PRIVATE_KEY.pub"

  if [[ -e "$PRIVATE_KEY" || -e "$PUBLIC_KEY" ]]; then
    die "Aynı isimde bir SSH anahtarı zaten var: $PRIVATE_KEY"
  fi
}

read_remote_user() {
  local answer

  while true; do
    read -rp "Uzak sunucudaki kullanıcı [$KEY_NAME]: " answer
    REMOTE_USER="${answer:-$KEY_NAME}"

    if [[ "$REMOTE_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
      return 0
    fi

    echo "Geçerli bir Linux kullanıcı adı gir."
  done
}

read_remote_host() {
  while [[ -z "$REMOTE_HOST" ]]; do
    read -rp "Uzak sunucu IP adresi veya hostname: " REMOTE_HOST
  done
}

read_ssh_port() {
  local answer

  while true; do
    read -rp "Uzak SSH portu [22]: " answer
    answer="${answer:-22}"

    if [[ "$answer" =~ ^[0-9]{1,5}$ ]] &&
      ((10#$answer >= 1 && 10#$answer <= 65535)); then
      SSH_PORT="$((10#$answer))"
      return 0
    fi

    echo "Geçerli bir port gir (1-65535)."
  done
}

generate_ssh_key() {
  echo
  echo "Ed25519 anahtarı oluşturuluyor: $PRIVATE_KEY"
  echo "ssh-keygen parola sorarsa isteğe bağlı bir key parolası girebilirsin."

  ssh-keygen -t ed25519 -C "$KEY_NAME" -f "$PRIVATE_KEY"
  chmod 0400 "$PRIVATE_KEY"
  chmod 0644 "$PUBLIC_KEY"
}

copy_public_key() {
  echo
  echo "Public key $REMOTE_USER@$REMOTE_HOST hesabına kopyalanıyor."
  echo "Hedef kullanıcının mevcut parolası veya çalışan bir SSH erişimi gerekebilir."

  if ! ssh-copy-id -i "$PUBLIC_KEY" -p "$SSH_PORT" \
    "$REMOTE_USER@$REMOTE_HOST"; then
    echo "Anahtar dosyaları local bilgisayarda korunuyor." >&2
    echo "Tekrar denemek için:" >&2
    echo "  ssh-copy-id -i $PUBLIC_KEY -p $SSH_PORT $REMOTE_USER@$REMOTE_HOST" >&2
    die "Public key kopyalanamadı. Hedef kullanıcının SSH erişimini kontrol et."
  fi
}

print_completion_summary() {
  echo
  echo "SSH anahtarı oluşturuldu ve kopyalandı:"
  echo "  Private key : $PRIVATE_KEY"
  echo "  Public key  : $PUBLIC_KEY"
  echo "  Comment     : $KEY_NAME"
  echo "  Uzak hesap  : $REMOTE_USER@$REMOTE_HOST"
  echo "  SSH portu   : $SSH_PORT"
  echo
  echo "Bağlantı testi:"
  echo "  ssh -i $PRIVATE_KEY -p $SSH_PORT $REMOTE_USER@$REMOTE_HOST"
}

main() {
  require_dependencies
  read_key_name
  prepare_key_paths
  read_remote_user
  read_remote_host
  read_ssh_port
  generate_ssh_key
  copy_public_key
  print_completion_summary
}

main "$@"
