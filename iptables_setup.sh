#!/usr/bin/env bash
set -euo pipefail

# ==========================
# Interactive iptables setup
# ==========================

if [[ $EUID -ne 0 ]]; then
  echo "Bu script root olarak çalışmalı."
  echo "Kullanım: sudo bash $0"
  exit 1
fi

ask_default_yes() {
  local prompt="$1"
  local answer

  while true; do
    read -rp "$prompt [Y/n]: " answer
    answer="${answer,,}"

    case "$answer" in
      ""|y|yes|e|evet) return 0 ;;
      n|no|h|hayir|hayır) return 1 ;;
      *) echo "Lütfen y veya n gir." ;;
    esac
  done
}

ask_default_no() {
  local prompt="$1"
  local answer

  while true; do
    read -rp "$prompt [y/N]: " answer
    answer="${answer,,}"

    case "$answer" in
      y|yes|e|evet) return 0 ;;
      ""|n|no|h|hayir|hayır) return 1 ;;
      *) echo "Lütfen y veya n gir." ;;
    esac
  done
}

allow_tcp_port() {
  local port="$1"
  local label="$2"

  echo "✓ TCP $port açılıyor ($label)"
  iptables -A INPUT \
    -p tcp \
    --dport "$port" \
    -m conntrack \
    --ctstate NEW \
    -j ACCEPT

  if [[ "${IPV6_ENABLED:-0}" -eq 1 ]]; then
    ip6tables -A INPUT \
      -p tcp \
      --dport "$port" \
      -m conntrack \
      --ctstate NEW \
      -j ACCEPT
  fi
}

allow_udp_port() {
  local port="$1"
  local label="$2"

  echo "✓ UDP $port açılıyor ($label)"
  iptables -A INPUT \
    -p udp \
    --dport "$port" \
    -m conntrack \
    --ctstate NEW \
    -j ACCEPT

  if [[ "${IPV6_ENABLED:-0}" -eq 1 ]]; then
    ip6tables -A INPUT \
      -p udp \
      --dport "$port" \
      -m conntrack \
      --ctstate NEW \
      -j ACCEPT
  fi
}

echo "========================================="
echo "   Interactive iptables setup"
echo "========================================="
echo
echo "Default profile:"
echo
echo "AÇIK:"
echo "  - SSH            (22)"
echo "  - HTTP           (80)"
echo "  - HTTPS          (443)"
echo "  - SMTP inbound   (25)"
echo "  - SMTP submit    (587)"
echo "  - IMAPS          (993)"
echo
echo "KAPALI:"
echo "  - SMTPS legacy   (465)"
echo "  - IMAP plain     (143)"
echo "  - POP3           (110)"
echo "  - POP3S          (995)"
echo "  - ICMP/Ping"
echo "  - IPv6 disable"
echo
echo "Mevcut INPUT kuralları temizlenecek."
echo

read -rp "Devam edilsin mi? [Y/n]: " confirm
confirm="${confirm,,}"

if [[ "$confirm" =~ ^(n|no|h|hayir|hayır)$ ]]; then
  echo "İptal edildi."
  exit 0
fi

echo
echo "UFW disable ediliyor..."
ufw disable || true

echo
if ask_default_no "IPv6 kapatılsın mı?"; then
  IPV6_ENABLED=0
  echo "IPv6 kapatılıyor..."

  cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

  sysctl --system >/dev/null
else
  IPV6_ENABLED=1
  echo "IPv6 aktif bırakıldı."
  command -v ip6tables >/dev/null 2>&1 || { echo "ip6tables komutu bulunamadı."; exit 1; }
  command -v ip6tables-save >/dev/null 2>&1 || { echo "ip6tables-save komutu bulunamadı."; exit 1; }
fi

echo
echo "iptables resetleniyor..."

iptables -F
iptables -X

iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

if [[ "$IPV6_ENABLED" -eq 1 ]]; then
  echo
  echo "ip6tables resetleniyor..."
  ip6tables -F
  ip6tables -X
  ip6tables -P INPUT ACCEPT
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT ACCEPT
fi

echo
echo "Base kurallar ekleniyor..."

# loopback
iptables -A INPUT -i lo -j ACCEPT
if [[ "$IPV6_ENABLED" -eq 1 ]]; then
  ip6tables -A INPUT -i lo -j ACCEPT
