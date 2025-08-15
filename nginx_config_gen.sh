#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

PROXY_PASS=""
DOMAIN=""
WEBSOCKET_LINE=""
WWW_REDIRECT=false
WEBSOCKET_PASS=false
SSL_DISABLED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--proxy-pass)
      PROXY_PASS="$2"; shift;;
    -d|--domain)
      DOMAIN="$2"; shift;;
    -ws|--websocket)
      WEBSOCKET_PASS=true
      ;;
    -r|--www-redirect)
      WWW_REDIRECT=true
      ;;
    -dssl|--disable-ssl)
      SSL_DISABLED=true
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$PROXY_PASS" || -z "$DOMAIN" || "$PROXY_PASS" == -* || "$DOMAIN" == -* ]]; then
    echo "Error: --proxy-pass ve --domain required."
    echo "Usage: [...] --proxy-pass http://127.0.0.1:3000 --domain example.com [--www-redirect] [--websocket] [--disable-ssl]"
    echo "Usage: [...] -p http://127.0.0.1:3000 -d example.com [-r] [-ws] [-dssl]"
    exit 1
fi

[ -f "/etc/nginx/sites-enabled/$DOMAIN.conf" ] && \
    rm "/etc/nginx/sites-enabled/$DOMAIN.conf"

[ -f "/etc/nginx/sites-available/$DOMAIN.conf" ] && \
  {
    mkdir -p /etc/nginx/sites-available/deadsites
    mv /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-available/deadsites/$DOMAIN-$(uuidgen).conf.bak
  }

if [ "$WWW_REDIRECT" = true ]; then
   SERVER_NAME_LINE="server_name www.$DOMAIN;"
else
   SERVER_NAME_LINE="server_name $DOMAIN;"
fi

if [ "$WEBSOCKET_PASS" = true ]; then
  WEBSOCKET_LINE="proxy_set_header Connection \$http_connection;
  proxy_set_header Upgrade \$http_upgrade;"
fi
if [ "$SSL_DISABLED" = false ]; then
  LISTEN_LINE="listen 443 ssl;"
  SSL_LINES="ssl_certificate         /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key     /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
  include                 /etc/letsencrypt/options-ssl-nginx.conf;
  ssl_dhparam             /etc/letsencrypt/ssl-dhparams.pem;
  ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/chain.pem;
  ssl_stapling on;
  ssl_stapling_verify on;"
else
  LISTEN_LINE="listen 80;"
  SSL_LINES=""
fi
export PROXY_PASS DOMAIN SERVER_NAME_LINE WEBSOCKET_LINE LISTEN_LINE SSL_LINES

envsubst '${LISTEN_LINE} ${SERVER_NAME_LINE} ${PROXY_PASS} ${WEBSOCKET_LINE} ${SSL_LINES}'  < ./templates/nginx/site.template > "/etc/nginx/sites-available/${DOMAIN}.conf"

if [ "$WWW_REDIRECT" = true ]; then
  envsubst '${LISTEN_LINE} ${DOMAIN} ${SSL_LINES}'  < ./templates/nginx/site_redirect.template >> "/etc/nginx/sites-available/${DOMAIN}.conf"
fi

ln -s /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/

echo "Testing nginx..."
nginx -t && \
  {
    systemctl restart nginx && \
      echo "Nginx restarted successfully!";
  } || \
  echo "Nginx configuration failed!"
