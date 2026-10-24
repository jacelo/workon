# machine.sh — the project's OrbStack machine: running commands in it, its lifecycle, the
# isolation checks, and one-way copies into it.
#
# Security model: data only flows Mac → machine.
#   - Machines are created with --isolated (no shared folders, no `mac` command, no host
#     integration). Existing machines that aren't isolated are refused.
#   - Network isolation (--isolate-network) is on by default: the machine can reach the
#     internet but not your Mac's IPs or other machines.
#   - Files are copied in by piping tar/cat over stdin. Nothing is read back out of the
#     machine onto the Mac, and no Mac folders are mounted.
#
# The machine's settings (MACHINE, USER_NAME, DISTRO, …) come from the "vm" group's load phase.

MARKER_DIR=".local/state/workon"   # inside the machine user's home

# Run a command in the machine. stdin is closed unless you use in_machine_stdin.
in_machine()       { orb -m "$MACHINE" -u "$USER_NAME" "$@" </dev/null; }
in_machine_stdin() { orb -m "$MACHINE" -u "$USER_NAME" "$@"; }
as_root()          { orb -m "$MACHINE" -u root "$@" </dev/null; }

machine_state() { orb list 2>/dev/null | awk -v m="$MACHINE" '$1==m {print $2}'; }
machine_cfg()   { orbctl config show 2>/dev/null | awk -v k="machine.$MACHINE.$1:" '$1==k {sub(/^[^:]*: ?/,""); print}'; }

create_machine() {
  info "Creating isolated machine '$MACHINE' ($DISTRO)…"
  local args=(create --isolated -u "$USER_NAME")
  [[ "$ISOLATE_NET" == "true" ]] && args+=(--isolate-network)
  [[ -n "$ARCH"   ]] && args+=(-a "$ARCH")
  [[ -n "$CPUS"   ]] && args+=(--cpus "$CPUS")
  [[ -n "$MEMORY" ]] && args+=(--memory "$MEMORY")
  [[ -n "$DISK"   ]] && args+=(--disk "$DISK")
  with_heartbeat "creating machine" orb "${args[@]}" "$DISTRO" "$MACHINE"
}

# Refuse to work in a machine that could touch the Mac.
check_isolation() {
  [[ "$(machine_cfg isolated)" == "true" ]] ||
    die "Machine '$MACHINE' is NOT isolated (it can see your Mac's files). Recreate it: orb delete $MACHINE && workon $P"
  [[ -z "$(machine_cfg mounts)" ]] ||
    die "Machine '$MACHINE' has Mac folders mounted ($(machine_cfg mounts)). Remove them in OrbStack settings."
  [[ "$(machine_cfg forward_ssh_agent)" != "true" ]] ||
    die "Machine '$MACHINE' has SSH agent forwarding on, which lets it use your Mac's keys. Turn it off: orbctl config set machine.$MACHINE.forward_ssh_agent false"
  if [[ "$ISOLATE_NET" == "true" && "$(machine_cfg isolate_network)" != "true" ]]; then
    warn "Machine '$MACHINE' can reach your Mac over the network. To block it: orbctl config set machine.$MACHINE.isolate_network true"
  fi
}

# attach_machine: the machine is running — set VM_HOME and run every group's attach phase.
attach_machine() {
  VM_HOME="$(in_machine sh -c 'printf %s "$HOME"')"
  run_phase attach
}

# ensure_machine: create or start the machine, check isolation, then attach.
ensure_machine() {
  require_cmd orb "OrbStack's 'orb' CLI not found — install OrbStack from https://orbstack.dev"
  local state; state="$(machine_state)"
  if [[ -z "$state" ]]; then
    create_machine
  elif [[ "$state" != "running" ]]; then
    info "Starting machine '$MACHINE'…"
    with_heartbeat "starting machine" orb start "$MACHINE"
  fi
  check_isolation
  ok "Machine '$MACHINE' is running (isolated)"
  attach_machine
}

is_provisioned()   { in_machine test -f "$VM_HOME/$MARKER_DIR/$P.provisioned"; }
mark_provisioned() { in_machine sh -c 'mkdir -p "$1" && date > "$1/$2.provisioned"' _ "$VM_HOME/$MARKER_DIR" "$P"; }

# install_packages <pkg...>: as root, with whatever package manager the machine has.
install_packages() {
  (( $# )) || return 0
  info "Installing packages: $*"
  with_heartbeat "installing packages" as_root sh -c '
    set -e
    if   command -v apt-get >/dev/null; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v dnf     >/dev/null; then dnf install -y "$@"
    elif command -v apk     >/dev/null; then apk add --no-cache "$@"
    elif command -v pacman  >/dev/null; then pacman -Sy --noconfirm --needed "$@"
    elif command -v zypper  >/dev/null; then zypper -n install "$@"
    else echo "No supported package manager found" >&2; exit 1; fi' _ "$@"
}

# ---------- one-way copies (Mac → machine only) ----------

# push_file <mac_src> <vm_dest> [mode]: copy one file, keeping its permissions unless given.
push_file() {
  local mode="${3:-}"
  [[ -n "$mode" ]] || mode="$(stat -f %Lp "$1")"
  in_machine_stdin sh -c 'mkdir -p "$(dirname "$1")" && cat > "$1" && chmod "$2" "$1"' _ "$2" "$mode" < "$1"
}

# push_dir <mac_src> <vm_dest> [exclude...]: copy a folder's contents.
push_dir() {
  local src="$1" dest="$2"; shift 2
  local ex=(--exclude .DS_Store --exclude '._*') e
  for e in "$@"; do ex+=(--exclude "$e"); done
  COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$src" "${ex[@]}" -cf - . |
    in_machine_stdin sh -c 'mkdir -p "$1" && tar -xf - -C "$1" --no-same-owner 2>&1 | grep -v "unknown extended header" >&2 || true' _ "$dest"
}

# vm_merge_json: read {"<vm path>": {…}} on stdin and merge each object into that JSON file
# in the machine (top-level keys only). Needs python3 in the machine.
vm_merge_json() {
  in_machine sh -c 'command -v python3' >/dev/null || die "python3 is needed in the machine to edit JSON settings"
  in_machine_stdin python3 -c '
import json, os, sys
for path, patch in json.load(sys.stdin).items():
    p = os.path.expanduser(path)
    try:
        with open(p) as f: cur = json.load(f)
    except FileNotFoundError:
        cur = {}
    cur.update(patch)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".workon.tmp", "w") as f: json.dump(cur, f, indent=2)
    os.replace(p + ".workon.tmp", p)'
}