fi

# established
iptables -A INPUT \
  -m conntrack \
  --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
if [[ "$IPV6_ENABLED" -eq 1 ]]; then
  ip6tables -A INPUT \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT
fi

echo "✓ loopback access"
echo "✓ ESTABLISHED/RELATED"

echo
echo "=== ICMP ==="

if ask_default_no "Ping (ICMP) açık olsun mu?"; then
  iptables -A INPUT -p icmp -j ACCEPT
  if [[ "$IPV6_ENABLED" -eq 1 ]]; then
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
  fi
  echo "✓ ICMP açık"
else
  echo "✗ ICMP kapalı"
  if [[ "$IPV6_ENABLED" -eq 1 ]]; then
    echo "⚠ ICMPv6 kapalı bırakıldı (IPv6 iletişimini etkileyebilir)."
  fi
fi

echo
echo "=== SSH ==="

if ask_default_yes "SSH portu açılsın mı? (22)"; then
  allow_tcp_port 22 "SSH"
fi

echo
echo "=== WEB ==="

if ask_default_yes "HTTP/HTTPS açılsın mı? (80,443)"; then
  allow_tcp_port 80 "HTTP"
  allow_tcp_port 443 "HTTPS"
fi

echo
echo "=== MAIL SMTP ==="

if ask_default_yes "SMTP inbound açılsın mı? (25)"; then
  allow_tcp_port 25 "SMTP inbound"
fi

if ask_default_yes "SMTP submission açılsın mı? (587 STARTTLS)"; then
  allow_tcp_port 587 "SMTP submission"
fi

if ask_default_no "Legacy SMTPS açılsın mı? (465)"; then
  allow_tcp_port 465 "SMTPS legacy"
fi

echo
echo "=== MAIL IMAP ==="

if ask_default_yes "IMAPS açılsın mı? (993 SSL/TLS)"; then
  allow_tcp_port 993 "IMAPS"
fi

if ask_default_no "Plain IMAP açılsın mı? (143 STARTTLS)"; then
  allow_tcp_port 143 "IMAP STARTTLS"
fi

echo
echo "=== MAIL POP3 ==="

if ask_default_no "POP3 açılsın mı? (110)"; then
  allow_tcp_port 110 "POP3"
fi

if ask_default_no "POP3S açılsın mı? (995)"; then
  allow_tcp_port 995 "POP3S"
fi

echo
echo "=== FWKNOP ==="

if ask_default_no "fwknop UDP portu eklensin mi?"; then
  while true; do
    read -rp "fwknop UDP port: " FWKNOP_PORT
    if [[ "$FWKNOP_PORT" =~ ^[0-9]+$ ]] && (( FWKNOP_PORT >= 1 && FWKNOP_PORT <= 65535 )); then
      break
    fi
    echo "Geçerli bir port gir (1-65535)."
  done
  allow_udp_port "$FWKNOP_PORT" "fwknop"
fi

echo
echo "INPUT policy DROP yapılıyor..."
iptables -P INPUT DROP
if [[ "$IPV6_ENABLED" -eq 1 ]]; then
  ip6tables -P INPUT DROP
fi

echo
echo "Final rules:"
iptables -L INPUT -n -v --line-numbers
if [[ "$IPV6_ENABLED" -eq 1 ]]; then
  echo
  echo "Final IPv6 rules:"
  ip6tables -L INPUT -n -v --line-numbers
fi

echo
if ask_default_yes "Kurallar kalıcı kaydedilsin mi?"; then
  apt-get update -qq

  DEBIAN_FRONTEND=noninteractive \
  apt-get install -y \
  iptables-persistent \
  netfilter-persistent

  iptables-save > /etc/iptables/rules.v4
  if [[ "$IPV6_ENABLED" -eq 1 ]]; then
    ip6tables-save > /etc/iptables/rules.v6
  fi

  systemctl enable --now netfilter-persistent
  netfilter-persistent save

  echo
  echo "✓ Kalıcı kaydedildi"
  echo "✓ /etc/iptables/rules.v4"
  if [[ "$IPV6_ENABLED" -eq 1 ]]; then
    echo "✓ /etc/iptables/rules.v6"
  fi
else
  echo "Kalıcı kaydedilmedi."
fi

echo
echo "Tamamlandı."
