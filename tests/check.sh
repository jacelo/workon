#!/usr/bin/env bash
# check.sh — fast checks that don't touch any machine. Run before committing changes.
#   tests/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKON="$ROOT/bin/workon"
EXAMPLE="$ROOT/config/workon.example.json"
fails=0
pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*"; fails=$((fails + 1)); }

# Every script parses with macOS's bash 3.2, which is what runs workon.
for f in "$WORKON" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT"/tests/*.sh "$ROOT"/lib/*.sh "$ROOT"/lib/groups/*.sh; do
  if /bin/bash -n "$f" 2>/dev/null; then pass "syntax: ${f#$ROOT/}"; else fail "syntax: ${f#$ROOT/}"; fi
done

if command -v shellcheck >/dev/null; then
  if shellcheck -x -s bash -e SC2016,SC1091 "$WORKON" "$ROOT"/lib/*.sh "$ROOT"/lib/groups/*.sh; then
    pass "shellcheck"
  else
    fail "shellcheck"
  fi
else
  echo "  (shellcheck not installed — skipped; brew install shellcheck)"
fi

# The example config is valid and resolves.
if jq empty "$EXAMPLE" 2>/dev/null; then pass "example config is valid JSON"; else fail "example config is not valid JSON"; fi

names="$(WORKON_CONFIG="$EXAMPLE" "$WORKON" --names)"
if [[ "$names" == $'acme.web\nsandbox' ]]; then pass "projects resolve: $(tr '\n' ' ' <<<"$names")"
else fail "projects resolve: got '$names'"; fi

# Inheritance: defaults → acme → acme.web.
show="$(WORKON_CONFIG="$EXAMPLE" "$WORKON" --show web)"
expect() { # expect <jq filter> <value> <label>
  local got; got="$(jq -r "$1" <<<"$show")"
  if [[ "$got" == "$2" ]]; then pass "$3"; else fail "$3 (got '$got', want '$2')"; fi
}
expect '.project'                    'acme.web'            "short name 'web' resolves to acme.web"
expect '.git.user'                   'Your Name'           "inherits defaults"
expect '.git.email'                  'you@acme.example'    "parent level overrides defaults"
expect '.git.repo'                   'git@github.com:acme/web.git' "project sets its own values"
expect '.claude.settings.theme'      'dark'                "objects merge deeply"
expect '.claude.mcp | keys | join(",")' 'docs'             "project adds to inherited objects"
expect '.vm.packages | length'       '8'                   "arrays are replaced, not appended"

# Every group module registered and every phase function is well formed.
groups="$(WORKON_CONFIG="$EXAMPLE" /bin/bash -c '
  set -euo pipefail; WORKON_ROOT="'"$ROOT"'"
  for m in core lifecycle config machine commands; do source "$WORKON_ROOT/lib/$m.sh"; done
  for m in "$WORKON_ROOT"/lib/groups/*.sh; do source "$m"; done
  echo "${WORKON_GROUPS[*]}"')"
if [[ "$groups" == "vm workspace git claude copy pull hooks cursor" ]]; then pass "groups load in order: $groups"
else fail "groups load in order: got '$groups'"; fi

# Pull safety rules: these decide what may come back from a machine onto the Mac.
pull_results="$(/bin/bash -c '
  set -euo pipefail; WORKON_ROOT="'"$ROOT"'"; WORKON_CONFIG="'"$EXAMPLE"'"
  for m in core lifecycle config machine commands; do source "$WORKON_ROOT/lib/$m.sh"; done
  for m in "$WORKON_ROOT"/lib/groups/*.sh; do source "$m"; done
  PULL_EXTS=$'"'"'md\ntxt'"'"'
  t() { if "$@" >/dev/null 2>&1; then echo "yes"; else echo "no"; fi; }
  echo "size $(parse_size 10M) $(parse_size 500k) $(parse_size 1024) $(t parse_size 10X)"
  echo "rel $(t pull_valid_rel notes/a.md dir) $(t pull_valid_rel ../x.md dir) $(t pull_valid_rel .vscode/x.md dir) $(t pull_valid_rel a/.hidden.md dir) $(t pull_valid_rel /etc/x.md dir) $(t pull_valid_rel "a"$'"'"'\n'"'"'"b.md" dir) $(t pull_valid_rel a//b.md dir) $(t pull_valid_rel . file) $(t pull_valid_rel x file)"
  echo "ext $(t pull_ext_allowed a/b.md) $(t pull_ext_allowed B.TXT) $(t pull_ext_allowed run.sh) $(t pull_ext_allowed README) $(t pull_ext_allowed x.md.app)"
  echo "classify $(pull_classify h1 h1 "") $(pull_classify h2 "" "") $(pull_classify h2 h1 "") $(pull_classify h2 h1 h1) $(pull_classify h1 h2 h1) $(pull_classify h3 h2 h1) $(pull_classify h1 "" h1) $(pull_classify h2 "" h1)"
')"
expect_line() { # expect_line <prefix> <want> <label>
  local got; got="$(grep "^$1 " <<<"$pull_results" | cut -d" " -f2-)"
  if [[ "$got" == "$2" ]]; then pass "$3"; else fail "$3 (got '$got', want '$2')"; fi
}
expect_line size     "10485760 512000 1024 no"                  "pull: sizes parse (10M, 500k, bytes; junk rejected)"
expect_line rel      "yes no no no no no no yes no"             "pull: unsafe, hidden and absolute names rejected"
expect_line ext      "yes yes no no no"                         "pull: only allowed extensions"
expect_line classify "unchanged new changed changed mac-newer conflict mac-deleted conflict" \
                                                                "pull: changes classified by which side changed"

if WORKON_CONFIG="$EXAMPLE" "$WORKON" nope >/dev/null 2>&1; then fail "unknown project is rejected"
else pass "unknown project is rejected"; fi

echo
if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo "All checks passed"
