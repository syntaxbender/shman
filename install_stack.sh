#!/bin/bash
DEBIAN_FRONTEND=noninteractive

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

INSTALL_POSTGRES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -psql|--postgres)
      INSTALL_POSTGRES=true
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

apt update && apt upgrade -y
needrestart -r a
apt install -y curl gnupg2 wget net-tools dnsutils build-essential git gnupg lsb-release ca-certificates software-properties-common openssl nginx certbot python3-certbot-nginx uuid-runtime 
needrestart -r a
wget -q https://deb.nodesource.com/setup_20.x -O ./nodesource.sh && \
chmod +x ./nodesource.sh && \
./nodesource.sh && \
apt install -y nodejs && \
rm ./nodesource.sh

if [ "$INSTALL_POSTGRES" = true ]; then
install -d /usr/share/postgresql-common/pgdg && \
  curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
  . /etc/os-release && \
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
  apt update && \
  apt -y install postgresql-16 postgresql-contrib-16
fi

./nginx_default.sh
