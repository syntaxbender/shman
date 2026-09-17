#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/config.sh
source "$REPO_ROOT/lib/config.sh"

upsert_conf_line() {
  local conf_file="$1"
  local key="$2"
  local line="$3"

  upsert_config_line "$conf_file" "^[[:space:]]*${key}[[:space:]]+" "$line"
}

rule_matches_ssh_port() {
  local rule="$1"
  local port="$2"
  local dports token start end
  local -a _ports=()

  if [[ "$rule" =~ [[:space:]]--dport[[:space:]]${port}([[:space:]]|$) ]]; then
    return 0
  fi

  if [[ "$rule" =~ [[:space:]]--dports[[:space:]] ]]; then
    dports="${rule#* --dports }"
    dports="${dports%% *}"
    IFS=',' read -r -a _ports <<< "$dports"
    for token in "${_ports[@]}"; do
      if [[ "$token" == "$port" ]]; then
        return 0
      fi
      if [[ "$token" == *:* ]]; then
        start="${token%%:*}"
        end="${token##*:}"
        if [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] && (( port >= start && port <= end )); then
          return 0
        fi
      fi
    done
  fi

  return 1
}

PROFILE=""
SERVER_USER=""
SSH_PORT=""
PCAP_INTF=""
SPA_PORT=""
SERVER_GPG_PASS=""
ROOT_GPG_HOME="/root/.gnupg"
SERVER_HOME=""
CLIENT_PUB=""
HMAC_FILE=""
SERVER_GPG_EMAIL=""
SERVER_KEY_ID=""
CLIENT_KEY_ID=""
CLIENT_KEY_FPR=""
CLIENT_FPR_CSV=""
SERVER_GPG_PW_CFG=""
HMAC_KEY=""
FWKNOPD_CONF="/etc/fwknop/fwknopd.conf"
INPUT_POLICY=""
SPA_RULE_FOUND=""
SSH_RULE_SPECS=()

collect_inputs() {
  read -rp "Profile adı, örn mail-prod: " PROFILE
  [[ -n "$PROFILE" ]] || die "Profile boş olamaz."

  read -rp "Server SSH kullanıcısı [${SUDO_USER:-ubuntu}]: " SERVER_USER
  SERVER_USER="${SERVER_USER:-${SUDO_USER:-ubuntu}}"

  read -rp "Açılıp kapatılacak olan SSH portu [22]: " SSH_PORT
  SSH_PORT="${SSH_PORT:-22}"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port numerik olmalı."

  read -rp "Network interface for fwknopd.conf [ens0]: " PCAP_INTF
  PCAP_INTF="${PCAP_INTF:-ens0}"

  read -rp "fwknop UDP port [62201]: " SPA_PORT
  SPA_PORT="${SPA_PORT:-62201}"
  [[ "$SPA_PORT" =~ ^[0-9]+$ ]] || die "SPA port numerik olmalı."

  read -rsp "Server GPG passphrase (boş olabilir): " SERVER_GPG_PASS
  echo
}

derive_paths() {
  SERVER_HOME="$(eval echo "~$SERVER_USER")"
  CLIENT_PUB="$SERVER_HOME/fwknop-${PROFILE}-client-pub.asc"
  HMAC_FILE="$SERVER_HOME/fwknop-${PROFILE}-hmac.key"
  SERVER_GPG_EMAIL="server-${PROFILE}@fwknop.local"
}

print_derived_values() {
  info "Türetilen değerler:"
  echo "  Client public key: $CLIENT_PUB"
  echo "  HMAC key: $HMAC_FILE"
  echo "  Server GPG UID: $SERVER_GPG_EMAIL"
  echo "  fwknopd interface: $PCAP_INTF"
  echo "  fwknop UDP port: $SPA_PORT"
}

validate_exchange_files() {
  [[ -f "$CLIENT_PUB" ]] || die "Client public key bulunamadı: $CLIENT_PUB"
  [[ -f "$HMAC_FILE" ]] || die "HMAC key bulunamadı: $HMAC_FILE"
}

prepare_root_gpg_home() {
  mkdir -p "$ROOT_GPG_HOME"
  chmod 700 "$ROOT_GPG_HOME"
}

load_server_private_key() {
  info "Root GPG keyring içinde server private key aranıyor..."
  SERVER_KEY_ID="$(
    gpg --homedir "$ROOT_GPG_HOME" --list-secret-keys --with-colons "$SERVER_GPG_EMAIL" |
      awk -F: '/^sec:/ {print $5; exit}'
  )"
  [[ -n "$SERVER_KEY_ID" ]] || die "Root keyring içinde server secret key bulunamadı: $SERVER_GPG_EMAIL

