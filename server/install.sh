#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

export DEBIAN_FRONTEND=noninteractive

INSTALL_BASE=0
INSTALL_POSTGRES=0
INSTALL_MYSQL=0
INSTALL_NGINX=0
INSTALL_APACHE=0
INSTALL_CERTBOT=0
INSTALL_PODMAN=0
INSTALL_PHP=0
INSTALL_NODE=0
INSTALL_FORGEJO=0
INSTALL_FIREWALL=0
INSTALL_FWKNOP=0
INSTALL_ZRAM=0
INSTALL_ZSH=0
INSTALL_SSH=0

MYSQL_ROOT_PASSWORD=""
MYSQL_ROOT_PASSWORD_AGAIN=""
FIREWALL_PACKAGES_READY=0

log() {
  local message="$1"
  local type="${2:-info}"
  local timestamp
  local color
  local endcolor="\033[0m"

  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$type" in
    info) color="\033[38;5;79m" ;;
    success) color="\033[1;32m" ;;
    error) color="\033[1;31m" ;;
    *) color="\033[1;34m" ;;
  esac

  echo -e "${color}${timestamp} - ${message}${endcolor}"
}

usage() {
  cat <<EOF
Kullanım: sudo $0 SEÇENEK...

  --base             Temel sunucu araçları
  --node             Node.js 20.x
  --postgresql       PostgreSQL 17
  --mysql            MySQL Server
  --php              PHP ve PHP-FPM
  --podman           Podman ve rootless bağımlılıkları
  --nginx            Nginx
  --apache           Apache
  --certbot          Certbot ve Nginx/Apache eklentileri
  --forgejo          Forgejo binary, kullanıcı ve dizinleri
  --firewall         iptables kalıcılık paketleri
  --fwknop           FWKnop server ve firewall bağımlılıkları
  --zram             ZRAM generator ve kernel modülü
  --zsh              ZSH ortamı paketleri
  --ssh              OpenSSH server
  --all              Tüm kurulumlar
EOF
}

select_all() {
  INSTALL_BASE=1
  INSTALL_POSTGRES=1
  INSTALL_MYSQL=1
  INSTALL_NGINX=1
  INSTALL_APACHE=1
  INSTALL_CERTBOT=1
  INSTALL_PODMAN=1
  INSTALL_PHP=1
  INSTALL_NODE=1
  INSTALL_FORGEJO=1
  INSTALL_FIREWALL=1
  INSTALL_FWKNOP=1
  INSTALL_ZRAM=1
  INSTALL_ZSH=1
  INSTALL_SSH=1
}

parse_arguments() {
  [[ $# -gt 0 ]] || {
    usage >&2
    exit 1
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -dep|--dependencies|--base) INSTALL_BASE=1 ;;
      -psql|--postgresql) INSTALL_POSTGRES=1 ;;
      --mysql) INSTALL_MYSQL=1 ;;
      --nginx) INSTALL_NGINX=1 ;;
      --apache) INSTALL_APACHE=1 ;;
      --certbot) INSTALL_CERTBOT=1 ;;
      --podman) INSTALL_PODMAN=1 ;;
      --php) INSTALL_PHP=1 ;;
      --node) INSTALL_NODE=1 ;;
      --forgejo) INSTALL_FORGEJO=1 ;;
      --firewall) INSTALL_FIREWALL=1 ;;
      --fwknop) INSTALL_FWKNOP=1 ;;
      --zram) INSTALL_ZRAM=1 ;;
      --zsh) INSTALL_ZSH=1 ;;
      --ssh) INSTALL_SSH=1 ;;
      --all) select_all ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) die "Bilinmeyen seçenek: $1" ;;
    esac
    shift
  done
}

