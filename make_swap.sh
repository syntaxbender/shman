#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

SWAP_SIZE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--size)
      if [[ -n "$2" ]]; then
        SWAP_SIZE="$2"
        shift
      else
        echo "Error: --size requires a value as megabytes."
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

if [[ -z "$SWAP_SIZE" ]]; then
    echo "Error: --size arg required."
    echo "Usage: [...] --size 1536"
    exit 1
fi

fallocate -l "${SWAP_SIZE_MB}M" /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
