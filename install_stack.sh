#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

apt update && apt upgrade -y
apt install -y curl wget net-tools dnsutils build-essential git gnupg lsb-release ca-certificates software-properties-common openssl nginx certbot python3-certbot-nginx uuid-runtime
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt install -y nodejs