apt_update() {
  apt-get update
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

run_needrestart() {
  needrestart -r a
}

collect_mysql_password() {
  [[ "$INSTALL_MYSQL" -eq 1 ]] || return 0

  require_command debconf-set-selections
  log "MySQL root parolası hazırlanıyor."

  read -rsp "MySQL root şifresini girin: " MYSQL_ROOT_PASSWORD
  echo
  read -rsp "MySQL root şifresini tekrar girin: " MYSQL_ROOT_PASSWORD_AGAIN
  echo

  [[ "$MYSQL_ROOT_PASSWORD" == "$MYSQL_ROOT_PASSWORD_AGAIN" ]] ||
    die "MySQL şifreleri uyuşmuyor."

  printf '%s\n' "mysql-server mysql-server/root_password password $MYSQL_ROOT_PASSWORD" |
    debconf-set-selections
  printf '%s\n' "mysql-server mysql-server/root_password_again password $MYSQL_ROOT_PASSWORD" |
    debconf-set-selections
}

install_base() {
  [[ "$INSTALL_BASE" -eq 1 ]] || return 0

  log "Temel sunucu araçları kuruluyor."
  apt-get upgrade -y
  apt_install \
    curl wget gnupg gnupg2 net-tools dnsutils debconf-utils build-essential \
    git nano vim git-lfs lsb-release ca-certificates software-properties-common \
    openssl uuid-runtime iproute2 iputils-ping netcat-openbsd lsof htop unzip \
    needrestart traceroute tcpdump jq tree zip tar rsync gettext-base \
    unattended-upgrades
  run_needrestart
  log "Temel sunucu araçları kuruldu." "success"
}

install_node() {
  local setup_script

  [[ "$INSTALL_NODE" -eq 1 ]] || return 0

  log "Node.js 20.x kuruluyor."
  apt_install wget ca-certificates gnupg gettext-base
  require_commands wget mktemp chmod bash rm
  setup_script="$(mktemp /tmp/nodesource.XXXXXX.sh)"
  wget -q https://deb.nodesource.com/setup_20.x -O "$setup_script"
  chmod 0700 "$setup_script"
  bash "$setup_script"
  rm -f -- "$setup_script"
  apt_update
  apt_install nodejs
  run_needrestart
  log "Node.js 20.x kuruldu." "success"
}

install_postgresql() {
  [[ "$INSTALL_POSTGRES" -eq 1 ]] || return 0

  log "PostgreSQL 17 kuruluyor."
  apt_install curl ca-certificates
  require_commands curl install
  install -d /usr/share/postgresql-common/pgdg
  curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
  # shellcheck source=/etc/os-release
  source /etc/os-release
  printf '%s\n' \
    "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" \
    >/etc/apt/sources.list.d/pgdg.list
  apt_update
  apt_install postgresql-contrib-17 postgresql-17
  run_needrestart
  log "PostgreSQL 17 kuruldu." "success"
}

install_mysql() {
  local mysql_version
  local package_file

  [[ "$INSTALL_MYSQL" -eq 1 ]] || return 0

  log "MySQL kuruluyor."
  apt_install curl wget ca-certificates gnupg
  require_commands curl sed sort tail wget dpkg mktemp rm
  mysql_version="$(
    curl -fsSL https://dev.mysql.com/downloads/repo/apt/ |
      sed -n 's/.*mysql-apt-config_\([0-9][0-9.-]*\)_all\.deb.*/\1/p' |
      sort -Vu |
      tail -n 1
  )"
  [[ -n "$mysql_version" ]] || die "MySQL APT paket sürümü belirlenemedi."

  package_file="$(mktemp /tmp/mysql-apt-config.XXXXXX.deb)"
  wget -O "$package_file" \
    "https://dev.mysql.com/get/mysql-apt-config_${mysql_version}_all.deb"
  dpkg -i "$package_file"
  rm -f -- "$package_file"
  apt_update
  apt_install mysql-server
  run_needrestart
  log "MySQL kuruldu." "success"
}

install_php() {
  [[ "$INSTALL_PHP" -eq 1 ]] || return 0

  log "PHP kuruluyor."
  apt_install curl php php-mysql php-curl php-mbstring php-fpm
  run_needrestart
  log "PHP kuruldu." "success"
}

