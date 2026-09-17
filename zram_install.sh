#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

KERNEL=""
INITRD=""

load_kernel_context() {
  KERNEL="$(uname -r)"
  INITRD="/boot/initrd.img-$KERNEL"
  echo "Kernel: $KERNEL"
}

install_zram_generator() {
  echo
  echo "=== Installing ZRAM generator ==="

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-zram-generator
}

ensure_zram_module() {
  if modinfo zram &>/dev/null; then
    return 0
  fi

  echo "zram module not found."
  echo "Installing linux-modules-extra-$KERNEL..."
  DEBIAN_FRONTEND=noninteractive \
    apt-get install -y "linux-modules-extra-$KERNEL"

  modinfo zram &>/dev/null || die "zram kernel module is still unavailable."
}

configure_zram_generator() {
  echo
  echo "=== Configuring ZRAM ==="

  cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
}

configure_early_module_loading() {
  echo
  echo "=== Configuring early zram module loading ==="

  touch /etc/initramfs-tools/modules
  if ! grep -qxF 'zram' /etc/initramfs-tools/modules; then
    echo 'zram' >> /etc/initramfs-tools/modules
  fi

  # Rebuild initramfs when zram is missing from it.
  if [[ ! -f "$INITRD" ]]; then
    echo "Rebuilding initramfs..."
    update-initramfs -u -k "$KERNEL"
    return 0
  fi

  if ! lsinitramfs "$INITRD" 2>/dev/null | grep '/zram\.ko' >/dev/null; then
    echo "Adding zram module to initramfs..."
    update-initramfs -u -k "$KERNEL"
  else
    echo "zram is already present in initramfs."
  fi
}

configure_swappiness() {
  echo
  echo "=== Configuring swappiness ==="

  cat >/etc/sysctl.d/99-zram.conf <<'EOF'
vm.swappiness=100
EOF

  sysctl -w vm.swappiness=100 >/dev/null
}

start_zram() {
  echo
  echo "=== Loading zram module ==="

  modprobe zram
  systemctl daemon-reload

  if swapon --show=NAME --noheadings 2>/dev/null |
    awk '{$1=$1};1' |
    grep -x '/dev/zram0' >/dev/null; then
    echo "/dev/zram0 is already active."
    echo "Current device is left untouched."
    return 0
  fi

  echo "Starting /dev/zram0..."
  systemctl start systemd-zram-setup@zram0.service
}

print_status() {
  echo
  echo "=== STATUS ==="

  echo
  echo "--- module ---"
  lsmod | grep '^zram' || true

  echo
  echo "--- zram ---"
  zramctl || true

  echo
  echo "--- swap ---"
  swapon --show || true

  echo
  echo "--- swappiness ---"
  sysctl vm.swappiness

  echo
  echo "--- compression algorithms ---"
  if [[ -e /sys/block/zram0/comp_algorithm ]]; then
    cat /sys/block/zram0/comp_algorithm
  fi

  echo
  echo "=== DONE ==="
  echo "A reboot is recommended after the first installation."
}

main() {
  require_root
  load_kernel_context
  install_zram_generator
  ensure_zram_module
  configure_zram_generator
  configure_early_module_loading
  configure_swappiness
  start_zram
  print_status
}

main "$@"
