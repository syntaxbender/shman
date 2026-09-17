#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../../lib/config.sh
source "$REPO_ROOT/lib/config.sh"

DEFAULT_TARGET_USER="ubuntu"
TARGET_USERS=()
SSH_ALLOW_USERS=""
SSHD_CONFIG="/etc/ssh/sshd_config"
MANAGED_CONFIG="/etc/ssh/sshd_config.d/00-shman-hardening.conf"

MANAGED_CONFIG_STAGE=""
CURRENT_PORT=""
SSH_PORT=""
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

  upsert_config_line \
    "$MANAGED_CONFIG_STAGE" \
    "^[[:space:]]*${option}[[:space:]]+" \
    "${option} ${value}" \
    1
}

require_dependencies() {
  require_command_or_install sshd "sudo ./server/install.sh --ssh"
  local commands=(
    getent id ssh-keygen systemctl install mktemp cp rm chmod chown
    awk ss grep sed
  )

  require_commands "${commands[@]}"
}

select_target_users() {
  local answer
  local raw_user
  local target_user
  local -a raw_users=()
  local -A seen_users=()

  read -rp "SSH erişimi verilecek kullanıcılar (virgülle ayır) [$DEFAULT_TARGET_USER]: " answer
  answer="${answer:-$DEFAULT_TARGET_USER}"

  IFS=',' read -r -a raw_users <<<"$answer"
  for raw_user in "${raw_users[@]}"; do
    target_user="${raw_user#"${raw_user%%[![:space:]]*}"}"
    target_user="${target_user%"${target_user##*[![:space:]]}"}"

    [[ -n "$target_user" ]] || die "Kullanıcı listesinde boş bir kayıt var."
    [[ "$target_user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] ||
      die "Geçersiz kullanıcı adı: $target_user"
    [[ "$target_user" != "root" ]] ||
      die "Root SSH erişimi bu script tarafından kapatılır; root seçilemez."

    if [[ -z "${seen_users[$target_user]:-}" ]]; then
      TARGET_USERS+=("$target_user")
      seen_users[$target_user]=1
    fi
  done

  [[ "${#TARGET_USERS[@]}" -gt 0 ]] || die "En az bir kullanıcı girilmelidir."
  SSH_ALLOW_USERS="${TARGET_USERS[*]}"
}

validate_target_users() {
  local target_user
  local user_entry
  local user_home
  local user_shell

  for target_user in "${TARGET_USERS[@]}"; do
    user_entry="$(getent passwd "$target_user")" ||
      die "$target_user kullanıcısı bulunamadı."

    user_home="$(awk -F: '{ print $6 }' <<<"$user_entry")"
    user_shell="$(awk -F: '{ print $7 }' <<<"$user_entry")"

    [[ -d "$user_home" ]] ||
      die "$target_user kullanıcısının home dizini bulunamadı: $user_home"

    case "$user_shell" in
      */nologin|*/false)
        die "$target_user SSH oturumu açabilen bir kullanıcı değil: $user_shell"
        ;;
    esac
  done
}

confirm_authorized_keys() {
  local target_user
  local user_entry
  local user_home
  local authorized_keys
  local key_summary

  for target_user in "${TARGET_USERS[@]}"; do
    user_entry="$(getent passwd "$target_user")"
    user_home="$(awk -F: '{ print $6 }' <<<"$user_entry")"
    authorized_keys="$user_home/.ssh/authorized_keys"

    [[ -f "$authorized_keys" && -s "$authorized_keys" ]] ||
      die "$target_user için ekli SSH key yok: $authorized_keys bulunamadı veya boş."

    if ! key_summary="$(ssh-keygen -lf "$authorized_keys" 2>&1)" ||
      [[ -z "$key_summary" ]]; then
      die "$authorized_keys içinde geçerli bir public key bulunamadı."
    fi

    echo "$target_user kullanıcısının authorized_keys kayıtları (parmak izi ve yorum):"
    echo "$key_summary"
    echo

    ask_default_no "$target_user için yukarıdaki key kayıtları doğru mu?" ||
      die "$target_user key kayıtları kullanıcı tarafından onaylanmadı."
  done
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
  read_port "SSH TCP portu" "$CURRENT_PORT" SSH_PORT
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
  echo "Uygulanıyor: $SSH_ALLOW_USERS kullanıcıları, yalnız public key, TCP/$SSH_PORT"
  echo "Not: Bu script firewall kuralı eklemez."
}

prepare_managed_config() {
  install -d -m 0755 /etc/ssh/sshd_config.d
  MANAGED_CONFIG_STAGE="$(mktemp)"

  if [[ -f "$MANAGED_CONFIG" ]]; then
    cp -p -- "$MANAGED_CONFIG" "$MANAGED_CONFIG_STAGE"
    return 0
  fi

  printf '%s\n' '# Managed by shman/server/config/ssh.sh' >"$MANAGED_CONFIG_STAGE"
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
  set_sshd_option AllowUsers "$SSH_ALLOW_USERS"
  set_sshd_option AuthorizedKeysFile .ssh/authorized_keys
  set_sshd_option HostbasedAuthentication no
  set_sshd_option GSSAPIAuthentication no
  set_sshd_option KerberosAuthentication no
}

install_managed_config() {
  install_validated_config \
    "$MANAGED_CONFIG_STAGE" "$MANAGED_CONFIG" 0644 \
    sshd -t -f "$SSHD_CONFIG" ||
  die "Yeni SSH yapılandırması geçersiz; değişiklik uygulanmadı."
}

secure_authorized_keys() {
  local target_user
  local user_entry
  local user_home
  local ssh_dir
  local authorized_keys
  local target_group

  for target_user in "${TARGET_USERS[@]}"; do
    user_entry="$(getent passwd "$target_user")"
    user_home="$(awk -F: '{ print $6 }' <<<"$user_entry")"
    ssh_dir="$user_home/.ssh"
    authorized_keys="$ssh_dir/authorized_keys"
    target_group="$(id -gn "$target_user")"

    chown "$target_user:$target_group" "$ssh_dir" "$authorized_keys"
    chmod 0700 "$ssh_dir"
    chmod 0600 "$authorized_keys"
  done
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
  echo "  Kullanıcılar: $SSH_ALLOW_USERS"
  echo "  Giriş      : yalnız public key"
  echo "  Root/parola: kapalı"
  echo
  echo "Firewall'da TCP/$SSH_PORT portunu açmayı ve mevcut oturumu kapatmadan"
  echo "yeni bir terminalden bağlantıyı test etmeyi unutma:"
  echo "  ssh -p $SSH_PORT KULLANICI@SUNUCU_IP"
}

cleanup() {
  if [[ -n "$MANAGED_CONFIG_STAGE" ]]; then
    rm -f -- "$MANAGED_CONFIG_STAGE"
  fi
}

main() {
  require_root
  require_dependencies
  select_target_users
  validate_target_users
  confirm_authorized_keys
  validate_current_sshd_config
  select_ssh_port
  validate_selected_port
  print_apply_notice
  prepare_managed_config
  apply_hardening_options
  install_managed_config
  secure_authorized_keys
  reload_ssh_service
  print_completion_summary
}

trap cleanup EXIT
main "$@"
