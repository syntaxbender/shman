#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

USERNAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)
      if [[ -n "$2" ]]; then
        USERNAME="$2"
        shift
      else
        echo "Error: --user requires a value."
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

if [[ -z "$USERNAME" ]]; then
    echo "Error: --user arg required."
    echo "Usage: [...] --user USERNAME"
    exit 1
fi

useradd -m -d /home/$USERNAME -s /bin/bash -U $USERNAME && \
mkdir -p /home/$USERNAME/public_html && \
chmod -R 750 /home/$USERNAME && \
chown -R $USERNAME:$USERNAME /home/$USERNAME && \
usermod -aG $USERNAME www-data
