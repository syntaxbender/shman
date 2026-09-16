#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

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

echo
echo "=== Installing basic server tools ==="

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    wget \
    git \
    net-tools \
    dnsutils \
    iputils-ping \
    traceroute \
    tcpdump \
    jq \
    vim \
    nano \
    htop \
    tree \
    unzip \
    zip \
    tar \
    rsync \
    openssl \
    ca-certificates \
    gnupg \
    lsof \
    software-properties-common \
    unattended-upgrades

echo
echo "=== Disabling unnecessary VM hardware services ==="

mask_unit fwupd.service
mask_unit ModemManager.service
mask_unit udisks2.service

echo
echo "=== Checking iSCSI ==="

ISCSI_IN_USE=0

if command -v iscsiadm &>/dev/null; then
    if iscsiadm -m session 2>/dev/null | grep -q .; then
        ISCSI_IN_USE=1
    fi
fi

if (( ISCSI_IN_USE )); then
    echo "Active iSCSI session found."
    echo "Skipping iSCSI service changes."
else
    echo "No active iSCSI sessions."

    disable_unit iscsid.service
    disable_unit iscsid.socket
    disable_unit open-iscsi.service
fi

echo
echo "=== Checking NFS ==="

if findmnt -rn -t nfs,nfs4 | grep -q .; then
    echo "Active NFS mount found."
    echo "Skipping rpcbind changes."
else
    echo "No active NFS mounts."

    disable_unit rpcbind.service
    disable_unit rpcbind.socket
fi

echo
echo "=== Configuring automatic Ubuntu updates ==="

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Disable the persistent shutdown helper.
# apt-daily-upgrade.timer still runs unattended-upgrade when required.
disable_unit unattended-upgrades.service

systemctl enable --now apt-daily.timer
systemctl enable --now apt-daily-upgrade.timer

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
    snapd.socket
do
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
ps -eo pid,user,comm,rss,%mem --sort=-rss | head -20

echo
echo "=== DONE ==="
