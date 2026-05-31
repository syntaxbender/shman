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

remove_profile_from_fwknoprc() {
  local profile="$1"
  local fwknoprc="$HOME/.fwknoprc"
  local tmp_file
  [[ -f "$fwknoprc" ]] || return 0

  tmp_file="$(mktemp)"
  awk -v section="[$profile]" '
    $0 == section {skip=1; next}
    /^\[/ {skip=0}
    !skip {print}
  ' "$fwknoprc" > "$tmp_file"
  mv "$tmp_file" "$fwknoprc"
}

read -rp "Profile adı, örn mail-prod: " PROFILE
[[ -n "$PROFILE" ]] || die "Profile boş olamaz."

read -rp "Server host/domain/IP: " SERVER_HOST
[[ -n "$SERVER_HOST" ]] || die "Server host boş olamaz."

read -rp "Server SSH user [ubuntu]: " SERVER_USER
SERVER_USER="${SERVER_USER:-ubuntu}"

read -rp "Server SSH port for scp [22]: " SERVER_SSH_PORT
SERVER_SSH_PORT="${SERVER_SSH_PORT:-22}"

read -rp "SSH private key path (boşsa default ssh config): " SSH_KEY_FILE

read -rp "SPA UDP port for this server: " SPA_PORT
[[ "$SPA_PORT" =~ ^[0-9]+$ ]] || die "SPA port numerik olmalı."

read -rp "SSH access port to open via fwknop [22]: " SSH_ACCESS_PORT
SSH_ACCESS_PORT="${SSH_ACCESS_PORT:-22}"
[[ "$SSH_ACCESS_PORT" =~ ^[0-9]+$ ]] || die "SSH access port numerik olmalı."

read -rsp "Client GPG passphrase for this profile (boş olabilir): " CLIENT_GPG_PASS
echo

CLIENT_GPG_NAME="client-${PROFILE}"
CLIENT_GPG_EMAIL="client-${PROFILE}@fwknop.local"

SERVER_PUB_BASENAME="fwknop-${PROFILE}-server-pub.asc"
HMAC_BASENAME="fwknop-${PROFILE}-hmac.key"
CLIENT_PUB_BASENAME="fwknop-${PROFILE}-client-pub.asc"

PROFILE_EXISTS=""
EXISTING_CLIENT_KEY_FPR="$(gpg --with-colons --list-secret-keys "$CLIENT_GPG_EMAIL" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}' || true)"
CLIENT_KEY_EXISTS=""

profile_exists_in_fwknoprc "$PROFILE" && PROFILE_EXISTS="yes"
[[ -n "$EXISTING_CLIENT_KEY_FPR" ]] && CLIENT_KEY_EXISTS="yes"

if [[ -n "$PROFILE_EXISTS" || -n "$CLIENT_KEY_EXISTS" ]]; then
  warn "Bu profile ait mevcut kayıtlar bulundu."
  [[ -n "$PROFILE_EXISTS" ]] && echo "  - ~/.fwknoprc içinde profile bloğu: [$PROFILE]"
  [[ -n "$CLIENT_KEY_EXISTS" ]] && echo "  - Client secret key: $CLIENT_GPG_EMAIL"
  echo
  read -rp "Overwrite edilsin mi? [y/N]: " OVERWRITE_EXCHANGE
  OVERWRITE_EXCHANGE="${OVERWRITE_EXCHANGE:-N}"
  [[ "$OVERWRITE_EXCHANGE" =~ ^[Yy]$ ]] || die "Kullanıcı iptal etti. Overwrite yapılmadı."

  [[ -n "$PROFILE_EXISTS" ]] && remove_profile_from_fwknoprc "$PROFILE"
  if [[ -n "$CLIENT_KEY_EXISTS" ]]; then
    gpg --batch --yes --delete-secret-and-public-key "$EXISTING_CLIENT_KEY_FPR"
  fi
fi

LOCAL_TMP="$(mktemp -d)"
trap 'rm -rf "$LOCAL_TMP"' EXIT

info "Client paketleri kuruluyor..."
sudo apt update
sudo apt install -y fwknop-client gnupg openssh-client

SSH_OPTS=(-p "$SERVER_SSH_PORT")
SCP_OPTS=(-P "$SERVER_SSH_PORT")
if [[ -n "$SSH_KEY_FILE" ]]; then
  [[ -f "$SSH_KEY_FILE" ]] || die "SSH private key bulunamadı: $SSH_KEY_FILE"
  SSH_OPTS+=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes)
  SCP_OPTS+=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes)
fi

info "Server kullanıcısının home dizini uzaktan okunuyor..."
REMOTE_HOME="$(ssh "${SSH_OPTS[@]}" "$SERVER_USER@$SERVER_HOST" 'printf %s "$HOME"')"
[[ -n "$REMOTE_HOME" ]] || die "Remote home dizini okunamadı: $SERVER_USER@$SERVER_HOST"

