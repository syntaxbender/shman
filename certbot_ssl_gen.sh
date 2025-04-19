#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

DOMAINS=""
WEB_SERVER="nginx"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domains)
      if [[ -n "$2" ]]; then
        DOMAINS="$2"
        PRIMARY_DOMAIN=$(echo "$DOMAINS" | cut -d',' -f1)
        shift
      else
        echo "Error: --domains requires a value."
        exit 1
      fi
      ;;
    -w|--web-server)
      if [[ -n "$2" ]]; then
        WEB_SERVER="$2"
        shift
      else
        echo "Error: --web-server requires a value."
        exit 1
      fi
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$DOMAINS" ]]; then
    echo "Error: --domains arg required."
    echo "Usage: [...] --domains "example.com,www.example.com" [--web-server nginx|apache]"
    exit 1
fi

if [[ "$WEB_SERVER" != "apache" && "$WEB_SERVER" != "nginx" ]]; then
    echo "Error: --web-server arg must be nginx or apache"
    exit 1
fi

certbot certonly -a $WEB_SERVER --agree-tos --no-eff-email --staple-ocsp --force-renewal --email info@$PRIMARY_DOMAIN -d $DOMAINS
