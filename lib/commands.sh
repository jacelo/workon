# commands.sh — the CLI. Each command is a cmd_<name> function; workon_main dispatches.

usage() {
  cat <<USAGE
workon — open a project in its own isolated OrbStack machine, in Cursor over Remote-SSH.

Usage:
  workon <project>            Create/start the machine, set it up, open Cursor
                              (full name like "acme.web", or just "web" if unique)
  workon -l | --list          List projects
  workon -s | --shell <p>     Open a shell in the machine, in the project folder
  workon -d | --down <p>      Close the project's Cursor window, run on_stop hooks, stop the machine
                              (nothing is deleted; "workon <p>" brings it back)
  workon --stop <p>           Stop the machine only
  workon --sync <p>           Re-apply settings and re-copy every "copy" entry (overwrites)
  workon --provision <p>      Re-run first-time installs and the on_create_root / on_create hooks
  workon --show <p>           Print the project's merged settings
  workon --init               Create config/workon.json from the example
  workon -e | --edit          Edit the config file
  workon -h | --help          Show this help

Config:  $CONFIG
Debug:   WORKON_DEBUG=1 workon <project>   (prints every command as it runs)
Docs:    $WORKON_ROOT/README.md
USAGE
}

need_arg() { [[ -n "${2:-}" ]] || die "Usage: workon $1 <project>"; }

# The full run: machine up, first-time setup if needed, settings, hooks, Cursor.
cmd_open() {
  load_project "$1"
  ensure_machine
  local fresh=0
  if ! is_provisioned; then
    fresh=1
    info "First-time setup: installing packages and tools (this can take several minutes)"
    run_phase provision
  else
    info "Machine already set up, skipping installs"
  fi
  run_phase setup
  if (( fresh )); then run_phase create; mark_provisioned; fi
  run_phase start
  run_phase open
  ok "Done in $(elapsed)"
}

cmd_shell() {
  load_project "$1"; ensure_machine
  exec orb -m "$MACHINE" -u "$USER_NAME" bash -lc 'cd "$1" 2>/dev/null; exec "${SHELL:-bash}" -l' _ "$PROJ_PATH"
}

cmd_sync() {
  load_project "$1"; ensure_machine
  WORKON_SYNC=1 run_phase setup
  ok "Synced"
}

cmd_provision() {
  load_project "$1"; ensure_machine
  info "Re-running first-time setup"
  run_phase provision; run_phase setup; run_phase create; mark_provisioned
  ok "Provisioned"
}

cmd_down() {
  load_project "$1"
  MACHINE_RUNNING=""
  if [[ "$(machine_state)" == "running" ]]; then MACHINE_RUNNING=1; attach_machine; fi
  run_phase down reverse
  if [[ -n "$MACHINE_RUNNING" ]]; then
    info "Stopping machine '$MACHINE'…"
    with_heartbeat "stopping machine" orb stop "$MACHINE"
    ok "Down in $(elapsed). Nothing was deleted — run 'workon $P' to bring it back."
  else
    ok "Machine '$MACHINE' is already stopped"
  fi
}

cmd_stop() {
  load_project "$1"
  orb stop "$MACHINE"; ok "Stopped '$MACHINE'"
}

cmd_show() {
  load_project "$1"
  jq --arg p "$P" '{project: $p} + .' <<<"$CFG"
}

cmd_init() {
  [[ -f "$CONFIG" ]] && die "Config already exists: $CONFIG"
  [[ -f "$EXAMPLE_CONFIG" ]] || die "Example config not found: $EXAMPLE_CONFIG"
  mkdir -p "$CONFIG_DIR/claude-keys"; chmod 700 "$CONFIG_DIR/claude-keys"
  cp "$EXAMPLE_CONFIG" "$CONFIG"
  ok "Created $CONFIG — edit it with 'workon --edit'"
}

workon_main() {
  case "${1:-}" in
    -h|--help) usage; return ;;
    --init)    cmd_init; return ;;
    "")        usage; if [[ -f "$CONFIG" ]]; then load_config; echo; list_projects; fi; return ;;
  esac
  load_config
  case "$1" in
    -l|--list)   list_projects ;;
    --names)     project_names ;;   # used by shell completion
    -e|--edit)   "${EDITOR:-nano}" "$CONFIG" ;;
    -s|--shell)  need_arg "$@"; cmd_shell "$2" ;;
    -d|--down)   need_arg "$@"; cmd_down "$2" ;;
    --stop)      need_arg "$@"; cmd_stop "$2" ;;
    --sync)      need_arg "$@"; cmd_sync "$2" ;;
    --provision) need_arg "$@"; cmd_provision "$2" ;;
    --show)      need_arg "$@"; cmd_show "$2" ;;
    -*)          die "Unknown option: $1 (see workon --help)" ;;
    *)           cmd_open "$1" ;;
  esac
}