Önce fwknop_server_prepare.sh adımını çalıştır veya key'i root keyring'e import et."
}

load_client_public_key_id() {
  info "Client public key ID okunuyor..."
  CLIENT_KEY_ID="$(
    gpg --homedir "$ROOT_GPG_HOME" --show-keys --with-colons "$CLIENT_PUB" |
      awk -F: '/^pub:/ {print $5; exit}'
  )"
  [[ -n "$CLIENT_KEY_ID" ]] || die "Client public key ID bulunamadı."
}

remove_existing_client_key() {
  local overwrite_client_key
  local existing_client_key_fpr

  if ! gpg --homedir "$ROOT_GPG_HOME" --list-keys "$CLIENT_KEY_ID" >/dev/null 2>&1; then
    return 0
  fi

  warn "Root GPG keyring içinde bu client public key zaten var: $CLIENT_KEY_ID"
  read -rp "Overwrite edilsin mi? [y/N]: " overwrite_client_key
  overwrite_client_key="${overwrite_client_key:-N}"
  [[ "$overwrite_client_key" =~ ^[Yy]$ ]] || die "Kullanıcı iptal etti. Client key overwrite edilmedi."

  existing_client_key_fpr="$(
    gpg --homedir "$ROOT_GPG_HOME" --with-colons --list-keys "$CLIENT_KEY_ID" |
      awk -F: '/^fpr:/ {print $10; exit}'
  )"
  [[ -n "$existing_client_key_fpr" ]] || die "Mevcut client key fingerprint bulunamadı."
  gpg --homedir "$ROOT_GPG_HOME" --batch --yes --delete-secret-and-public-key "$existing_client_key_fpr"
}

import_and_sign_client_key() {
  info "Client public key root GPG home'a import ediliyor..."
  gpg --homedir "$ROOT_GPG_HOME" --import "$CLIENT_PUB"

  CLIENT_KEY_FPR="$(
    gpg --homedir "$ROOT_GPG_HOME" --with-colons --list-keys "$CLIENT_KEY_ID" |
      awk -F: '/^fpr:/ {print $10; exit}'
  )"
  [[ -n "$CLIENT_KEY_FPR" ]] || die "Client public key fingerprint bulunamadı."

  CLIENT_FPR_CSV="$(
    gpg --homedir "$ROOT_GPG_HOME" --show-keys --with-colons "$CLIENT_PUB" |
      awk -F: '/^fpr:/ {print $10}' |
      awk '!seen[$0]++' |
      paste -sd, -
  )"
  [[ -n "$CLIENT_FPR_CSV" ]] || die "Client public key fingerprint listesi üretilemedi."

  info "Client public key server private key ile imzalanıyor..."
  gpg --homedir "$ROOT_GPG_HOME" --batch --yes --pinentry-mode loopback \
    --passphrase "$SERVER_GPG_PASS" --local-user "$SERVER_KEY_ID" \
    --quick-sign-key "$CLIENT_KEY_FPR"

  info "Client public key ownertrust seviyesi ayarlanıyor (2 = I do NOT trust)..."
  printf '%s:2:\n' "$CLIENT_KEY_FPR" |
    gpg --homedir "$ROOT_GPG_HOME" --import-ownertrust >/dev/null
}

confirm_access_config_overwrite() {
  local overwrite_access

  if [[ ! -f /etc/fwknop/access.conf ]]; then
    return 0
  fi

  warn "/etc/fwknop/access.conf zaten var."
  read -rp "Overwrite edilsin mi? [y/N]: " overwrite_access
  overwrite_access="${overwrite_access:-N}"
  [[ "$overwrite_access" =~ ^[Yy]$ ]] || die "access.conf overwrite edilmedi."
}

load_access_secrets() {
  HMAC_KEY="$(tr -d '\r\n' <"$HMAC_FILE")"
  [[ -n "$HMAC_KEY" ]] || die "HMAC key okunamadı."

  if [[ -n "$SERVER_GPG_PASS" ]]; then
    SERVER_GPG_PW_CFG="GPG_DECRYPT_PW              $SERVER_GPG_PASS"
  else
    SERVER_GPG_PW_CFG="GPG_ALLOW_NO_PW             Y"
  fi
}

