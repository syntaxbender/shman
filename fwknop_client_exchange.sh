#!/usr/bin/env bash
set -euo pipefail

info(){ echo -e "\n[INFO] $*"; }
warn(){ echo -e "\n[WARN] $*"; }
die(){ echo -e "\n[ERR] $*" >&2; exit 1; }

profile_exists_in_fwknoprc() {
  local profile="$1"
  [[ -f "$HOME/.fwknoprc" ]] || return 1
  grep -Fxq "[$profile]" "$HOME/.fwknoprc"
}

read -rp "Profile adı, örn mail-prod: " PROFILE
[[ -n "$PROFILE" ]] || die "Profile boş olamaz."

if profile_exists_in_fwknoprc "$PROFILE"; then
  die "~/.fwknoprc içinde bu profile zaten var: [$PROFILE]

Overwrite yapılmaz.
Mevcut bloğu manuel sil veya farklı profile adı kullan."
fi

read -rp "Server host/domain/IP: " SERVER_HOST
[[ -n "$SERVER_HOST" ]] || die "Server host boş olamaz."

read -rp "Server SSH user [ubuntu]: " SERVER_USER
SERVER_USER="${SERVER_USER:-ubuntu}"

read -rp "Server SSH port for scp [22]: " SERVER_SSH_PORT
SERVER_SSH_PORT="${SERVER_SSH_PORT:-22}"

read -rp "SPA UDP port for this server: " SPA_PORT
[[ "$SPA_PORT" =~ ^[0-9]+$ ]] || die "SPA port numerik olmalı."

read -rp "SSH access port to open via fwknop [22]: " SSH_ACCESS_PORT
SSH_ACCESS_PORT="${SSH_ACCESS_PORT:-22}"
[[ "$SSH_ACCESS_PORT" =~ ^[0-9]+$ ]] || die "SSH access port numerik olmalı."

read -rsp "Client GPG passphrase for this profile: " CLIENT_GPG_PASS
echo
[[ -n "$CLIENT_GPG_PASS" ]] || die "Passphrase boş olamaz."

CLIENT_GPG_NAME="client-${PROFILE}"
CLIENT_GPG_EMAIL="client-${PROFILE}@fwknop.local"

SERVER_PUB_REMOTE="/home/$SERVER_USER/fwknop-${PROFILE}-server-pub.asc"
HMAC_REMOTE="/home/$SERVER_USER/fwknop-${PROFILE}-hmac.key"
CLIENT_PUB_REMOTE="/home/$SERVER_USER/fwknop-${PROFILE}-client-pub.asc"

info "Türetilen değerler:"
echo "  Client GPG UID: $CLIENT_GPG_NAME <$CLIENT_GPG_EMAIL>"
echo "  Server public key remote: $SERVER_PUB_REMOTE"
echo "  HMAC remote: $HMAC_REMOTE"
echo "  Client public key remote output: $CLIENT_PUB_REMOTE"

if gpg --list-secret-keys "$CLIENT_GPG_EMAIL" >/dev/null 2>&1; then
  die "Bu profile için client secret key zaten var: $CLIENT_GPG_EMAIL"
fi

LOCAL_TMP="$(mktemp -d)"
trap 'rm -rf "$LOCAL_TMP"' EXIT

info "Client paketleri kuruluyor..."
sudo apt update
sudo apt install -y fwknop-client gnupg openssh-client

info "Server public key ve profile bazlı HMAC key client'a çekiliyor..."
scp -P "$SERVER_SSH_PORT" "$SERVER_USER@$SERVER_HOST:$SERVER_PUB_REMOTE" "$LOCAL_TMP/server-pub.asc"
scp -P "$SERVER_SSH_PORT" "$SERVER_USER@$SERVER_HOST:$HMAC_REMOTE" "$LOCAL_TMP/hmac.key"
chmod 600 "$LOCAL_TMP/hmac.key"

info "Client GPG key oluşturuluyor. Expire yok."
gpg --batch --pinentry-mode loopback --passphrase "$CLIENT_GPG_PASS" \
  --quick-generate-key "$CLIENT_GPG_NAME <$CLIENT_GPG_EMAIL>" rsa2048 sign 0

CLIENT_KEY_ID="$(gpg --list-secret-keys --with-colons "$CLIENT_GPG_EMAIL" | awk -F: '/^sec:/ {print $5; exit}')"
[[ -n "$CLIENT_KEY_ID" ]] || die "Client GPG key ID bulunamadı."

info "Client public key export ediliyor..."
gpg --armor --export "$CLIENT_KEY_ID" > "$LOCAL_TMP/client-pub.asc"

info "Server public key import ediliyor..."
gpg --import "$LOCAL_TMP/server-pub.asc"

SERVER_KEY_ID="$(gpg --show-keys --with-colons "$LOCAL_TMP/server-pub.asc" | awk -F: '/^pub:/ {print $5; exit}')"
[[ -n "$SERVER_KEY_ID" ]] || die "Server public key ID bulunamadı."

info "Client public key server'a gönderiliyor..."
scp -P "$SERVER_SSH_PORT" "$LOCAL_TMP/client-pub.asc" "$SERVER_USER@$SERVER_HOST:$CLIENT_PUB_REMOTE"

HMAC_KEY="$(cat "$LOCAL_TMP/hmac.key")"

info "~/.fwknoprc içine yeni profile append ediliyor..."
cat >> "$HOME/.fwknoprc" <<EOF

[$PROFILE]
ACCESS                      tcp/$SSH_ACCESS_PORT
SPA_SERVER                  $SERVER_HOST
SPA_SERVER_PROTO            udp
SPA_SERVER_PORT             $SPA_PORT
ALLOW_IP                    resolve

USE_GPG                     Y
GPG_RECIPIENT               $SERVER_KEY_ID
GPG_SIGNER                  $CLIENT_KEY_ID
GPG_SIGNING_PW              $CLIENT_GPG_PASS

USE_HMAC                    Y
HMAC_KEY_BASE64             $HMAC_KEY
HMAC_DIGEST_TYPE            sha512
EOF

chmod 600 "$HOME/.fwknoprc"

cat <<EOF

========================================
CLIENT EXCHANGE OK
========================================

Profile:
  $PROFILE

SPA UDP port:
  $SPA_PORT

SSH access port:
  $SSH_ACCESS_PORT

Client key ID:
  $CLIENT_KEY_ID

Server key ID:
  $SERVER_KEY_ID

Client public key server'a gönderildi:
  $CLIENT_PUB_REMOTE

Sonraki adım server tarafında:
  sudo ./server-finalize.sh

Finalize sırasında aynı profile adını ve SPA portunu gir.

Test:
  fwknop -n $PROFILE -vv
  ssh -p $SSH_ACCESS_PORT $SERVER_USER@$SERVER_HOST

EOF
