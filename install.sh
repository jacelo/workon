#!/usr/bin/env bash
# install.sh — set up workon on this Mac. Safe to re-run: each step checks before changing anything.
#   1. Checks the tools workon needs.
#   2. Adds bin/ to PATH and the zsh completion to ~/.zshrc.
#   3. Turns off SSH agent and X11 forwarding to OrbStack machines in ~/.ssh/config.
#   4. Creates config/workon.json from the example if you don't have one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }

# 1. Tools
for tool in jq orb ssh osascript; do
  if command -v "$tool" >/dev/null; then ok "$tool found"; else warn "$tool not found"; fi
done
command -v jq  >/dev/null || warn "  install it with: brew install jq"
command -v orb >/dev/null || warn "  install OrbStack: https://orbstack.dev"
if command -v cursor >/dev/null || [[ -x /Applications/Cursor.app/Contents/Resources/app/bin/cursor ]]; then
  ok "Cursor found"
else
  warn "Cursor not found: https://cursor.com"
fi

# 2. PATH and completion
# The block between the markers is rewritten when it's out of date, so path changes carry over.
zshrc="$HOME/.zshrc"
block="# >>> workon >>>
export PATH=\"$ROOT/bin:\$PATH\"
autoload -Uz compinit && compinit -C
source \"$ROOT/lib/completion.zsh\"
# <<< workon <<<"
touch "$zshrc"
current="$(sed -n '/^# >>> workon >>>$/,/^# <<< workon <<<$/p' "$zshrc")"
if [[ "$current" == "$block" ]]; then
  ok "~/.zshrc already set up"
else
  if [[ -n "$current" ]]; then
    cp "$zshrc" "$zshrc.bak-workon"
    sed -i '' '/^# >>> workon >>>$/,/^# <<< workon <<<$/d' "$zshrc"
  fi
  printf '\n%s\n' "$block" >> "$zshrc"
  ok "Updated ~/.zshrc (open a new terminal to use it)"
fi

# 3. SSH hardening
sshcfg="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if grep -qF "# >>> workon hardening >>>" "$sshcfg" 2>/dev/null; then
  ok "~/.ssh/config already hardened"
else
  cat >> "$sshcfg" <<'SSH'

# >>> workon hardening >>>
# Never forward your Mac's SSH agent or X11 into OrbStack machines.
Host orb
  ForwardAgent no
  ForwardX11 no
# <<< workon hardening <<<
SSH
  chmod 600 "$sshcfg"
  ok "Turned off agent and X11 forwarding to OrbStack machines in ~/.ssh/config"
fi

# 4. Config
mkdir -p "$ROOT/config/claude-keys"; chmod 700 "$ROOT/config/claude-keys"
if [[ -f "$ROOT/config/workon.json" ]]; then
  ok "config/workon.json exists"
else
  cp "$ROOT/config/workon.example.json" "$ROOT/config/workon.json"
  ok "Created config/workon.json from the example — edit it with 'workon --edit'"
fi
