#!/usr/bin/env bash
set -euo pipefail

KEY_NAME=""
KEY_DIR="/mnt/shman-ssh"
RAM_HOME=""
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

  for command_name in ssh ssh-keygen ssh-copy-id sudo mount findmnt id mkdir chmod; do
    require_command "$command_name"
  done
}

harden_process_environment() {
  umask 077
  ulimit -c 0 || die "Core dump limiti kapatılamadı."
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

prepare_ram_key_directory() {
  local current_filesystem=""
  local mount_options=""
  local user_id
  local group_id

  user_id="$(id -u)"
  group_id="$(id -g)"

  sudo mkdir -p "$KEY_DIR"

  if current_filesystem="$(findmnt -rn -M "$KEY_DIR" -o FSTYPE 2>/dev/null)"; then
    [[ "$current_filesystem" == "tmpfs" ]] ||
      die "$KEY_DIR başka bir dosya sistemi tarafından kullanılıyor."
    echo "Mevcut tmpfs kullanılacak: $KEY_DIR"
  else
    sudo mount -t tmpfs \
      -o "size=1M,noswap,mode=700,uid=$user_id,gid=$group_id" \
      tmpfs "$KEY_DIR" ||
      die "tmpfs bağlanamadı. Kernel noswap seçeneğini desteklemiyor olabilir."
  fi

  mount_options="$(findmnt -rn -M "$KEY_DIR" -o OPTIONS)"
  case ",$mount_options," in
    *,noswap,*) ;;
    *) die "$KEY_DIR tmpfs mount'unda noswap seçeneği etkin değil." ;;
  esac

  findmnt -no TARGET,FSTYPE,OPTIONS "$KEY_DIR"

  RAM_HOME="$KEY_DIR/client-home"
  mkdir -p "$RAM_HOME/.ssh"
  chmod 0700 "$RAM_HOME" "$RAM_HOME/.ssh"

  PRIVATE_KEY="$KEY_DIR/$KEY_NAME"
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

  ssh-keygen -t ed25519 -a 100 -C "$KEY_NAME" -f "$PRIVATE_KEY"
  chmod 0400 "$PRIVATE_KEY"
  chmod 0644 "$PUBLIC_KEY"
}

copy_public_key() {
  echo
  echo "Public key $REMOTE_USER@$REMOTE_HOST hesabına kopyalanıyor."
  echo "Hedef kullanıcının mevcut parolası veya çalışan bir SSH erişimi gerekebilir."

  if ! HOME="$RAM_HOME" ssh-copy-id \
    -o "UserKnownHostsFile=$KEY_DIR/known_hosts" \
    -i "$PUBLIC_KEY" -p "$SSH_PORT" \
    "$REMOTE_USER@$REMOTE_HOST"; then
    echo "Anahtar dosyaları tmpfs üzerinde korunuyor." >&2
    echo "Tekrar denemek için:" >&2
    echo "  HOME=$RAM_HOME ssh-copy-id -o UserKnownHostsFile=$KEY_DIR/known_hosts -i $PUBLIC_KEY -p $SSH_PORT $REMOTE_USER@$REMOTE_HOST" >&2
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
  echo "  Depolama    : tmpfs (noswap)"
  echo
  echo "UYARI: Bilgisayar yeniden başlatılırsa veya $KEY_DIR unmount edilirse"
  echo "private key kalıcı olarak kaybolur. Mount otomatik kaldırılmamıştır."
  echo
  echo "Bağlantı testi:"
  echo "  ssh -o UserKnownHostsFile=$KEY_DIR/known_hosts -i $PRIVATE_KEY -p $SSH_PORT $REMOTE_USER@$REMOTE_HOST"
  echo
  echo "Anahtarı yok etmek için:"
  echo "  sudo umount $KEY_DIR"
}

main() {
  harden_process_environment
  require_dependencies
  read_key_name
  prepare_ram_key_directory
  read_remote_user
  read_remote_host
  read_ssh_port
  generate_ssh_key
  copy_public_key
  print_completion_summary
}

main "$@"
