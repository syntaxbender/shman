#!/usr/bin/env bash

die() {
  echo "Hata: $*" >&2
  exit 1
}

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Bu script root olarak çalıştırılmalıdır."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Gerekli komut bulunamadı: $1"
}

require_commands() {
  local command_name

  for command_name in "$@"; do
    require_command "$command_name"
  done
}

ask_default_yes() {
  local prompt="$1"
  local answer

  while true; do
    read -rp "$prompt [Y/n]: " answer
    answer="${answer,,}"

    case "$answer" in
      ""|y|yes|e|evet) return 0 ;;
      n|no|h|hayir|hayır) return 1 ;;
      *) echo "Lütfen y veya n gir." ;;
    esac
  done
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
  local prompt="$1"
  local default_port="$2"
  local result_name="$3"
  local answer
  local -n result="$result_name"

  while true; do
    read -rp "$prompt [$default_port]: " answer
    answer="${answer:-$default_port}"

    if [[ "$answer" =~ ^[0-9]{1,5}$ ]] &&
      ((10#$answer >= 1 && 10#$answer <= 65535)); then
      result="$((10#$answer))"
      return 0
    fi

    echo "Geçerli bir port gir (1-65535)."
  done
}