install_podman() {
  [[ "$INSTALL_PODMAN" -eq 1 ]] || return 0

  log "Podman kuruluyor."
  apt_install podman uidmap slirp4netns fuse-overlayfs apparmor apparmor-utils

  if apt-cache show passt >/dev/null 2>&1; then
    apt_install passt
  else
    log "passt paketi depoda bulunamadı; atlanıyor."
  fi

  run_needrestart
  log "Podman kuruldu." "success"
}

install_nginx() {
  [[ "$INSTALL_NGINX" -eq 1 ]] || return 0

  log "Nginx kuruluyor."
  apt_install nginx gettext-base curl wget openssl
  run_needrestart
  log "Nginx kuruldu; site yapılandırması değiştirilmedi." "success"
}

install_apache() {
  [[ "$INSTALL_APACHE" -eq 1 ]] || return 0

  log "Apache kuruluyor."
  apt_install apache2
  run_needrestart
  log "Apache kuruldu." "success"
}

install_certbot() {
  [[ "$INSTALL_CERTBOT" -eq 1 ]] || return 0

  log "Certbot ve web server eklentileri kuruluyor."
  apt_install certbot python3-certbot-nginx python3-certbot-apache
  run_needrestart
  log "Certbot kuruldu." "success"
}

install_forgejo() {
  local forgejo_version

  [[ "$INSTALL_FORGEJO" -eq 1 ]] || return 0

  log "Forgejo binary ve sistem kullanıcısı kuruluyor."
  apt_install curl wget ca-certificates openssl gettext-base
  require_commands curl grep sort tail wget chmod id adduser install
  forgejo_version="$(
    curl -fsSL https://codeberg.org/forgejo/forgejo/releases |
      grep -oP 'forgejo/releases/download/v\K[0-9.]+' |
      sort -Vu |
      tail -n 1
  )"
  [[ -n "$forgejo_version" ]] || die "Forgejo sürümü belirlenemedi."

  wget -O /usr/local/bin/forgejo \
    "https://codeberg.org/forgejo/forgejo/releases/download/v${forgejo_version}/forgejo-${forgejo_version}-linux-amd64"
  chmod 0755 /usr/local/bin/forgejo

  if ! id git &>/dev/null; then
    adduser --system --shell /bin/bash --gecos 'Git Version Control' \
      --group --disabled-password --home /home/git git
  fi

  install -d -m 0750 -o git -g git /var/lib/forgejo
  install -d -m 0750 -o root -g git /etc/forgejo
  log "Forgejo kuruldu; uygulama yapılandırması yazılmadı." "success"
}

persistence_packages_installed() {
  local package
  local status

  command -v dpkg-query >/dev/null 2>&1 || return 1
  for package in iptables-persistent netfilter-persistent; do
    status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" || return 1
    [[ "$status" == "install ok installed" ]] || return 1
  done
}

