#!/bin/bash

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

sudo apt install gnupg2 wget
sudo sh -c 'echo "deb [arch=amd64] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys B7B3B788A8D3785C 
sudo apt update
sudo apt install -y postgresql-16 postgresql-contrib-16


apt update && apt upgrade -y
apt install -y curl gnupg2 wget net-tools dnsutils build-essential git gnupg lsb-release ca-certificates software-properties-common openssl nginx certbot python3-certbot-nginx uuid-runtime 
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt install -y nodejs

if [ "$INSTALL_POSTGRES" = true ]; then
install -d /usr/share/postgresql-common/pgdg && \
  curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc

. /etc/os-release && \
  sudo sh -c "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main' > /etc/apt/sources.list.d/pgdg.list" && \
  sudo apt update && \
  sudo apt -y install postgresql-16 postgresql-contrib-16
fi

./nginx_default.sh
