#!/usr/bin/env bash
set -euo pipefail

info(){ echo -e "\n[INFO] $*"; }
warn(){ echo -e "\n[WARN] $*"; }
die(){ echo -e "\n[ERR] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Root olarak çalıştır: sudo ./fwknop_server_prepare.sh"

read -rp "Profile adı, örn mail-prod: " PROFILE
[[ -n "$PROFILE" ]] || die "Profile boş olamaz."

read -rp "Server SSH kullanıcısı [${SUDO_USER:-ubuntu}]: " SERVER_USER
SERVER_USER="${SERVER_USER:-${SUDO_USER:-ubuntu}}"

read -rp "Network interface for fwknopd.conf [ens3]: " PCAP_INTF
PCAP_INTF="${PCAP_INTF:-ens3}"

read -rsp "Server GPG passphrase (boş olabilir): " SERVER_GPG_PASS
echo

ROOT_GPG_HOME="/root/.gnupg"
SERVER_HOME="$(eval echo "~$SERVER_USER")"
[[ -d "$SERVER_HOME" ]] || die "Kullanıcı home dizini bulunamadı: $SERVER_HOME"

SERVER_GPG_NAME="server-${PROFILE}"
SERVER_GPG_EMAIL="server-${PROFILE}@fwknop.local"

SERVER_PUB_OUT="$SERVER_HOME/fwknop-${PROFILE}-server-pub.asc"
HMAC_FILE="$SERVER_HOME/fwknop-${PROFILE}-hmac.key"

info "Türetilen değerler:"
echo "  Server GPG UID: $SERVER_GPG_NAME <$SERVER_GPG_EMAIL>"
echo "  Server public key: $SERVER_PUB_OUT"
echo "  HMAC key: $HMAC_FILE"

info "Çakışma kontrolleri yapılıyor..."

mkdir -p "$ROOT_GPG_HOME"
chmod 700 "$ROOT_GPG_HOME"

if gpg --homedir "$ROOT_GPG_HOME" --list-secret-keys "$SERVER_GPG_EMAIL" >/dev/null 2>&1; then
  die "Bu profile için server secret key zaten var: $SERVER_GPG_EMAIL"
fi

if [[ -e "$SERVER_PUB_OUT" ]]; then
  die "Server public key dosyası zaten var: $SERVER_PUB_OUT"
fi

if [[ -e "$HMAC_FILE" ]]; then
  die "HMAC key dosyası zaten var: $HMAC_FILE"
fi

info "Paketler kuruluyor..."
apt update
apt install -y fwknop-server fwknop-client gnupg iptables-persistent netfilter-persistent openssl

info "UFW kapatılıyor..."
ufw disable || true

info "iptables/IPv6 yönetimi yapılmıyor."
info "Firewall kuralları bu script tarafından oluşturulmaz."

info "Server GPG key root keyring altında oluşturuluyor. Expire yok."
gpg --homedir "$ROOT_GPG_HOME" --batch --pinentry-mode loopback --passphrase "$SERVER_GPG_PASS" \
  --quick-generate-key "$SERVER_GPG_NAME <$SERVER_GPG_EMAIL>" rsa2048 sign 0

SERVER_KEY_ID="$(gpg --homedir "$ROOT_GPG_HOME" --list-secret-keys --with-colons "$SERVER_GPG_EMAIL" | awk -F: '/^sec:/ {print $5; exit}')"
[[ -n "$SERVER_KEY_ID" ]] || die "Server GPG key ID bulunamadı."

info "Server public key export ediliyor..."
gpg --homedir "$ROOT_GPG_HOME" --armor --export "$SERVER_KEY_ID" > "$SERVER_PUB_OUT"
chown "$SERVER_USER:$SERVER_USER" "$SERVER_PUB_OUT"
chmod 644 "$SERVER_PUB_OUT"

info "Profile bazlı HMAC key üretiliyor..."
openssl rand -base64 64 > "$HMAC_FILE"
chown "$SERVER_USER:$SERVER_USER" "$HMAC_FILE"
chmod 600 "$HMAC_FILE"

info "/etc/fwknop/fwknopd.conf yazılıyor..."
cat >/etc/fwknop/fwknopd.conf <<EOF
PCAP_INTF                   $PCAP_INTF;
ENABLE_SPA_PACKET_AGING      Y;
MAX_SPA_PACKET_AGE           60;
EOF

cat <<EOF

========================================
SERVER PREPARE OK
========================================

Profile:
  $PROFILE

Server GPG UID:
  $SERVER_GPG_EMAIL

Server GPG key ID:
  $SERVER_KEY_ID

Server public key:
  $SERVER_PUB_OUT

HMAC key:
  $HMAC_FILE

Sonraki adım client tarafında:
  ./fwknop_client_exchange.sh

Client exchange sırasında aynı profile adını kullan.
SPA portu script üretmez; sen elle belirleyip firewall'da açmalısın.

EOF
