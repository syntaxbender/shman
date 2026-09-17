#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

unit_exists() {
    systemctl cat "$1" &>/dev/null
}

mask_unit() {
    local unit="$1"

    if unit_exists "$unit"; then
        echo "Masking: $unit"
        systemctl mask --now "$unit" || true
    else
        echo "Not installed: $unit"
    fi
}

disable_unit() {
    local unit="$1"

    if unit_exists "$unit"; then
        echo "Disabling: $unit"
        systemctl disable --now "$unit" || true
    else
        echo "Not installed: $unit"
    fi
}

validate_dependencies() {
  require_commands systemctl findmnt free ps grep head dpkg-query

  if [[ "$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null || true)" != "install ok installed" ]]; then
    die "unattended-upgrades kurulu değil. Önce çalıştır: sudo ./server/install.sh --base"
  fi
}

disable_unnecessary_vm_services() {
  echo
  echo "=== Disabling unnecessary VM hardware services ==="

  mask_unit fwupd.service
  mask_unit ModemManager.service
  mask_unit udisks2.service
}

configure_iscsi_services() {
  local iscsi_in_use=0

  echo
  echo "=== Checking iSCSI ==="

  if command -v iscsiadm &>/dev/null &&
    iscsiadm -m session 2>/dev/null | grep . >/dev/null; then
    iscsi_in_use=1
  fi

  if ((iscsi_in_use)); then
    echo "Active iSCSI session found."
    echo "Skipping iSCSI service changes."
    return 0
  fi

  echo "No active iSCSI sessions."
  disable_unit iscsid.service
  disable_unit iscsid.socket
  disable_unit open-iscsi.service
}

configure_nfs_services() {
  echo
  echo "=== Checking NFS ==="

  if findmnt -rn -t nfs,nfs4 | grep . >/dev/null; then
    echo "Active NFS mount found."
    echo "Skipping rpcbind changes."
    return 0
  fi

  echo "No active NFS mounts."
  disable_unit rpcbind.service
  disable_unit rpcbind.socket
}

configure_automatic_updates() {
  echo
  echo "=== Configuring automatic Ubuntu updates ==="

  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  # Disable the persistent shutdown helper.
  # apt-daily-upgrade.timer still runs unattended-upgrade when required.
  disable_unit unattended-upgrades.service

  systemctl enable --now apt-daily.timer
  systemctl enable --now apt-daily-upgrade.timer
}

configure_snapd() {
  echo
  echo "=== Configuring snapd ==="

  # Do not keep snapd resident simply because of boot.
  # snapd.socket remains enabled so it can be activated when required.
  if unit_exists snapd.service; then
    systemctl disable snapd.service || true
    systemctl stop snapd.service || true
  fi

  if unit_exists snapd.socket; then
    systemctl enable --now snapd.socket
  fi

  echo
  echo "NOTE:"
  echo "Oracle Cloud Agent updater can invoke snap and wake snapd again."
  echo "Oracle Cloud Agent itself is NOT disabled by this script."
}

print_status() {
  local unit

  echo
  echo "=================================================="
  echo " STATUS"
  echo "=================================================="

  echo
  echo "=== Memory ==="
  free -m

  echo
  echo "=== Service states ==="

  for unit in \
    fwupd.service \
    ModemManager.service \
    udisks2.service \
    iscsid.service \
    iscsid.socket \
    open-iscsi.service \
    rpcbind.service \
    rpcbind.socket \
    unattended-upgrades.service \
    snapd.service \
    snapd.socket; do
    if unit_exists "$unit"; then
      printf "%-38s enabled=%-10s active=%s\n" \
        "$unit" \
        "$(systemctl is-enabled "$unit" 2>/dev/null || true)" \
        "$(systemctl is-active "$unit" 2>/dev/null || true)"
    fi
  done

  echo
  echo "=== Automatic update timers ==="
  systemctl list-timers \
    apt-daily.timer \
    apt-daily-upgrade.timer \
    --no-pager

  echo
  echo "=== Failed units ==="
  systemctl --failed --no-pager

  echo
  echo "=== Largest processes ==="
  ps -eo pid,user,comm,rss,%mem --sort=-rss | head -20 || true

  echo
  echo "=== DONE ==="
}

main() {
  require_root
  validate_dependencies
  disable_unnecessary_vm_services
  configure_iscsi_services
  configure_nfs_services
  configure_automatic_updates
  configure_snapd
  print_status
}

main "$@"