SERVER_PUB_REMOTE="$REMOTE_HOME/$SERVER_PUB_BASENAME"
HMAC_REMOTE="$REMOTE_HOME/$HMAC_BASENAME"
CLIENT_PUB_REMOTE="$REMOTE_HOME/$CLIENT_PUB_BASENAME"

info "Türetilen değerler:"
echo "  Client GPG UID: $CLIENT_GPG_NAME <$CLIENT_GPG_EMAIL>"
echo "  Server public key remote: $SERVER_PUB_REMOTE"
echo "  HMAC remote: $HMAC_REMOTE"
echo "  Client public key remote output: $CLIENT_PUB_REMOTE"

info "Server public key ve profile bazlı HMAC key client'a çekiliyor..."
scp "${SCP_OPTS[@]}" "$SERVER_USER@$SERVER_HOST:$SERVER_PUB_REMOTE" "$LOCAL_TMP/server-pub.asc"
scp "${SCP_OPTS[@]}" "$SERVER_USER@$SERVER_HOST:$HMAC_REMOTE" "$LOCAL_TMP/hmac.key"
chmod 600 "$LOCAL_TMP/hmac.key"

info "Client GPG key oluşturuluyor (RSA/RSA 2048, 1y)."
CLIENT_KEY_SPEC_FILE="$(mktemp)"
cat > "$CLIENT_KEY_SPEC_FILE" <<EOF
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: $CLIENT_GPG_NAME
Name-Email: $CLIENT_GPG_EMAIL
Expire-Date: 1y
EOF
if [[ -z "$CLIENT_GPG_PASS" ]]; then
  echo "%no-protection" >> "$CLIENT_KEY_SPEC_FILE"
fi
echo "%commit" >> "$CLIENT_KEY_SPEC_FILE"

if [[ -n "$CLIENT_GPG_PASS" ]]; then
  gpg --batch --pinentry-mode loopback --passphrase "$CLIENT_GPG_PASS" \
    --generate-key "$CLIENT_KEY_SPEC_FILE"
else
  gpg --batch --pinentry-mode loopback \
    --generate-key "$CLIENT_KEY_SPEC_FILE"
fi
rm -f "$CLIENT_KEY_SPEC_FILE"

CLIENT_KEY_ID="$(gpg --list-secret-keys --with-colons "$CLIENT_GPG_EMAIL" | awk -F: '/^sec:/ {print $5; exit}')"
[[ -n "$CLIENT_KEY_ID" ]] || die "Client GPG key ID bulunamadı."

info "Client public key export ediliyor..."
gpg --armor --export "$CLIENT_KEY_ID" > "$LOCAL_TMP/client-pub.asc"

info "Server public key import ediliyor..."
gpg --import "$LOCAL_TMP/server-pub.asc"

SERVER_KEY_ID="$(gpg --show-keys --with-colons "$LOCAL_TMP/server-pub.asc" | awk -F: '/^pub:/ {print $5; exit}')"
[[ -n "$SERVER_KEY_ID" ]] || die "Server public key ID bulunamadı."

SERVER_KEY_FPR="$(gpg --with-colons --list-keys "$SERVER_KEY_ID" | awk -F: '/^fpr:/ {print $10; exit}')"
[[ -n "$SERVER_KEY_FPR" ]] || die "Server public key fingerprint bulunamadı."

info "Server public key client private key ile imzalanıyor..."
gpg --batch --yes --pinentry-mode loopback --passphrase "$CLIENT_GPG_PASS" \
  --local-user "$CLIENT_KEY_ID" --quick-sign-key "$SERVER_KEY_FPR"

info "Server public key ownertrust seviyesi ayarlanıyor (2 = I do NOT trust)..."
printf '%s:2:\n' "$SERVER_KEY_FPR" | gpg --import-ownertrust >/dev/null

info "Client public key server'a gönderiliyor..."
scp "${SCP_OPTS[@]}" "$LOCAL_TMP/client-pub.asc" "$SERVER_USER@$SERVER_HOST:$CLIENT_PUB_REMOTE"

HMAC_KEY="$(tr -d '\r\n' < "$LOCAL_TMP/hmac.key")"
[[ -n "$HMAC_KEY" ]] || die "HMAC key okunamadı."

if [[ -n "$CLIENT_GPG_PASS" ]]; then
  CLIENT_GPG_PW_CFG="GPG_SIGNING_PW              $CLIENT_GPG_PASS"
else
  CLIENT_GPG_PW_CFG=""
fi

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
$CLIENT_GPG_PW_CFG

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
  sudo ./fwknop_server_finalize.sh

Finalize sırasında aynı profile adını ve SPA portunu gir.

Test:
  fwknop -n $PROFILE -vv
  ssh -p $SSH_ACCESS_PORT $SERVER_USER@$SERVER_HOST

EOF
