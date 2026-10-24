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
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT

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
