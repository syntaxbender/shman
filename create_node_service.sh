#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root! exiting..."
  exit 1
fi

SVC_NAME=""
USER=""
EXEC_NPM=""
PORT=""
DESC=""
ENV_FILE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -sn|--svc-name)
      if [[ -n "$2" ]]; then
        SVC_NAME="$2"
        shift
      else
        echo "Error: --svc-name requires a value."
        exit 1
      fi
      ;;
    -u|--user)
      if [[ -n "$2" ]]; then
        USER="$2"
        shift
      else
        echo "Error: --user requires a value."
        exit 1
      fi
      ;;
    -enpm|--exec-npm)
      if [[ -n "$2" ]]; then
        EXEC_NPM="$2"
        shift
      else
        echo "Error: --exec-npm requires a value."
        exit 1
      fi
      ;;
    -p|--port)
      if [[ -n "$2" ]]; then
        PORT="$2"
        shift
      else
        echo "Error: --port requires a value."
        exit 1
      fi
      ;;
    -d|--description)
      if [[ -n "$2" ]]; then
        DESC="$2"
        shift
      else
        echo "Error: --description requires a value."
        exit 1
      fi
      ;;
    -envf|--env-file)
      ENV_FILE=true
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$SVC_NAME" || -z "$USER" || -z "$EXEC_NPM" || -z "$DESC" ]]; then
    echo "Error: --user, --exec-npm, --port, --description, --env-file args required."
    echo "Usage: [...] --user username --exec-npm "run start" --description "prod service" [--port 3000] [--env-file]"
    exit 1
fi

cat > "/etc/systemd/system/$SVC_NAME.conf" <<EOF
[Unit]
Description=$DESC

[Service]
User=$USER
Group=$USER
WorkingDirectory=/home/$USER/app
ExecStart=/usr/bin/npm $EXEC_NPM
Restart=on-failure
Environment=NODE_ENV=production
[Install]
WantedBy=default.target
EOF

ENV_FILE_LINE="EnvironmentFile=/home/$USER/app/.env"
PORT_LINE="Environment=PORT=$PORT"
[ -n "$PORT" ] && \
    sed -i "/Restart/a $PORT_LINE" /etc/systemd/system/$SVC_NAME.conf

[ "$ENV_FILE" = true ] && \
    sed -i "/Restart/a $ENV_FILE_LINE" /etc/systemd/system/$SVC_NAME.conf
