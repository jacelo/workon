# claude — Claude Code inside the machine, so it can only touch the machine.
#
# "claude": {
#   "install":    true,                     // default true; installs to ~/.local/bin
#   "token_file": "~/path/token",           // default: config/claude-keys/<project>
#   "settings":   { "theme": "dark" },      // merged into the machine's ~/.claude/settings.json
#   "mcp":        { "<name>": { … } },      // user-scope MCP servers (no secrets here)
#   "mcp_file":   "~/path/mcp.json"         // Mac file: { "mcpServers": { … } } for servers with secrets
# }
# Re-applied on every run. A token or MCP server removed from the config is removed from the machine.
register_group claude

CLAUDE_KEYS_DIR="$CONFIG_DIR/claude-keys"   # one token file per project
CLAUDE_STATE=".config/workon"                # inside the machine user's home

claude::setup() {
  [[ "$(field claude.install true)" == "true" ]] || return 0
  CLAUDE_BIN="$VM_HOME/.local/bin/claude"
  claude_install
  claude_token
  claude_settings
  claude_mcp
}

claude_install() {
  if ! in_machine test -x "$CLAUDE_BIN"; then
    info "Installing Claude Code in the machine…"
    with_heartbeat "installing Claude Code" in_machine bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'
  fi
  # Cursor's terminal is a non-login shell, so PATH and the token go in ~/.bashrc.
  in_machine bash -c '
    grep -qF "/.local/bin:" ~/.bashrc || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc
    line="[ -f ~/'"$CLAUDE_STATE"'/claude.env ] && . ~/'"$CLAUDE_STATE"'/claude.env"
    grep -qxF "$line" ~/.bashrc || echo "$line" >> ~/.bashrc'
}

# The token is copied in, readable only by the machine user, and removed again when it's gone.
claude_token() {
  local tf token=""; tf="$(field claude.token_file "")"
  if [[ -z "$tf" ]]; then tf="$CLAUDE_KEYS_DIR/$P"; else tf="$(host_path "$tf")"; fi
  if [[ -f "$tf" ]]; then token="$(tr -d '[:space:]' < "$tf")"; fi
  if [[ -n "$token" ]]; then
    printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$token" |
      in_machine_stdin sh -c 'umask 077 && mkdir -p ~/'"$CLAUDE_STATE"' && cat > ~/'"$CLAUDE_STATE"'/claude.env'
    CLAUDE_HAS_TOKEN=1
    ok "Claude Code token installed"
  else
    warn "No Claude token in $tf — skipping (paste one from 'claude setup-token', or log in with 'claude' in the machine)"
    CLAUDE_HAS_TOKEN=""
    in_machine rm -f "$VM_HOME/$CLAUDE_STATE/claude.env"
  fi
}

# Settings, plus skipping the first-run login screen when a token is set.
claude_settings() {
  local patch
  patch="$(jq -cn --argjson s "$(field_json claude.settings '{}')" --arg tok "$CLAUDE_HAS_TOKEN" '
    {"~/.claude/settings.json": $s}
    + (if $tok == "1" then {"~/.claude.json": {hasCompletedOnboarding: true}} else {} end)')"
  [[ "$patch" == '{"~/.claude/settings.json":{}}' ]] || vm_merge_json <<<"$patch"
}

# MCP servers: inline "mcp" plus "mcp_file" (the file wins on name clashes).
claude_mcp() {
  local servers mf name json
  servers="$(field_json claude.mcp '{}')"
  mf="$(field claude.mcp_file "")"
  if [[ -n "$mf" ]]; then
    mf="$(host_path "$mf")"; [[ -f "$mf" ]] || die "MCP file not found: $mf"
    servers="$(jq -c --argjson a "$servers" '$a + (.mcpServers // {})' "$mf")" || die "MCP file is not valid JSON: $mf"
  fi
  # Remove servers workon added before that are no longer configured.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    jq -e --arg n "$name" 'has($n)' <<<"$servers" >/dev/null && continue
    info "Removing MCP server '$name'"
    in_machine "$CLAUDE_BIN" mcp remove -s user "$name" >/dev/null 2>&1 || true
  done < <(in_machine sh -c 'cat ~/'"$CLAUDE_STATE"'/mcp-servers 2>/dev/null || true')
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    json="$(jq -c --arg n "$name" '.[$n]' <<<"$servers")"
    in_machine "$CLAUDE_BIN" mcp remove -s user "$name" >/dev/null 2>&1 || true
    in_machine "$CLAUDE_BIN" mcp add-json -s user "$name" "$json" >/dev/null || die "Could not add MCP server '$name'"
    ok "MCP server '$name' configured"
  done < <(jq -r 'keys[]' <<<"$servers")
  jq -r 'keys[]' <<<"$servers" |
    in_machine_stdin sh -c 'mkdir -p ~/'"$CLAUDE_STATE"' && cat > ~/'"$CLAUDE_STATE"'/mcp-servers'
}