write_access_config() {
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
GPG_FINGERPRINT_ID          $CLIENT_FPR_CSV

HMAC_KEY_BASE64             $HMAC_KEY
HMAC_DIGEST_TYPE            sha512

CMD_CYCLE_OPEN              /usr/sbin/iptables -I INPUT -p tcp -s \$SRC --dport \$PORT -j ACCEPT
CMD_CYCLE_CLOSE             /usr/sbin/iptables -D INPUT -p tcp -s \$SRC --dport \$PORT -j ACCEPT
CMD_CYCLE_TIMER             60
EOF
}

update_fwknopd_config() {
  info "/etc/fwknop/fwknopd.conf append/upsert modunda güncelleniyor (overwrite yok)..."
  touch "$FWKNOPD_CONF"
  upsert_conf_line "$FWKNOPD_CONF" "PCAP_INTF" "PCAP_INTF                   $PCAP_INTF;"
  upsert_conf_line "$FWKNOPD_CONF" "PCAP_FILTER" "PCAP_FILTER                 udp port $SPA_PORT;"
  upsert_conf_line "$FWKNOPD_CONF" "UDPSERV_PORT" "UDPSERV_PORT                $SPA_PORT;"
  upsert_conf_line "$FWKNOPD_CONF" "ENABLE_SPA_PACKET_AGING" "ENABLE_SPA_PACKET_AGING      Y;"
  upsert_conf_line "$FWKNOPD_CONF" "MAX_SPA_PACKET_AGE" "MAX_SPA_PACKET_AGE           60;"
}

restart_fwknop_server() {
  info "fwknop-server başlatılıyor/restart ediliyor..."
  systemctl enable --now fwknop-server
  systemctl restart fwknop-server
}

require_firewall_dependencies() {
  info "iptables ortamı kontrol ediliyor..."
  require_commands iptables iptables-save netfilter-persistent
}

verify_firewall_baseline() {
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
}

collect_ssh_rules() {
  local rule

  info "INPUT zincirinde SSH portunu açan tüm tcp kurallar aranıyor..."
  SSH_RULE_SPECS=()
  while IFS= read -r rule; do
    [[ "$rule" == "-A INPUT "* ]] || continue
    [[ "$rule" =~ [[:space:]]-p[[:space:]]tcp([[:space:]]|$) ]] || continue
    if rule_matches_ssh_port "$rule" "$SSH_PORT"; then
      SSH_RULE_SPECS+=("${rule#-A INPUT }")
    fi
  done < <(iptables -S INPUT)
}

remove_ssh_rules() {
  local confirm
  local rule_spec
  local -a rule_parts=()

  if [[ ${#SSH_RULE_SPECS[@]} -eq 0 ]]; then
    warn "INPUT içinde port $SSH_PORT için tcp kuralı bulunamadı."
    info "Devam ediliyor..."
    return 0
  fi

  echo
  warn "Kaldırılacak INPUT tcp/$SSH_PORT kural(lar)ı:"
  for rule_spec in "${SSH_RULE_SPECS[@]}"; do
    echo "  - $rule_spec"
  done
  echo

  read -rp "Bu SSH kural(lar)ını kaldırmak istiyor musun? [y/N]: " confirm
  confirm="${confirm:-N}"
  [[ "$confirm" =~ ^[Yy]$ ]] || die "Kullanıcı iptal etti. SSH kuralları kaldırılmadı."

  for rule_spec in "${SSH_RULE_SPECS[@]}"; do
    read -r -a rule_parts <<<"$rule_spec"
    iptables -D INPUT "${rule_parts[@]}"
  done
}

persist_firewall_rules() {
  info "Güncel INPUT kuralları:"
  iptables -L INPUT -n -v --line-numbers

  info "Mevcut iptables kuralları kalıcılaştırılıyor..."
  mkdir -p /etc/iptables
  iptables-save >/etc/iptables/rules.v4
  ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true

  systemctl enable --now netfilter-persistent
  netfilter-persistent save
}

print_completion_summary() {
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
}

main() {
  require_root
  collect_inputs
  derive_paths
  print_derived_values
  validate_exchange_files
  prepare_root_gpg_home
  load_server_private_key
  load_client_public_key_id
  remove_existing_client_key
  import_and_sign_client_key
  confirm_access_config_overwrite
  load_access_secrets
  write_access_config
  update_fwknopd_config
  restart_fwknop_server
  require_firewall_dependencies
  verify_firewall_baseline
  collect_ssh_rules
  remove_ssh_rules
  persist_firewall_rules
  print_completion_summary
}

main "$@"
