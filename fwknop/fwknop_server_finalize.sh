#!/usr/bin/env bash
set -euo pipefail

info(){ echo -e "\n[INFO] $*"; }
warn(){ echo -e "\n[WARN] $*"; }
die(){ echo -e "\n[ERR] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Root olarak çalıştır: sudo ./fwknop_server_finalize.sh"

read -rp "Profile adı, örn mail-prod: " PROFILE
[[ -n "$PROFILE" ]] || die "Profile boş olamaz."

read -rp "Server SSH kullanıcısı [${SUDO_USER:-ubuntu}]: " SERVER_USER
SERVER_USER="${SERVER_USER:-${SUDO_USER:-ubuntu}}"

read -rp "Açılıp kapatılacak olan SSH portu [22]: " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port numerik olmalı."

read -rp "fwknop UDP port [62201]: " SPA_PORT
SPA_PORT="${SPA_PORT:-62201}"
[[ "$SPA_PORT" =~ ^[0-9]+$ ]] || die "SPA port numerik olmalı."

read -rsp "Server GPG passphrase (boş olabilir): " SERVER_GPG_PASS
echo

ROOT_GPG_HOME="/root/.gnupg"
SERVER_HOME="$(eval echo "~$SERVER_USER")"
CLIENT_PUB="$SERVER_HOME/fwknop-${PROFILE}-client-pub.asc"
HMAC_FILE="$SERVER_HOME/fwknop-${PROFILE}-hmac.key"
SERVER_GPG_EMAIL="server-${PROFILE}@fwknop.local"

info "Türetilen değerler:"
echo "  Client public key: $CLIENT_PUB"
echo "  HMAC key: $HMAC_FILE"
echo "  Server GPG UID: $SERVER_GPG_EMAIL"

[[ -f "$CLIENT_PUB" ]] || die "Client public key bulunamadı: $CLIENT_PUB"
[[ -f "$HMAC_FILE" ]] || die "HMAC key bulunamadı: $HMAC_FILE"

info "Root GPG keyring içinde server private key aranıyor..."
mkdir -p "$ROOT_GPG_HOME"
chmod 700 "$ROOT_GPG_HOME"

SERVER_KEY_ID="$(gpg --homedir "$ROOT_GPG_HOME" --list-secret-keys --with-colons "$SERVER_GPG_EMAIL" | awk -F: '/^sec:/ {print $5; exit}')"
[[ -n "$SERVER_KEY_ID" ]] || die "Root keyring içinde server secret key bulunamadı: $SERVER_GPG_EMAIL

Önce fwknop_server_prepare.sh adımını çalıştır veya key'i root keyring'e import et."

info "Client public key ID okunuyor..."
CLIENT_KEY_ID="$(gpg --homedir "$ROOT_GPG_HOME" --show-keys --with-colons "$CLIENT_PUB" | awk -F: '/^pub:/ {print $5; exit}')"
[[ -n "$CLIENT_KEY_ID" ]] || die "Client public key ID bulunamadı."

if gpg --homedir "$ROOT_GPG_HOME" --list-keys "$CLIENT_KEY_ID" >/dev/null 2>&1; then
  warn "Root GPG keyring içinde bu client public key zaten var: $CLIENT_KEY_ID"
  read -rp "Overwrite edilsin mi? [y/N]: " OVERWRITE_CLIENT_KEY
  OVERWRITE_CLIENT_KEY="${OVERWRITE_CLIENT_KEY:-N}"
  [[ "$OVERWRITE_CLIENT_KEY" =~ ^[Yy]$ ]] || die "Kullanıcı iptal etti. Client key overwrite edilmedi."

  EXISTING_CLIENT_KEY_FPR="$(gpg --homedir "$ROOT_GPG_HOME" --with-colons --list-keys "$CLIENT_KEY_ID" | awk -F: '/^fpr:/ {print $10; exit}')"
  [[ -n "$EXISTING_CLIENT_KEY_FPR" ]] || die "Mevcut client key fingerprint bulunamadı."
  gpg --homedir "$ROOT_GPG_HOME" --batch --yes --delete-secret-and-public-key "$EXISTING_CLIENT_KEY_FPR"
fi

info "Client public key root GPG home'a import ediliyor..."
gpg --homedir "$ROOT_GPG_HOME" --import "$CLIENT_PUB"

CLIENT_KEY_FPR="$(gpg --homedir "$ROOT_GPG_HOME" --with-colons --list-keys "$CLIENT_KEY_ID" | awk -F: '/^fpr:/ {print $10; exit}')"
[[ -n "$CLIENT_KEY_FPR" ]] || die "Client public key fingerprint bulunamadı."

info "Client public key server private key ile imzalanıyor..."
gpg --homedir "$ROOT_GPG_HOME" --batch --yes --pinentry-mode loopback \
  --passphrase "$SERVER_GPG_PASS" --local-user "$SERVER_KEY_ID" \
  --quick-sign-key "$CLIENT_KEY_FPR"

info "Client public key ownertrust seviyesi ayarlanıyor (2 = I do NOT trust)..."
printf '%s:2:\n' "$CLIENT_KEY_FPR" | gpg --homedir "$ROOT_GPG_HOME" --import-ownertrust >/dev/null

if [[ -f /etc/fwknop/access.conf ]]; then
  warn "/etc/fwknop/access.conf zaten var."
  read -rp "Overwrite edilsin mi? [y/N]: " OVERWRITE_ACCESS
  OVERWRITE_ACCESS="${OVERWRITE_ACCESS:-N}"
  [[ "$OVERWRITE_ACCESS" =~ ^[Yy]$ ]] || die "access.conf overwrite edilmedi."
fi

HMAC_KEY="$(cat "$HMAC_FILE")"

if [[ -n "$SERVER_GPG_PASS" ]]; then
  SERVER_GPG_PW_CFG="GPG_DECRYPT_PW              $SERVER_GPG_PASS"
else
  SERVER_GPG_PW_CFG="GPG_ALLOW_NO_PW             Y"
fi

info "/etc/fwknop/access.conf yazılıyor..."
cat >/etc/fwknop/access.conf <<EOF
SOURCE                      ANY
OPEN_PORTS                  tcp/$SSH_PORT
REQUIRE_SOURCE_ADDRESS      Y

GPG_HOME_DIR                /root/.gnupg
GPG_DECRYPT_ID              $SERVER_KEY_ID
$SERVER_GPG_PW_CFG
GPG_REQUIRE_SIG             Y
GPG_IGNORE_SIG_VERIFY_ERROR N
GPG_REMOTE_ID               $CLIENT_KEY_ID

HMAC_KEY_BASE64             $HMAC_KEY
HMAC_DIGEST_TYPE            sha512

CMD_CYCLE_OPEN              /usr/sbin/iptables -I INPUT -p tcp -s \$SRC --dport \$PORT -j ACCEPT
CMD_CYCLE_CLOSE             /usr/sbin/iptables -D INPUT -p tcp -s \$SRC --dport \$PORT -j ACCEPT
CMD_CYCLE_TIMER             60
EOF

info "fwknop-server başlatılıyor/restart ediliyor..."
systemctl enable --now fwknop-server
systemctl restart fwknop-server

info "iptables ortamı kontrol ediliyor..."
command -v iptables >/dev/null 2>&1 || die "iptables komutu bulunamadı."
command -v iptables-save >/dev/null 2>&1 || die "iptables-save komutu bulunamadı."
command -v netfilter-persistent >/dev/null 2>&1 || die "netfilter-persistent bulunamadı."

info "iptables backend:"
iptables --version || true

info "Mevcut INPUT kuralları:"
iptables -L INPUT -n -v --line-numbers

INPUT_POLICY="$(iptables -S INPUT | awk '/^-P INPUT/ {print $3}')"
if [[ "$INPUT_POLICY" != "DROP" ]]; then
  die "INPUT policy DROP değil: $INPUT_POLICY

Bu script sıfırdan iptables yönetimi yapmaz."
fi

if iptables -S INPUT | grep -Eq -- '(-m conntrack .*--ctstate (RELATED,ESTABLISHED|ESTABLISHED,RELATED)|-m state .*--state (RELATED,ESTABLISHED|ESTABLISHED,RELATED))'; then
  info "ESTABLISHED,RELATED kuralı mevcut."
else
  die "ESTABLISHED,RELATED ACCEPT kuralı bulunamadı."
fi

info "SPA UDP portu kontrol ediliyor..."
SPA_RULE_FOUND=""

if iptables -S INPUT | grep -Eq -- "^-A INPUT .* -p udp .*--dport ${SPA_PORT} .* -j ACCEPT|^-A INPUT .*--dport ${SPA_PORT} .* -p udp .* -j ACCEPT"; then
  SPA_RULE_FOUND="yes"
fi

if [[ -z "$SPA_RULE_FOUND" ]] && iptables -L INPUT -n | grep -Eq "udp dpt:${SPA_PORT}"; then
  SPA_RULE_FOUND="yes"
fi

if [[ -z "$SPA_RULE_FOUND" ]]; then
  die "SPA UDP portu ($SPA_PORT) için ACCEPT kuralı bulunamadı.

Önce bunu manuel ekle:
  sudo iptables -A INPUT -p udp --dport $SPA_PORT -j ACCEPT"
fi

info "SSH portunu açan özel ACCEPT kuralı aranıyor..."
SSH_RULE_LINES="$(iptables -L INPUT -n --line-numbers | awk -v port="dpt:$SSH_PORT" '
  $0 ~ /ACCEPT/ && $0 ~ /tcp/ && $0 ~ port {print $1}
')"

if [[ -z "$SSH_RULE_LINES" ]]; then
  die "SSH portunu açan tcp dpt:$SSH_PORT ACCEPT kuralı bulunamadı."
fi

echo
warn "Kaldırılacak SSH ACCEPT rule line numaraları:"
echo "$SSH_RULE_LINES"
echo

read -rp "Bu SSH ACCEPT kuralını/kuralarını kaldırmak istiyor musun? [y/N]: " CONFIRM
CONFIRM="${CONFIRM:-N}"

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  die "Kullanıcı iptal etti. SSH ACCEPT kuralı kaldırılmadı."
fi

for line in $(echo "$SSH_RULE_LINES" | sort -rn); do
  iptables -D INPUT "$line"
done

info "Güncel INPUT kuralları:"
iptables -L INPUT -n -v --line-numbers

info "Mevcut iptables kuralları kalıcılaştırılıyor..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

systemctl enable --now netfilter-persistent
netfilter-persistent save

cat <<EOF

========================================
SERVER FINALIZE OK
========================================

Profile:
  $PROFILE

SPA UDP port:
  $SPA_PORT

SSH protected port:
  $SSH_PORT

Client key ID:
  $CLIENT_KEY_ID

Server key ID:
  $SERVER_KEY_ID

Test:
  fwknop -n $PROFILE -vv
  ssh -p $SSH_PORT $SERVER_USER@SERVER

EOF
