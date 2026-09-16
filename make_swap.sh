#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SWAP_SIZE=""
SWAP_FILE="/swapfile"
FSTAB_ENTRY="/swapfile none swap sw 0 0"

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--size)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "--size megabayt değeri gerektirir."
        SWAP_SIZE="$2"
        shift 2
        ;;
      *) die "Bilinmeyen seçenek: $1" ;;
    esac
  done

  [[ -n "$SWAP_SIZE" ]] || die "Kullanım: $0 --size 1536"
  [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] && ((10#$SWAP_SIZE > 0)) ||
    die "Swap boyutu pozitif bir tam sayı olmalıdır."
}

swap_is_active() {
  swapon --show=NAME --noheadings 2>/dev/null |
    awk '{$1=$1};1' |
    grep -Fxq "$SWAP_FILE"
}

prepare_swap_file() {
  if swap_is_active; then
    echo "$SWAP_FILE zaten aktif; yeniden oluşturulmadı."
    return 0
  fi

  if [[ -e "$SWAP_FILE" ]]; then
    echo "$SWAP_FILE zaten var; mevcut swap imzasıyla etkinleştiriliyor."
    swapon "$SWAP_FILE" ||
      die "$SWAP_FILE mevcut fakat geçerli bir swap dosyası olarak etkinleştirilemedi."
    return 0
  fi

  fallocate -l "${SWAP_SIZE}M" "$SWAP_FILE"
  chmod 0600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
}

ensure_fstab_entry() {
  if grep -Eq '^[[:space:]]*/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]+sw[[:space:]]+0[[:space:]]+0([[:space:]]|$)' /etc/fstab; then
    echo "/etc/fstab kaydı zaten mevcut."
    return 0
  fi

  printf '%s\n' "$FSTAB_ENTRY" >>/etc/fstab
  echo "/etc/fstab kaydı eklendi."
}

main() {
  require_root
  require_commands fallocate chmod mkswap swapon awk grep
  parse_arguments "$@"
  prepare_swap_file
  ensure_fstab_entry
}

main "$@"
