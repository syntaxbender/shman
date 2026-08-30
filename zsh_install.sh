#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root:"
    echo "  sudo bash $0"
    exit 1
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-ubuntu}}"

if ! id "$TARGET_USER" &>/dev/null; then
    echo "ERROR: User not found: $TARGET_USER"
    exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

echo "Target user: $TARGET_USER"
echo "Target home: $TARGET_HOME"

echo
echo "=== Installing ZSH environment ==="

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    zsh \
    git \
    fzf \
    zsh-autosuggestions \
    zsh-syntax-highlighting

P10K_DIR="$TARGET_HOME/.local/share/powerlevel10k"

install -d \
    -o "$TARGET_USER" \
    -g "$TARGET_GROUP" \
    "$TARGET_HOME/.local/share"

if [[ ! -d "$P10K_DIR/.git" ]]; then
    echo "Installing Powerlevel10k..."

    runuser -u "$TARGET_USER" -- \
        env HOME="$TARGET_HOME" \
        git clone --depth=1 \
        https://github.com/romkatv/powerlevel10k.git \
        "$P10K_DIR"
else
    echo "Powerlevel10k already installed."
fi

ZSHRC="$TARGET_HOME/.zshrc"

touch "$ZSHRC"
chown "$TARGET_USER:$TARGET_GROUP" "$ZSHRC"

if ! grep -qF '### OCI-ZSH-BEGIN ###' "$ZSHRC"; then

    if [[ -s "$ZSHRC" ]]; then
        cp "$ZSHRC" "${ZSHRC}.bak"
        chown "$TARGET_USER:$TARGET_GROUP" "${ZSHRC}.bak"
    fi

    cat >> "$ZSHRC" <<'EOF'

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

fi

chown "$TARGET_USER:$TARGET_GROUP" "$ZSHRC"

ZSH_BIN="$(command -v zsh)"

if [[ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" != "$ZSH_BIN" ]]; then
    echo "Setting ZSH as default shell..."
    usermod -s "$ZSH_BIN" "$TARGET_USER"
fi

echo
echo "=== DONE ==="
echo "Default shell:"
getent passwd "$TARGET_USER" | cut -d: -f7

echo
echo "Reconnect via SSH."
echo "Then run:"
echo "  p10k configure"
