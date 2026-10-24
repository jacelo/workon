# config.sh — load workon.json, resolve inheritance, and read project settings.
#
# Layout: "projects" is a tree (e.g. acme → web). Group keys (see WORKON_GROUPS) can appear at
# any level; a node with no child nodes is a project, named by its dotted path ("acme.web").
# Settings merge deep: "defaults" → each parent level → the project. Arrays are replaced, not
# appended, so a project's "hooks.on_create" list replaces the defaults' list.

CONFIG="${WORKON_CONFIG:-$WORKON_ROOT/config/workon.json}"
CONFIG_DIR="$(dirname "$CONFIG")"
EXAMPLE_CONFIG="$WORKON_ROOT/config/workon.example.json"

RESOLVE_JQ='
def isgroup: . as $k | $groups | index($k) != null;
def own:  with_entries(select(.key | isgroup));
def kids: with_entries(select((.key | isgroup | not) and (.value | type == "object")));
def walkp($acc; $path):
  ($acc * own) as $m | kids as $k |
  if ($k | length) == 0 then {key: ($path | join(".")), value: $m}
  else $k | to_entries[] | .key as $n | .value | walkp($m; $path + [$n]) end;
(.defaults // {}) as $d
| [(.projects // {}) | to_entries[] | .key as $n | .value | walkp($d; [$n])] | from_entries'

# load_config: parse the config once into ALL ({"<project>": <merged settings>}).
load_config() {
  require_cmd jq "jq is required (brew install jq)"
  [[ -f "$CONFIG" ]] || die "Config not found: $CONFIG — run 'workon --init' to create one from the example"
  jq empty "$CONFIG" 2>/dev/null || die "Config is not valid JSON: $CONFIG"
  ALL="$(jq -c --argjson groups "$(groups_json)" "$RESOLVE_JQ" "$CONFIG")" ||
    die "Could not read projects from $CONFIG"
}

# field <group.key> [fallback]: a value from the current project's merged settings.
# Arrays print one item per line; booleans print true/false.
field() {
  jq -r --arg k "$1" --arg d "${2:-}" '
    getpath($k | split(".")) as $v | (if $v == null then $d else $v end)
    | if type=="array" then .[] elif type=="boolean" then tostring else . end' <<<"$CFG"
}

# field_json <group.key> [fallback-json]: the raw JSON value (for objects).
field_json() {
  jq -c --arg k "$1" --argjson d "${2:-null}" 'getpath($k | split(".")) // $d' <<<"$CFG"
}

machine_default() { tr '.' '-' <<<"$1"; }   # acme.web → acme-web

project_names() { jq -r 'keys[]' <<<"$ALL"; }

list_projects() {
  jq -r 'to_entries[] | [.key, (.value.vm.name // (.key | gsub("\\."; "-"))), (.value.git.repo // "-")] | @tsv' <<<"$ALL" |
    awk -F'\t' 'BEGIN{printf "%-24s %-24s %s\n","PROJECT","MACHINE","REPO"} {printf "%-24s %-24s %s\n",$1,$2,$3}'
}

# resolve_name <query>: accept the full name ("acme.web") or a unique last part ("web").
resolve_name() {
  local matches
  matches="$(jq -r --arg q "$1" 'keys[] | select(. == $q or endswith("." + $q))' <<<"$ALL")"
  if grep -qx -- "$1" <<<"$matches"; then echo "$1"; return; fi
  case "$(grep -c . <<<"$matches")" in
    1) echo "$matches" ;;
    0) echo "Unknown project '$1'. Available:" >&2; list_projects >&2; exit 1 ;;
    *) die "'$1' matches several projects: $(tr '\n' ' ' <<<"$matches")— use the full name" ;;
  esac
}

# load_project <query>: select a project and run every group's load phase.
load_project() {
  P="$(resolve_name "$1")"
  CFG="$(jq -c --arg p "$P" '.[$p]' <<<"$ALL")"
  run_phase load
}
