# lifecycle.sh — the group registry and the phases every command runs through.
#
# A "group" is a top-level config key ("vm", "git", "claude", …) plus the module that handles
# it, in lib/groups/NN-<name>.sh. A module registers itself and defines a function per
# phase it cares about, named <group>::<phase>. Phases it doesn't define are skipped.
#
# Phases, in the order `workon <project>` runs them:
#   load       Read the group's settings into variables. Runs for every command, before the
#              machine is touched, so it must not talk to the machine.
#   attach     The machine is running: resolve paths inside it (VM_HOME is set).
#   provision  First run only (or --provision): one-time installs, usually as root.
#   setup      Every run and --sync: idempotent configuration. WORKON_SYNC=1 under --sync.
#   create     First run only, after setup: one-time project setup.
#   start      Every run, after setup.
#   open       Every run, last: open the editor.
#   down       `workon --down`. Runs in REVERSE group order, so teardown mirrors setup.
#              MACHINE_RUNNING=1 when the machine is up (it is never started just to stop it).
#
# Groups run in file-name order (10-vm, 20-workspace, …) within each phase.

WORKON_GROUPS=()

register_group() { WORKON_GROUPS+=("$1"); }

# run_phase <phase> [reverse]: call <group>::<phase> for every registered group that has one.
run_phase() {
  local phase="$1" order="${2:-}" i g
  if [[ "$order" == "reverse" ]]; then
    for (( i = ${#WORKON_GROUPS[@]} - 1; i >= 0; i-- )); do
      g="${WORKON_GROUPS[$i]}"
      if declare -F "$g::$phase" >/dev/null; then "$g::$phase"; fi
    done
  else
    for g in "${WORKON_GROUPS[@]}"; do
      if declare -F "$g::$phase" >/dev/null; then "$g::$phase"; fi
    done
  fi
}

# JSON array of group names, for the config resolver.
groups_json() { printf '%s\n' "${WORKON_GROUPS[@]}" | jq -R . | jq -sc .; }
