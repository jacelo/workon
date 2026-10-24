# copy — copies of Mac files and folders into the machine. One-way, unless an entry opts in to
# pulling changes back with "pull": true (see 55-pull.sh and `workon --pull`).
#
# "copy": [
#   "~/notes/todo.md",                                  // string: copied into the project folder
#   { "src": "~/acme/.env.local", "dest": ".env.local" },   // dest relative to the project folder
#   { "src": "~/acme/assets", "dest": "~/assets",           // ~ is the machine user's home
#     "sync": "always",                                 // "once" (default): only if dest is missing
#     "exclude": ["*.tmp"] },                           // folders only
#   { "src": "~/acme/docs", "dest": "~/docs",
#     "pull": true }                                    // `workon --pull` brings changes back
# ]
# `workon --sync` re-copies every entry, overwriting what's in the machine. For "pull" entries it
# first checks that the machine has no changes you haven't pulled, and skips the entry if it does.
register_group copy

# copy_resolve <entry json>: set C_SRC, C_DEST, C_SYNC, C_PULL and C_EXCLUDES for one entry.
copy_resolve() {
  local entry="$1" e
  C_SRC="$(host_path "$(jq -r 'if type=="string" then . else .src end' <<<"$entry")")"
  C_DEST="$(jq -r 'if type=="string" then "" else (.dest // "") end' <<<"$entry")"
  C_SYNC="$(jq -r 'if type=="string" then "once" else (.sync // "once") end' <<<"$entry")"
  C_PULL="$(jq -r 'if type=="object" and .pull == true then 1 else "" end' <<<"$entry")"
  C_EXCLUDES=()
  while IFS= read -r e; do [[ -n "$e" ]] && C_EXCLUDES+=("$e"); done \
    < <(jq -r 'if type=="object" then (.exclude // [])[] else empty end' <<<"$entry")
  if [[ -n "$C_DEST" ]]; then C_DEST="$(vm_path "$C_DEST")"; else C_DEST="$PROJ_PATH/$(basename "$C_SRC")"; fi
  if [[ -n "$C_PULL" && "$C_SYNC" == "always" ]]; then
    die "Copy entry $C_SRC has \"pull\": true and \"sync\": \"always\" — that would overwrite the machine's changes on every run. Use \"once\"."
  fi
}

copy_entries() { jq -c '(.copy // [])[]' <<<"$CFG"; }

copy::setup() {
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    copy_resolve "$entry"
    [[ -e "$C_SRC" ]] || { warn "Copy source not found, skipping: $C_SRC"; continue; }

    if [[ "$C_SYNC" != "always" && -z "${WORKON_SYNC:-}" ]] && in_machine test -e "$C_DEST"; then continue; fi
    if [[ -n "$C_PULL" && -n "${WORKON_SYNC:-}" ]] && in_machine test -e "$C_DEST" && pull_machine_ahead "$C_SRC" "$C_DEST"; then
      warn "Skipped $C_SRC: the machine has changes your Mac doesn't: $PULL_AHEAD"
      warn "  Run 'workon --pull $P' to bring them over. For a conflict, make both copies the same first."
      continue
    fi

    info "Copying $C_SRC → $C_DEST ($(du -sh "$C_SRC" | cut -f1))"
    if [[ -d "$C_SRC" ]]; then
      with_heartbeat "copying $(basename "$C_SRC")" push_dir "$C_SRC" "$C_DEST" "${C_EXCLUDES[@]+"${C_EXCLUDES[@]}"}"
    else
      with_heartbeat "copying $(basename "$C_SRC")" push_file "$C_SRC" "$C_DEST"
    fi
    # Both sides now match: remember it, so a later pull can tell who changed what.
    if [[ -n "$C_PULL" ]]; then pull_record_mac "$C_SRC"; fi
  done < <(copy_entries)
}
