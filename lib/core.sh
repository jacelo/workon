# core.sh — output, timing and path helpers shared by every module.
# Must stay compatible with macOS's /bin/bash 3.2: no associative arrays, mapfile, or ${x,,}.

START=$SECONDS

die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }

# elapsed [since]: m:ss since the start of the run (or since a given $SECONDS value).
elapsed() { local s=$(( SECONDS - ${1:-$START} )); printf '%d:%02d' $((s / 60)) $((s % 60)); }

info() { printf '\033[2m[%s]\033[0m \033[36m→\033[0m %s\n' "$(elapsed)" "$*"; }
ok()   { printf '\033[2m[%s]\033[0m \033[32m✓\033[0m %s\n' "$(elapsed)" "$*"; }

# with_heartbeat <label> <cmd...>: run one command, printing a "still working" line every 20s
# so long, quiet steps don't look hung. Wrap a single command, not a multi-step function:
# set -e is off inside the wrapped command.
with_heartbeat() {
  local label="$1" t0=$SECONDS rc=0 hb; shift
  ( while sleep 20; do printf '\033[2m        … still %s (%s)\033[0m\n' "$label" "$(elapsed "$t0")" >&2; done ) &
  hb=$!
  "$@" || rc=$?
  kill "$hb" 2>/dev/null; wait "$hb" 2>/dev/null || true
  return "$rc"
}
# On exit: stop heartbeats and delete temporary paths registered with temp_dir.
CLEANUP_PATHS=()
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}"' EXIT

# temp_dir_into <var>: create a private temporary folder, deleted when workon exits, and store
# its path in <var>. (Not `$(…)`: the cleanup list must be updated in this shell.)
temp_dir_into() {
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/workon.XXXXXX")" || die "Couldn't create a temporary folder"
  CLEANUP_PATHS+=("$d")
  eval "$1=\$d"
}

# sanitize: strip terminal control sequences from untrusted text before showing it.
# Keeps tabs and newlines. Removes ASCII controls (incl. ESC) and UTF-8 encoded C1 controls.
sanitize() { LC_ALL=C sed -e $'s/[\x01-\x08\x0b-\x1f\x7f]//g' -e $'s/\xc2[\x80-\x9f]//g'; }

# indent: prefix each line with the preview gutter. LC_ALL=C so bytes that aren't valid UTF-8 don't make sed fail.
indent() { LC_ALL=C sed 's/^/      │ /'; }

# is_binary <file>: true if the file looks binary (a NUL byte in its first 8000 bytes, as git checks).
is_binary() { [[ -s "$1" ]] && (( $(head -c 8000 "$1" | LC_ALL=C tr -dc '\000' | wc -c) > 0 )); }

# host_path <path>: expand ~ on the Mac. Host paths must be absolute or start with ~.
host_path() {
  case "$1" in
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1:2}" ;;
    /*)    printf '%s' "$1" ;;
    *)     die "Host path must be absolute or start with ~: $1" ;;
  esac
}

# vm_path <path>: expand a path inside the machine. ~ → VM home, relative → project dir.
# Needs VM_HOME (set when the machine is attached) and PROJ_PATH for relative paths.
vm_path() {
  case "$1" in
    "~")   printf '%s' "$VM_HOME" ;;
    "~/"*) printf '%s/%s' "$VM_HOME" "${1:2}" ;;
    /*)    printf '%s' "$1" ;;
    *)     printf '%s/%s' "$PROJ_PATH" "$1" ;;
  esac
}

require_cmd() { # require_cmd <command> <message>
  command -v "$1" >/dev/null || die "$2"
}
