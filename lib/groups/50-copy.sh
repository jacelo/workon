# copy — one-way copies of Mac files and folders into the machine.
#
# "copy": [
#   "~/notes/todo.md",                                  // string: copied into the project folder
#   { "src": "~/acme/.env.local", "dest": ".env.local" },   // dest relative to the project folder
#   { "src": "~/acme/assets", "dest": "~/assets",           // ~ is the machine user's home
#     "sync": "always",                                 // "once" (default): only if dest is missing
#     "exclude": ["*.tmp"] }                            // folders only
# ]
# `workon --sync` re-copies every entry, overwriting what's in the machine.
register_group copy

copy::setup() {
  local entry src dest sync e excludes=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    src="$(jq -r 'if type=="string" then . else .src end' <<<"$entry")"
    dest="$(jq -r 'if type=="string" then "" else (.dest // "") end' <<<"$entry")"
    sync="$(jq -r 'if type=="string" then "once" else (.sync // "once") end' <<<"$entry")"
    excludes=()
    while IFS= read -r e; do [[ -n "$e" ]] && excludes+=("$e"); done \
      < <(jq -r 'if type=="object" then (.exclude // [])[] else empty end' <<<"$entry")

    src="$(host_path "$src")"
    [[ -e "$src" ]] || { warn "Copy source not found, skipping: $src"; continue; }
    if [[ -n "$dest" ]]; then dest="$(vm_path "$dest")"; else dest="$PROJ_PATH/$(basename "$src")"; fi

    if [[ "$sync" != "always" && -z "${WORKON_SYNC:-}" ]] && in_machine test -e "$dest"; then continue; fi
    info "Copying $src → $dest ($(du -sh "$src" | cut -f1))"
    if [[ -d "$src" ]]; then
      with_heartbeat "copying $(basename "$src")" push_dir "$src" "$dest" "${excludes[@]+"${excludes[@]}"}"
    else
      with_heartbeat "copying $(basename "$src")" push_file "$src" "$dest"
    fi
  done < <(jq -c '(.copy // [])[]' <<<"$CFG")
}
