#!/usr/bin/env bash

backup_file() {
  local source_file="$1"
  local backup_directory="$2"
  local backup_file

  [[ -f "$source_file" ]] || return 1

  mkdir -p "$backup_directory"
  backup_file="$backup_directory/$(basename "$source_file").$(date +%Y%m%d%H%M%S)-$RANDOM.bak"
  cp -p -- "$source_file" "$backup_file"
  printf '%s\n' "$backup_file"
}

restore_file_backup() {
  local backup_file="$1"
  local destination="$2"

  cp -p -- "$backup_file" "$destination"
}

install_validated_config() {
  local candidate_file="$1"
  local destination="$2"
  local mode="$3"
  local rollback_file=""
  shift 3

  if [[ -f "$destination" ]]; then
    rollback_file="$(mktemp)"
    cp -p -- "$destination" "$rollback_file"
  fi

  if ! install -m "$mode" "$candidate_file" "$destination" || ! "$@"; then
    if [[ -n "$rollback_file" ]]; then
      cp -p -- "$rollback_file" "$destination"
    else
      rm -f -- "$destination"
    fi
    [[ -z "$rollback_file" ]] || rm -f -- "$rollback_file"
    return 1
  fi

  [[ -z "$rollback_file" ]] || rm -f -- "$rollback_file"
}

upsert_config_line() {
  local config_file="$1"
  local match_regex="$2"
  local replacement="$3"
  local ignore_case="${4:-0}"

  if [[ "$ignore_case" -eq 1 ]] && grep -Eiq "$match_regex" "$config_file"; then
    sed -Ei "s|${match_regex}.*|${replacement}|I" "$config_file"
  elif grep -Eq "$match_regex" "$config_file"; then
    sed -Ei "s|${match_regex}.*|${replacement}|" "$config_file"
  else
    printf '%s\n' "$replacement" >>"$config_file"
  fi
}
