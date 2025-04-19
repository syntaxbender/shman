#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

PROXY_PASS=""
DOMAIN=""
WWW_REDIRECT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--proxy-pass)
      if [[ -n "$2" ]]; then
        PROXY_PASS="$2"
        shift
      else
        echo "Error: --proxy-pass requires a value."
        exit 1
      fi
      ;;
    -d|--domain)
      if [[ -n "$2" ]]; then
        DOMAIN="$2"
        shift
      else
        echo "Error: --domain requires a value."
        exit 1
      fi
      ;;
    -r|--www-redirect)
      WWW_REDIRECT=true
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$PROXY_PASS" || -z "$DOMAIN" ]]; then
    echo "Error: --proxy-pass ve --domain required."
    echo "Usage: [...] --proxy-pass http://127.0.0.1:3000 --domain example.com [--www-redirect]"
    echo "Usage: [...] -p http://127.0.0.1:3000 -d example.com [-r]"
    exit 1
fi



[ -f "/etc/nginx/sites-enabled/$DOMAIN.conf" ] && \
    rm "/etc/nginx/sites-enabled/$DOMAIN.conf"

[ -f "/etc/nginx/sites-available/$DOMAIN.conf" ] && \
  {
    mkdir -p /etc/nginx/sites-available/deadsites
    mv /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-available/deadsites/$DOMAIN-$(uuidgen).conf.bak
  }

cat > "/etc/nginx/sites-available/$DOMAIN.conf" <<EOF
server {
    listen 443 ssl;
    server_name www.$DOMAIN;

    location / {
        proxy_pass       $PROXY_PASS;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    ssl_certificate         /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include                 /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam             /etc/letsencrypt/ssl-dhparams.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;
    ssl_stapling on;
    ssl_stapling_verify on;
}
EOF

if [ "$WWW_REDIRECT" = true ]; then
cat >> "/etc/nginx/sites-available/$DOMAIN.conf" <<EOF

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    return 301 https://www.$DOMAIN\$request_uri;
}
EOF
fi

ln -s /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/

echo "Testing nginx..."
nginx -t && \
  {
    systemctl restart nginx && \
      echo "Nginx restarted successfully!";
  } || \
  echo "Nginx configuration failed!"
