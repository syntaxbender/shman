#!/usr/bin/env bash
set -euo pipefail

USERNAME=""
USER_HOME=""
SHELL_ACCESS=0
LOGIN_SHELL="/usr/sbin/nologin"

die() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "please run as root"
}

require_dependencies() {
  local command_name
  local commands=(useradd usermod passwd mkdir chmod chown)

  for command_name in "${commands[@]}"; do
    require_command "$command_name"
  done
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--user)
        [[ $# -ge 2 ]] || die "--user requires a value"
        [[ -n "$2" ]] || die "--user requires a value"
        USERNAME="$2"
        shift 2
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 --user USERNAME" >&2
    die "--user argument is required"
  fi
}

validate_username() {
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] ||
    die "invalid Linux username: $USERNAME"

  USER_HOME="/home/$USERNAME"
}

ask_shell_access() {
  local answer

  while true; do
    read -rp "Bu kullanıcı SSH/shell erişimi alacak mı? [y/N]: " answer
    answer="${answer,,}"

    case "$answer" in
      y|yes|e|evet)
        SHELL_ACCESS=1
        LOGIN_SHELL="/bin/bash"
        return 0
        ;;
      ""|n|no|h|hayir|hayır)
        SHELL_ACCESS=0
        LOGIN_SHELL="/usr/sbin/nologin"
        return 0
        ;;
      *)
        echo "Lütfen y veya n gir."
        ;;
    esac
  done
}

print_ssh_key_instructions() {
  echo
  echo "Bu kullanıcı SSH/shell erişimi alacak."
  echo "Her SSH kullanıcısına özel bir public key, o kullanıcının"
  echo "$USER_HOME/.ssh/authorized_keys dosyasına kopyalanmalıdır."
  echo "Local bilgisayarda ssh_client_setup.sh dosyasının çalıştırılması gerekir."
  echo "ssh-copy-id, ilk key kopyalamasında bu kullanıcı için oluşturma"
  echo "sırasında belirlenen parolayı isteyecektir."
  echo "Key kopyalandıktan sonra ssh_server_setup.sh ile parola tabanlı"
  echo "SSH girişi kapatılabilir."
  echo
}

prepare_login_access() {
  [[ -x "$LOGIN_SHELL" ]] || die "login shell not found: $LOGIN_SHELL"

  if [[ "$SHELL_ACCESS" -eq 1 ]]; then
    print_ssh_key_instructions
  fi
}

create_user_account() {
  if ! useradd -m -d "$USER_HOME" -s "$LOGIN_SHELL" -U "$USERNAME" ||
    ! mkdir -p "$USER_HOME/public_html" ||
    ! chmod -R 750 "$USER_HOME" ||
    ! chown -R "$USERNAME:$USERNAME" "$USER_HOME" ||
    ! usermod -aG "$USERNAME" www-data; then
    die "user could not be created: $USERNAME"
  fi
}

configure_user_password() {
  if [[ "$SHELL_ACCESS" -ne 1 ]]; then
    return 0
  fi

  echo "Password for $USERNAME:"
  passwd "$USERNAME" || die "password could not be set for $USERNAME"
}

print_completion_summary() {
  echo
  echo "User created: $USERNAME"
  echo "Login shell: $LOGIN_SHELL"
}

main() {
  require_root
  require_dependencies
  parse_arguments "$@"
  validate_username
  ask_shell_access
  prepare_login_access
  create_user_account
  configure_user_password
  print_completion_summary
}

main "$@"
