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
      SVC_NAME="$2"; shift;;
    -u|--user)
      USER="$2"; shift;;
    -enpm|--exec-npm)
      EXEC_NPM="$2"; shift;;
    -p|--port)
      PORT="$2"; shift;;
    -d|--description)
      DESC="$2"; shift;;
    -envf|--env-file)
      ENV_FILE=true;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [[
  -z "$SVC_NAME" || -z "$USER" || -z "$EXEC_NPM" || -z "$DESC" ||
  "$SVC_NAME" == -* || "$USER" == -* || "$EXEC_NPM" == -* || "$DESC" == -*
]]; then
    echo "Error: --user, --exec-npm, --description, --svc-name args required."
    echo "Usage: [...] --user username --exec-npm \"run start\" --description \"prod service\" --svc-name \"service\" [--port 3000] [--env-file]"
    exit 1
fi

PORT_LINE=""
ENV_FILE_LINE=""
[[ -n "$PORT" ]] && PORT_LINE="Environment=PORT=$PORT"
[[ "$ENV_FILE" = true ]] && ENV_FILE_LINE="EnvironmentFile=/home/${USER}/app/.env"

export USER EXEC_NPM DESC PORT_LINE ENV_FILE_LINE

envsubst < ./templates/systemd/service.template > "/etc/systemd/system/${SVC_NAME}.service"

echo "Service file created at /etc/systemd/system/${SVC_NAME}.service"
