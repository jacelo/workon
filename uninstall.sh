#!/usr/bin/env bash
# uninstall.sh — undo what install.sh and workon changed on this Mac. Safe to re-run.
#
#   ./uninstall.sh           remove workon from ~/.zshrc and its changes to ~/.ssh
#   ./uninstall.sh --purge   also delete your config and Claude tokens (asks first)
#
# Machines are never deleted: their names are printed with the command to delete each one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[36m→\033[0m %s\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }

purge=""
case "${1:-}" in
  "") ;;
  --purge) purge=1 ;;
  -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown option: $1 (see ./uninstall.sh --help)" >&2; exit 1 ;;
esac

# Read machine names first, while the config still exists.
machines=""
if [[ -f "$ROOT/config/workon.json" ]] && command -v jq >/dev/null; then
  machines="$("$ROOT/bin/workon" --list 2>/dev/null | awk 'NR > 1 {print $2}')" || true
fi

# remove_block <file> <start marker> <end marker>: delete the lines between the markers, inclusive.
remove_block() {
  local file="$1" start="$2" end="$3"
  grep -qxF "$start" "$file" 2>/dev/null || return 1
  cp "$file" "$file.bak-workon"
  awk -v s="$start" -v e="$end" '$0 == s {skip = 1} !skip {print} $0 == e {skip = 0}' "$file.bak-workon" > "$file"
}

# 1. Shell: PATH and tab completion.
if remove_block "$HOME/.zshrc" "# >>> workon >>>" "# <<< workon <<<"; then
  ok "Removed workon from ~/.zshrc (backup: ~/.zshrc.bak-workon)"
else
  ok "~/.zshrc has no workon block"
fi

# 2. SSH: the forwarding block, the alias Include line, and the alias files.
sshcfg="$HOME/.ssh/config"
changed=""
if remove_block "$sshcfg" "# >>> workon hardening >>>" "# <<< workon hardening <<<"; then changed=1; fi
if grep -qxF "Include ~/.ssh/workon/*.conf" "$sshcfg" 2>/dev/null; then
  [[ -n "$changed" ]] || cp "$sshcfg" "$sshcfg.bak-workon"
  awk '$0 != "# Added by workon: SSH aliases for project machines" && $0 != "Include ~/.ssh/workon/*.conf"' \
    "$sshcfg" > "$sshcfg.tmp-workon" && mv "$sshcfg.tmp-workon" "$sshcfg"
  chmod 600 "$sshcfg"
  changed=1
fi
if [[ -n "$changed" ]]; then ok "Removed workon's changes from ~/.ssh/config (backup: ~/.ssh/config.bak-workon)"
else ok "~/.ssh/config has no workon changes"; fi
if [[ -d "$HOME/.ssh/workon" ]]; then
  rm -rf "$HOME/.ssh/workon"
  ok "Removed the machine SSH aliases in ~/.ssh/workon/"
fi

# 3. Your config and tokens, only with --purge.
if [[ -n "$purge" ]]; then
  echo
  warn "This deletes config/workon.json and every token in config/claude-keys/."
  read -r -p "Type 'yes' to delete them: " answer
  if [[ "$answer" == "yes" ]]; then
    rm -f "$ROOT/config/workon.json"
    find "$ROOT/config/claude-keys" -type f ! -name .gitkeep -delete 2>/dev/null || true
    ok "Deleted your config and Claude tokens"
  else
    info "Kept your config and Claude tokens"
  fi
else
  info "Kept your config and Claude tokens (./uninstall.sh --purge deletes them)"
fi

# 4. Machines are left alone.
existing=""
if command -v orb >/dev/null; then existing="$(orb list </dev/null 2>/dev/null | awk '{print $1}')" || true; fi
found=""
while IFS= read -r m; do
  if [[ -n "$m" ]] && grep -qx -- "$m" <<<"$existing"; then found="$found    orb delete $m"$'\n'; fi
done <<<"$machines"
if [[ -n "$found" ]]; then
  echo
  info "Your machines were kept. To delete one and everything in it:"
  printf '%s' "$found"
fi

echo
info "Open a new terminal to finish. This folder can be deleted once you no longer need it."
