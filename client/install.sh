#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

INSTALL_SSH=0
INSTALL_FWKNOP=0

usage() {
  cat <<EOF
Kullanım: sudo $0 SEÇENEK...

  --ssh      OpenSSH client araçları
  --fwknop   FWKnop client, GnuPG ve OpenSSH client
  --all      Tüm client araçları
EOF
}

parse_arguments() {
  [[ $# -gt 0 ]] || {
    usage >&2
    exit 1
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh) INSTALL_SSH=1 ;;
      --fwknop) INSTALL_FWKNOP=1 ;;
      --all)
        INSTALL_SSH=1
        INSTALL_FWKNOP=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) die "Bilinmeyen seçenek: $1" ;;
    esac
    shift
  done
}

install_packages() {
  local packages=()

  if [[ "$INSTALL_FWKNOP" -eq 1 ]]; then
    packages+=(fwknop-client gnupg openssh-client)
  fi
  if [[ "$INSTALL_SSH" -eq 1 ]]; then
    packages+=(sudo util-linux)
    [[ "$INSTALL_FWKNOP" -eq 1 ]] || packages+=(openssh-client)
  fi

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

main() {
  require_root
  require_command apt-get
  parse_arguments "$@"
  install_packages
  echo "Client araçları kuruldu."
}

main "$@"
