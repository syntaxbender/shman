#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

SERVER_IP=$(curl checkip.amazonaws.com)

[ -f "/var/www/html/nothing.jpg" ] && \
  mv /var/www/html/nothing.jpg /var/www/html/nothing-$(uuidgen).jpg.bak
[ -f "/var/www/html/index.html" ] && \
  mv /var/www/html/index.html /var/www/html/index-$(uuidgen).html.bak

wget -q -O /var/www/html/nothing.jpg https://raw.githubusercontent.com/syntaxbender/linux-infrastructure/refs/heads/main/data/nginx/var_html/nothing.jpg
wget -q -O /var/www/html/index.html https://raw.githubusercontent.com/syntaxbender/linux-infrastructure/refs/heads/main/data/nginx/var_html/index.html

mkdir -p /etc/nginx/ssl/ && \
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt -subj "/C=/ST=/L=/O=/OU=/CN=/emailAddress="

[ -f "/etc/nginx/sites-enabled/default" ] && \
  rm /etc/nginx/sites-enabled/default || \
  echo "Default is not enabled in nginx"
[ -f "/etc/nginx/sites-available/default" ] && \
  mv /etc/nginx/sites-available/default /etc/nginx/sites-available/default-$(uuidgen).bak || \
  echo "Default is not available in nginx"

cat <<EOF > /etc/nginx/sites-available/default
server {
    listen 80;
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    server_name $SERVER_IP;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\.ht {
        deny all;
    }
}

server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server{
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;
    return       404;
}
EOF

ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
echo "Testing nginx..."
nginx -t && \
  {
    systemctl restart nginx && \
      echo "Nginx restarted successfully!";
  } || \
  echo "Nginx configuration failed!"
