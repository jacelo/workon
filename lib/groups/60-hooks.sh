# hooks — your own shell commands, run in the machine at points in the lifecycle.
#
# "hooks": {
#   "on_create_root": ["…"],   // first run, as root, before the repo is cloned. $WORKON_USER = machine user
#   "on_create":      ["…"],   // first run, after clone and copies
#   "on_start":       ["…"],   // every `workon <project>`, before Cursor opens
#   "on_stop":        ["…"]    // `workon --down`, after Cursor closes, before the machine stops
# }
# Commands run with bash -lc. All but on_create_root run as the machine user from the project
# folder. A failing command stops workon, except in on_stop (the machine still stops).
#
# To add a hook: pick a lifecycle phase (see lifecycle.sh), then add a function below.
register_group hooks

hooks::provision() { run_hooks on_create_root root; }
hooks::create()    { run_hooks on_create; }
hooks::start()     { run_hooks on_start; }
hooks::down() {
  [[ -n "${MACHINE_RUNNING:-}" ]] || return 0
  ( run_hooks on_stop ) || warn "An on_stop command failed; continuing"
}

# run_hooks <key> [root]: run each command in hooks.<key>.
run_hooks() {
  local key="$1" as="${2:-}" cmd t0
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    t0=$SECONDS
    if [[ "$as" == "root" ]]; then
      info "Running as root: $cmd"
      with_heartbeat "running: ${cmd:0:50}" as_root env WORKON_USER="$USER_NAME" bash -lc "set -e; $cmd" ||
        die "Command failed ($key): $cmd"
    else
      info "Running: $cmd"
      with_heartbeat "running: ${cmd:0:50}" in_machine bash -lc "cd \"\$1\" && $cmd" _ "$PROJ_PATH" ||
        die "Command failed ($key): $cmd"
    fi
    ok "Finished in $(elapsed "$t0"): $cmd"
  done < <(field "hooks.$key" "")
}
