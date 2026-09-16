#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

WEB_SERVER="nginx"
INPUT_DOMAINS=()
CERTBOT_DOMAINS=()

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--domains)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "--domains değer gerektirir."
        IFS=',' read -r -a INPUT_DOMAINS <<<"$2"
        shift 2
        ;;
      -w|--web-server)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "--web-server değer gerektirir."
        WEB_SERVER="$2"
        shift 2
        ;;
      *) die "Bilinmeyen seçenek: $1" ;;
    esac
  done
}

validate_inputs() {
  local domain

  [[ "${#INPUT_DOMAINS[@]}" -gt 0 ]] ||
    die "Kullanım: $0 --domains example.com,www.example.com [--web-server nginx|apache]"
  [[ "$WEB_SERVER" == nginx || "$WEB_SERVER" == apache ]] ||
    die "--web-server nginx veya apache olmalıdır."

  for domain in "${INPUT_DOMAINS[@]}"; do
    [[ "$domain" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]{2,63}$ ]] ||
      die "Geçersiz domain: $domain"
  done
}

collect_certificate_domains() {
  local certbot_output
  local line
  local domain
  local first_domain="${INPUT_DOMAINS[0]}"
  local existing_domains=()
  local matching_domains=()

  certbot_output="$(certbot certificates 2>/dev/null || true)"

  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*Domains:[[:space:]]+(.*)$ ]]; then
      read -ra existing_domains <<<"${BASH_REMATCH[1]}"
      for domain in "${existing_domains[@]}"; do
        if [[ "$domain" == "$first_domain" ]]; then
          matching_domains=("${existing_domains[@]}")
          break 2
        fi
      done
    fi
  done <<<"$certbot_output"

  mapfile -t CERTBOT_DOMAINS < <(
    printf '%s\n' "${matching_domains[@]}" "${INPUT_DOMAINS[@]}" |
      awk 'NF && !seen[$0]++ { print length($0), $0 }' |
      sort -n |
      cut -d' ' -f2-
  )
}

request_certificate() {
  local primary_domain="${CERTBOT_DOMAINS[0]}"
  local certbot_args=()
  local domain

  for domain in "${CERTBOT_DOMAINS[@]}"; do
    certbot_args+=(-d "$domain")
  done

  certbot certonly \
    -a "$WEB_SERVER" \
    --agree-tos \
    --no-eff-email \
    --staple-ocsp \
    --force-renewal \
    --email "info@$primary_domain" \
    "${certbot_args[@]}"
}

main() {
  require_root
  require_commands certbot awk sort cut
  parse_arguments "$@"
  validate_inputs
  collect_certificate_domains
  request_certificate
}

main "$@"
