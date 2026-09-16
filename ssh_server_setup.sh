#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TARGET_USER="ubuntu"
TARGET_USER=""
SSHD_CONFIG="/etc/ssh/sshd_config"
MANAGED_CONFIG="/etc/ssh/sshd_config.d/00-shman-hardening.conf"

CONFIG_BACKUP=""
CURRENT_PORT=""
SSH_PORT=""
USER_HOME=""
USER_SHELL=""
SSH_DIR=""
AUTHORIZED_KEYS=""

die() {
  echo "Hata: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Gerekli komut bulunamadı: $1"
}

ask_default_no() {
  local prompt="$1"
  local answer

  while true; do
    read -rp "$prompt [y/N]: " answer
    answer="${answer,,}"

    case "$answer" in
      y|yes|e|evet) return 0 ;;
      ""|n|no|h|hayir|hayır) return 1 ;;
      *) echo "Lütfen y veya n gir." ;;
    esac
  done
}

read_port() {
  local default_port="$1"
  local answer

  while true; do
    read -rp "SSH TCP portu [$default_port]: " answer
    answer="${answer:-$default_port}"

    if [[ "$answer" =~ ^[0-9]{1,5}$ ]] &&
      ((10#$answer >= 1 && 10#$answer <= 65535)); then
      SSH_PORT="$((10#$answer))"
      return 0
    fi

    echo "Geçerli bir port gir (1-65535)."
  done
}

port_is_listening() {
  local port="$1"

  ss -H -ltn | awk -v port="$port" '
    $4 ~ (":" port "$") { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

set_sshd_option() {
  local option="$1"
  local value="$2"

  if grep -Eiq "^[[:space:]]*${option}[[:space:]]+" "$MANAGED_CONFIG"; then
    sed -Ei "s|^[[:space:]]*${option}[[:space:]]+.*$|${option} ${value}|I" \
      "$MANAGED_CONFIG"
  else
    printf '%s %s\n' "$option" "$value" >>"$MANAGED_CONFIG"
  fi
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Bu script root olarak çalışmalı: sudo bash $0"
}

require_dependencies() {
  local command_name
  local commands=(
    getent id sshd ssh-keygen systemctl install mktemp cp rm chmod chown
    awk ss grep sed
  )

  for command_name in "${commands[@]}"; do
    require_command "$command_name"
  done
}

select_target_user() {
  local answer

  read -rp "SSH erişimi verilecek kullanıcı [$DEFAULT_TARGET_USER]: " answer
  TARGET_USER="${answer:-$DEFAULT_TARGET_USER}"

  [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] ||
    die "Geçersiz kullanıcı adı: $TARGET_USER"

  [[ "$TARGET_USER" != "root" ]] ||
    die "Root SSH erişimi bu script tarafından kapatılır; root seçilemez."
}

load_target_user_paths() {
  local user_entry

  user_entry="$(getent passwd "$TARGET_USER")" ||
    die "$TARGET_USER kullanıcısı bulunamadı."

  USER_HOME="$(awk -F: '{ print $6 }' <<<"$user_entry")"
  USER_SHELL="$(awk -F: '{ print $7 }' <<<"$user_entry")"

  [[ -d "$USER_HOME" ]] ||
    die "$TARGET_USER kullanıcısının home dizini bulunamadı: $USER_HOME"

  case "$USER_SHELL" in
    */nologin|*/false)
      die "$TARGET_USER SSH oturumu açabilen bir kullanıcı değil: $USER_SHELL"
      ;;
  esac

  SSH_DIR="$USER_HOME/.ssh"
  AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
}

confirm_authorized_keys() {
  local key_summary

  [[ -f "$AUTHORIZED_KEYS" && -s "$AUTHORIZED_KEYS" ]] ||
    die "Ekli SSH key yok: $AUTHORIZED_KEYS bulunamadı veya boş."

  if ! key_summary="$(ssh-keygen -lf "$AUTHORIZED_KEYS" 2>&1)" ||
    [[ -z "$key_summary" ]]; then
    die "$AUTHORIZED_KEYS içinde geçerli bir public key bulunamadı."
  fi

  echo "Bulunan authorized_keys kayıtları (parmak izi ve yorum):"
  echo "$key_summary"
  echo

  ask_default_no "Yukarıdaki key kayıtları doğru mu?" ||
    die "Key kullanıcı tarafından onaylanmadı."
}

validate_current_sshd_config() {
  [[ -f "$SSHD_CONFIG" ]] ||
    die "OpenSSH server yapılandırması bulunamadı: $SSHD_CONFIG"

  sshd -t -f "$SSHD_CONFIG" ||
    die "Mevcut SSH yapılandırması geçersiz."
}

select_ssh_port() {
  CURRENT_PORT="$(
    sshd -T -f "$SSHD_CONFIG" 2>/dev/null |
      awk '$1 == "port" { print $2; exit }' || true
  )"

  [[ "$CURRENT_PORT" =~ ^[0-9]+$ ]] || CURRENT_PORT=22
  read_port "$CURRENT_PORT"
}

validate_selected_port() {
  if ! port_is_listening "$SSH_PORT"; then
    return 0
  fi

  if [[ "$SSH_PORT" == "$CURRENT_PORT" ]]; then
    echo "TCP/$SSH_PORT mevcut SSH portu; kullanılmaya devam edilecek."
    return 0
  fi

  die "TCP/$SSH_PORT başka bir servis tarafından kullanılıyor."
}

print_apply_notice() {
  echo
  echo "Uygulanıyor: $TARGET_USER kullanıcısı, yalnız public key, TCP/$SSH_PORT"
  echo "Not: Bu script firewall kuralı eklemez."
}

prepare_managed_config() {
  install -d -m 0755 /etc/ssh/sshd_config.d

  if [[ -f "$MANAGED_CONFIG" ]]; then
    CONFIG_BACKUP="$(mktemp /tmp/shman-ssh-config.XXXXXX)"
    cp -p -- "$MANAGED_CONFIG" "$CONFIG_BACKUP"
    return 0
  fi

  install -m 0644 /dev/null "$MANAGED_CONFIG"
  printf '%s\n' '# Managed by shman/ssh_server_setup.sh' >>"$MANAGED_CONFIG"
}

apply_hardening_options() {
  set_sshd_option Port "$SSH_PORT"
  set_sshd_option PermitRootLogin no
  set_sshd_option PubkeyAuthentication yes
  set_sshd_option AuthenticationMethods publickey
  set_sshd_option PasswordAuthentication no
  set_sshd_option KbdInteractiveAuthentication no
  set_sshd_option ChallengeResponseAuthentication no
  set_sshd_option PermitEmptyPasswords no
  set_sshd_option UsePAM yes
  set_sshd_option AllowUsers "$TARGET_USER"
  set_sshd_option AuthorizedKeysFile .ssh/authorized_keys
  set_sshd_option HostbasedAuthentication no
  set_sshd_option GSSAPIAuthentication no
  set_sshd_option KerberosAuthentication no
  chmod 0644 "$MANAGED_CONFIG"
}

restore_managed_config() {
  if [[ -n "$CONFIG_BACKUP" ]]; then
    cp -p -- "$CONFIG_BACKUP" "$MANAGED_CONFIG"
  else
    rm -f -- "$MANAGED_CONFIG"
  fi
}

validate_updated_sshd_config() {
  if sshd -t -f "$SSHD_CONFIG"; then
    return 0
  fi

  restore_managed_config
  die "Yeni SSH yapılandırması geçersiz; değişiklik uygulanmadı."
}

secure_authorized_keys() {
  local target_group

  target_group="$(id -gn "$TARGET_USER")"
  chown "$TARGET_USER:$target_group" "$SSH_DIR" "$AUTHORIZED_KEYS"
  chmod 0700 "$SSH_DIR"
  chmod 0600 "$AUTHORIZED_KEYS"
}

reload_ssh_service() {
  if systemctl is-active --quiet ssh.socket; then
    systemctl daemon-reload
    systemctl restart ssh.socket
  else
    systemctl reload-or-restart ssh.service
  fi
}

print_completion_summary() {
  echo
  echo "SSH yapılandırması tamamlandı:"
  echo "  Port       : $SSH_PORT"
  echo "  Kullanıcı  : $TARGET_USER"
  echo "  Giriş      : yalnız public key"
  echo "  Root/parola: kapalı"
  echo
  echo "Firewall'da TCP/$SSH_PORT portunu açmayı ve mevcut oturumu kapatmadan"
  echo "yeni bir terminalden bağlantıyı test etmeyi unutma:"
  echo "  ssh -p $SSH_PORT $TARGET_USER@SUNUCU_IP"
}

cleanup() {
  if [[ -n "$CONFIG_BACKUP" ]]; then
    rm -f -- "$CONFIG_BACKUP"
  fi
}

main() {
  require_root
  require_dependencies
  select_target_user
  load_target_user_paths
  confirm_authorized_keys
  validate_current_sshd_config
  select_ssh_port
  validate_selected_port
  print_apply_notice
  prepare_managed_config
  apply_hardening_options
  validate_updated_sshd_config
  secure_authorized_keys
  reload_ssh_service
  print_completion_summary
}

trap cleanup EXIT
main "$@"