install_firewall_packages_safely() {
  local rules_v4_backup=""
  local rules_v6_backup=""
  local rules_v4_existed=0
  local rules_v6_existed=0

  [[ "$FIREWALL_PACKAGES_READY" -eq 0 ]] || return 0
  apt_install iproute2 procps
  if persistence_packages_installed; then
    FIREWALL_PACKAGES_READY=1
    return 0
  fi

  require_commands dpkg-query mktemp cp rm mkdir systemctl
  mkdir -p /etc/iptables
  if [[ -f /etc/iptables/rules.v4 ]]; then
    rules_v4_existed=1
    rules_v4_backup="$(mktemp /tmp/shman-rules-v4.XXXXXX)"
    cp -p -- /etc/iptables/rules.v4 "$rules_v4_backup"
  fi
  if [[ -f /etc/iptables/rules.v6 ]]; then
    rules_v6_existed=1
    rules_v6_backup="$(mktemp /tmp/shman-rules-v6.XXXXXX)"
    cp -p -- /etc/iptables/rules.v6 "$rules_v6_backup"
  fi

  rm -f -- /etc/iptables/rules.v4 /etc/iptables/rules.v6
  if ! apt_install iptables iptables-persistent netfilter-persistent; then
    [[ "$rules_v4_existed" -eq 0 ]] || cp -p -- "$rules_v4_backup" /etc/iptables/rules.v4
    [[ "$rules_v6_existed" -eq 0 ]] || cp -p -- "$rules_v6_backup" /etc/iptables/rules.v6
    [[ -z "$rules_v4_backup" ]] || rm -f -- "$rules_v4_backup"
    [[ -z "$rules_v6_backup" ]] || rm -f -- "$rules_v6_backup"
    die "Firewall kalıcılık paketleri kurulamadı."
  fi

  systemctl disable --now netfilter-persistent >/dev/null 2>&1 || true
  rm -f -- /etc/iptables/rules.v4 /etc/iptables/rules.v6
  [[ "$rules_v4_existed" -eq 0 ]] || cp -p -- "$rules_v4_backup" /etc/iptables/rules.v4
  [[ "$rules_v6_existed" -eq 0 ]] || cp -p -- "$rules_v6_backup" /etc/iptables/rules.v6
  [[ -z "$rules_v4_backup" ]] || rm -f -- "$rules_v4_backup"
  [[ -z "$rules_v6_backup" ]] || rm -f -- "$rules_v6_backup"
  FIREWALL_PACKAGES_READY=1
}

install_firewall() {
  [[ "$INSTALL_FIREWALL" -eq 1 ]] || return 0

  log "Firewall kalıcılık paketleri kuruluyor."
  install_firewall_packages_safely
  run_needrestart
  log "Firewall kalıcılık paketleri kuruldu; servis config uygulanana kadar etkinleştirilmedi." "success"
}

install_fwknop() {
  [[ "$INSTALL_FWKNOP" -eq 1 ]] || return 0

  log "FWKnop server bağımlılıkları kuruluyor."
  apt_install fwknop-server fwknop-client gnupg openssl
  install_firewall_packages_safely
  run_needrestart
  log "FWKnop server bağımlılıkları kuruldu." "success"
}

install_zram() {
  local kernel

  [[ "$INSTALL_ZRAM" -eq 1 ]] || return 0

  apt_install kmod initramfs-tools procps
  require_commands uname modinfo
  kernel="$(uname -r)"
  log "ZRAM generator kuruluyor."
  apt_install systemd-zram-generator

  if ! modinfo zram &>/dev/null; then
    log "zram modülü bulunamadı; linux-modules-extra-$kernel kuruluyor."
    apt_install "linux-modules-extra-$kernel"
  fi

  modinfo zram &>/dev/null || die "zram kernel modülü kurulumdan sonra da bulunamadı."
  run_needrestart
  log "ZRAM bağımlılıkları kuruldu." "success"
}

install_zsh() {
  [[ "$INSTALL_ZSH" -eq 1 ]] || return 0

  log "ZSH ortamı paketleri kuruluyor."
  apt_install zsh git fzf zsh-autosuggestions zsh-syntax-highlighting
  run_needrestart
  log "ZSH ortamı paketleri kuruldu." "success"
}

install_ssh() {
  [[ "$INSTALL_SSH" -eq 1 ]] || return 0

  log "OpenSSH server kuruluyor."
  apt_install openssh-server iproute2
  run_needrestart
  log "OpenSSH server kuruldu; sshd yapılandırması değiştirilmedi." "success"
}

main() {
  require_root
  require_commands apt-get date needrestart
  parse_arguments "$@"
  collect_mysql_password
  apt_update
  install_base
  install_node
  install_postgresql
  install_mysql
  install_php
  install_podman
  install_nginx
  install_apache
  install_certbot
  install_forgejo
  install_firewall
  install_fwknop
  install_zram
  install_zsh
  install_ssh
}

main "$@"
