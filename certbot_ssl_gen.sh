#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

DOMAINS=false
WEB_SERVER="nginx"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domains)
      if [[ -n "$2" ]]; then
        DOMAINS=true
        IFS=',' read -r -a input_domains <<< "$2"
        first_arg_domain="${input_domains[0]}"
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

if [ "$DOMAINS" = false ]; then
    echo "Error: --domains arg required."
    echo "Usage: [...] --domains "example.com,www.example.com" [--web-server nginx|apache]"
    exit 1
fi

if [[ "$WEB_SERVER" != "apache" && "$WEB_SERVER" != "nginx" ]]; then
    echo "Error: --web-server arg must be nginx or apache"
    exit 1
fi

declare -A shortest_domains

CERTBOT_OUTPUT=$(certbot certificates 2>/dev/null || true)

while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*Domains:\ (.*)$ ]]; then
        domain_list="${BASH_REMATCH[1]}"
        IFS=' ' read -r -a domains <<< "$domain_list"
        sorted=($(for d in "${domains[@]}"; do echo "$d"; done | awk '{ print length, $0 }' | sort -n | cut -d' ' -f2-))
        shortest="${sorted[0]}"
        sorted_joined=$(printf "%s " "${sorted[@]}")
        sorted_joined=${sorted_joined% }
        shortest_domains["$shortest"]="$sorted_joined"
    fi
done <<< "$CERTBOT_OUTPUT"

matched_value=""
for key in "${!shortest_domains[@]}"; do
    if [[ "$first_arg_domain" == *"$key"* ]]; then
        matched_value="${shortest_domains[$key]}"
        break
    fi
done

combined_domains=($matched_value "${input_domains[@]}")
sorted_combined=($(for d in "${combined_domains[@]}"; do echo "$d"; done | awk '{ print length, $0 }' | sort -n | cut -d' ' -f2-))

PRIMARY_DOMAIN="${sorted_combined[0]}"
DOMAINS="${sorted_combined[*]}"

certbot certonly -a $WEB_SERVER --agree-tos --no-eff-email --staple-ocsp --force-renewal --email info@$PRIMARY_DOMAIN -d $DOMAINS
