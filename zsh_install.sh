#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TARGET_USER="${TARGET_USER:-${SUDO_USER:-ubuntu}}"
TARGET_HOME=""
TARGET_GROUP=""
P10K_DIR=""
ZSHRC=""
ZSH_BIN=""

load_target_user() {
  id "$TARGET_USER" &>/dev/null || die "User not found: $TARGET_USER"

  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  TARGET_GROUP="$(id -gn "$TARGET_USER")"
  P10K_DIR="$TARGET_HOME/.local/share/powerlevel10k"
  ZSHRC="$TARGET_HOME/.zshrc"

  echo "Target user: $TARGET_USER"
  echo "Target home: $TARGET_HOME"
}

install_zsh_packages() {
  echo
  echo "=== Installing ZSH environment ==="

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    zsh git fzf zsh-autosuggestions zsh-syntax-highlighting
}

install_powerlevel10k() {
  install -d \
    -o "$TARGET_USER" \
    -g "$TARGET_GROUP" \
    "$TARGET_HOME/.local/share"

  if [[ -d "$P10K_DIR/.git" ]]; then
    echo "Powerlevel10k already installed."
    return 0
  fi

  echo "Installing Powerlevel10k..."
  runuser -u "$TARGET_USER" -- \
    env HOME="$TARGET_HOME" \
    git clone --depth=1 \
    https://github.com/romkatv/powerlevel10k.git \
    "$P10K_DIR"
}

configure_zshrc() {
  touch "$ZSHRC"
  chown "$TARGET_USER:$TARGET_GROUP" "$ZSHRC"

  if grep -qF '### OCI-ZSH-BEGIN ###' "$ZSHRC"; then
    return 0
  fi

  if [[ -s "$ZSHRC" ]]; then
    cp "$ZSHRC" "${ZSHRC}.bak"
    chown "$TARGET_USER:$TARGET_GROUP" "${ZSHRC}.bak"
  fi

  cat >>"$ZSHRC" <<'EOF'

### OCI-ZSH-BEGIN ###

# History
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000

setopt HIST_IGNORE_DUPS
setopt SHARE_HISTORY

# Completion
autoload -Uz compinit
compinit

# Powerlevel10k
source "$HOME/.local/share/powerlevel10k/powerlevel10k.zsh-theme"

# fzf
[[ -f /usr/share/doc/fzf/examples/completion.zsh ]] && \
    source /usr/share/doc/fzf/examples/completion.zsh

[[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]] && \
    source /usr/share/doc/fzf/examples/key-bindings.zsh

# Autosuggestions
[[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && \
    source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Powerlevel10k configuration
[[ -f "$HOME/.p10k.zsh" ]] && \
    source "$HOME/.p10k.zsh"

# Syntax highlighting should be loaded last
[[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
    source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

### OCI-ZSH-END ###
EOF

  chown "$TARGET_USER:$TARGET_GROUP" "$ZSHRC"
}

set_default_shell() {
  ZSH_BIN="$(command -v zsh)"
  if [[ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" == "$ZSH_BIN" ]]; then
    return 0
  fi

  echo "Setting ZSH as default shell..."
  usermod -s "$ZSH_BIN" "$TARGET_USER"
}

print_completion_summary() {
  echo
  echo "=== DONE ==="
  echo "Default shell:"
  getent passwd "$TARGET_USER" | cut -d: -f7

  echo
  echo "Reconnect via SSH."
  echo "Then run:"
  echo "  p10k configure"
}

main() {
  require_root
  load_target_user
  install_zsh_packages
  install_powerlevel10k
  configure_zshrc
  set_default_shell
  print_completion_summary
}

main "$@"
