#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root:"
    echo "  sudo bash $0"
    exit 1
fi

KERNEL="$(uname -r)"
INITRD="/boot/initrd.img-$KERNEL"

echo "Kernel: $KERNEL"

echo
echo "=== Installing ZRAM generator ==="

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    systemd-zram-generator

# OCI minimal kernels may keep zram in linux-modules-extra.
if ! modinfo zram &>/dev/null; then
    echo "zram module not found."
    echo "Installing linux-modules-extra-$KERNEL..."

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "linux-modules-extra-$KERNEL"
fi

if ! modinfo zram &>/dev/null; then
    echo "ERROR: zram kernel module is still unavailable."
    exit 1
fi

echo
echo "=== Configuring ZRAM ==="

cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF

echo
echo "=== Configuring early zram module loading ==="

touch /etc/initramfs-tools/modules

if ! grep -qxF 'zram' /etc/initramfs-tools/modules; then
    echo 'zram' >> /etc/initramfs-tools/modules
fi

# Rebuild initramfs when zram is missing from it.
if [[ -f "$INITRD" ]]; then
    if ! lsinitramfs "$INITRD" 2>/dev/null | grep -q '/zram\.ko'; then
        echo "Adding zram module to initramfs..."
        update-initramfs -u -k "$KERNEL"
    else
        echo "zram is already present in initramfs."
    fi
else
    echo "Rebuilding initramfs..."
    update-initramfs -u -k "$KERNEL"
fi

echo
echo "=== Configuring swappiness ==="

cat > /etc/sysctl.d/99-zram.conf <<'EOF'
vm.swappiness=100
EOF

sysctl -w vm.swappiness=100 >/dev/null

echo
echo "=== Loading zram module ==="

modprobe zram

systemctl daemon-reload

# Don't tear down an already active zram device.
if swapon --show=NAME --noheadings 2>/dev/null \
    | awk '{$1=$1};1' \
    | grep -qx '/dev/zram0'; then

    echo "/dev/zram0 is already active."
    echo "Current device is left untouched."

else
    echo "Starting /dev/zram0..."

    systemctl start systemd-zram-setup@zram0.service
fi

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
