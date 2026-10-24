# pull — bring changes from the machine back to the Mac, for copy entries with "pull": true.
#
# "pull": {
#   "extensions":    ["md", "txt"],   // file types allowed back onto the Mac (default: md, txt)
#   "no_extension":  false,           // also allow files with no extension ("Work log")
#   "max_file_size": "10M"            // optional; bytes or K/M/G. No limit by default
# }
# Set it in "defaults" for every project; a project can override it.
#
# This is the one exception to "nothing comes out of the machine", so it's deliberately narrow:
#   - Only `workon --pull` does it, never anything automatic.
#   - Files go to a staging folder first. You see every change and confirm before your Mac copy
#     is touched.
#   - Only regular files. From folder entries, only allowed extensions, and nothing in a hidden
#     folder or with a hidden name (.vscode, .git, …) or an unsafe name. A single-file entry names
#     its file in the config, so it may be any type. No symlinks or special files either way.
#   - Pulled files lose any executable bit and are marked as downloaded (quarantined), so macOS
#     checks them if they're ever opened as apps.
#   - Nothing on the Mac is deleted. Files changed on both sides are skipped and reported.
#   - Shown text is stripped of terminal control sequences.
#
# Remembered state (which version each file had when both sides last matched) lives on the Mac in
# ~/.local/state/workon/pull/<project>.tsv, written by copies (push) and pulls.
register_group pull

# Scan and apply lists use the 0x1f separator, not tabs: bash `read` merges empty tab fields.
PULL_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/workon/pull"

pull::load() {
  PULL_EXTS="$(field pull.extensions "" | sed 's/^\.//' | tr '[:upper:]' '[:lower:]')"
  [[ -n "$PULL_EXTS" ]] || PULL_EXTS=$'md\ntxt'
  PULL_NOEXT="$(field pull.no_extension false)"
  local raw; raw="$(field pull.max_file_size "")"
  PULL_MAX=""
  if [[ -n "$raw" ]]; then
    PULL_MAX="$(parse_size "$raw")" || die "Invalid pull.max_file_size: '$raw' (use bytes, or e.g. 500K, 10M, 1G)"
  fi
  PULL_STATE="$PULL_STATE_DIR/$P.tsv"
}

# parse_size <n[K|M|G][B]>: print bytes.
parse_size() {
  [[ "$1" =~ ^([0-9]+)([KkMmGg]?)[Bb]?$ ]] || return 1
  local n="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    K|k) n=$(( n * 1024 )) ;;
    M|m) n=$(( n * 1024 * 1024 )) ;;
    G|g) n=$(( n * 1024 * 1024 * 1024 )) ;;
  esac
  printf '%s' "$n"
}

# pull_valid_rel <rel> <file|dir>: is a path the machine reported safe to write under the entry?
pull_valid_rel() {
  local rel="$1"
  [[ "$2" == "file" ]] && { [[ "$rel" == "." ]]; return; }
  [[ -n "$rel" && "$rel" != /* && ${#rel} -le 1024 ]] || return 1
  [[ "$rel" != *[[:cntrl:]]* ]] || return 1
  case "/$rel/" in */.*|*//*) return 1 ;; esac   # hidden parts, "." / "..", empty parts
  return 0
}

# pull_ext_allowed <file name>
pull_ext_allowed() {
  local base; base="$(basename "$1")"
  if [[ "$base" != *.* ]]; then
    if [[ "${PULL_NOEXT:-false}" == "true" ]]; then return 0; fi
    return 1
  fi
  grep -qxF -- "$(tr '[:upper:]' '[:lower:]' <<<"${base##*.}")" <<<"$PULL_EXTS"
}

# Paths for one file of an entry. In file mode the rel path is ".".
pull_mac_file() { if [[ "$2" == "." ]]; then printf '%s' "$1"; else printf '%s/%s' "$1" "$2"; fi; }
pull_vm_file()  { if [[ "$2" == "." ]]; then printf '%s' "$1"; else printf '%s/%s' "$1" "$2"; fi; }

mac_hash() { if [[ -f "$1" ]]; then shasum -a 256 -- "$1" | cut -d' ' -f1; fi; }

pull_baseline() { # pull_baseline <src> <rel>
  [[ -f "$PULL_STATE" ]] || return 0
  awk -F'\t' -v s="$1" -v r="$2" '$1 == s && $2 == r {h = $3} END {if (h != "") print h}' "$PULL_STATE"
}

# pull_state_merge <tsv file of "src<TAB>rel<TAB>hash">: replace those entries in the state file.
pull_state_merge() {
  mkdir -p "$PULL_STATE_DIR"; chmod 700 "$PULL_STATE_DIR"
  touch "$PULL_STATE"
  awk -F'\t' 'NR == FNR {seen[$1 "\t" $2] = 1; next} !(($1 "\t" $2) in seen)' "$1" "$PULL_STATE" > "$PULL_STATE.tmp"
  cat "$1" >> "$PULL_STATE.tmp"
  mv "$PULL_STATE.tmp" "$PULL_STATE"
}

# pull_record_mac <src>: after a push, remember the Mac's allowed files as the matching version.
pull_record_mac() {
  local src="$1" tmp f rel
  temp_dir_into tmp
  if [[ -f "$src" ]]; then
    printf '%s\t.\t%s\n' "$src" "$(mac_hash "$src")" >> "$tmp/state"
  else
    while IFS= read -r -d '' f; do
      rel="${f#"$src"/}"
      pull_valid_rel "$rel" dir && pull_ext_allowed "$rel" || continue
      printf '%s\t%s\t%s\n' "$src" "$rel" "$(mac_hash "$f")" >> "$tmp/state"
    done < <(find "$src" -type f -print0)
  fi
  if [[ -s "$tmp/state" ]]; then pull_state_merge "$tmp/state"; fi
}

# ---------- reading the machine (its answers are untrusted and checked on the Mac) ----------

# pull_vm_list <dest> <file|dir>: NUL-separated "type<TAB>size<TAB>rel" records.
pull_vm_list() {
  if [[ "$2" == "dir" ]]; then
    in_machine sh -c 'cd "$1" 2>/dev/null || exit 0; find . -mindepth 1 -printf "%y\t%s\t%P\0"' _ "$1"
  else
    in_machine sh -c '[ -e "$1" ] || [ -L "$1" ] || exit 0; find "$1" -maxdepth 0 -printf "%y\t%s\t.\0"' _ "$1"
  fi
}

# pull_vm_hashes <dest> <file|dir> < NUL-separated rel list: "rel<TAB>hash" lines for valid names.
pull_vm_hashes() {
  local dest="$1" mode="$2" rec hash name
  if [[ "$mode" == "file" ]]; then
    hash="$(in_machine sh -c 'sha256sum -- "$1" 2>/dev/null | cut -d" " -f1' _ "$dest")"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] && printf '.\t%s\n' "$hash"
    return 0
  fi
  while IFS= read -r -d '' rec; do
    hash="${rec%%  *}"; name="${rec#*  }"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] && pull_valid_rel "$name" dir || continue
    printf '%s\t%s\n' "$name" "$hash"
  done < <(in_machine_stdin sh -c 'cd "$1" && xargs -0 -r sha256sum -z --' _ "$dest")
}

# pull_scan <src> <dest> <out>: classify the machine's files for one entry, without fetching.
# Writes "<status><TAB><rel><TAB><vm hash><TAB><mac hash><TAB><note>" lines, where status is
# new | changed | unchanged | conflict | mac-newer | mac-deleted | skip.
pull_scan() {
  local src="$1" dest="$2" out="$3" mode=dir rec type size rel vmh mach base tmp
  if [[ -f "$src" ]] || { [[ ! -e "$src" ]] && ! in_machine test -d "$dest"; }; then mode=file; fi
  temp_dir_into tmp
  : > "$out"; : > "$tmp/names"
  while IFS= read -r -d '' rec; do
    type="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
    size="${rec%%$'\t'*}"; rel="${rec#*$'\t'}"
    [[ "$type" == "d" ]] && continue
    if ! pull_valid_rel "$rel" "$mode"; then
      printf 'skip\037%s\037\037\037unsafe or hidden name\n' "$(printf '%s' "$rel" | tr -d '[:cntrl:]' | cut -c1-80)" >> "$out"; continue
    fi
    local shown; shown="$(pull_mac_file "$src" "$rel")"
    if [[ "$type" != "f" ]]; then printf 'skip\037%s\037\037\037not a regular file\n' "$rel" >> "$out"; continue; fi
    # A single-file entry names its file in your config, so the machine can't choose what lands
    # on the Mac; the extension list only filters the files a folder entry brings back.
    if [[ "$mode" == "dir" ]] && ! pull_ext_allowed "$shown"; then printf 'skip\037%s\037\037\037file type not allowed\n' "$rel" >> "$out"; continue; fi
    if [[ -n "$PULL_MAX" && "$size" =~ ^[0-9]+$ ]] && (( size > PULL_MAX )); then
      printf 'skip\037%s\037\037\037larger than pull.max_file_size\n' "$rel" >> "$out"; continue
    fi
    printf '%s\0' "$rel" >> "$tmp/names"
  done < <(pull_vm_list "$dest" "$mode")

  pull_vm_hashes "$dest" "$mode" < "$tmp/names" > "$tmp/hashes"
  while IFS= read -r -d '' rel; do
    vmh="$(awk -F'\t' -v r="$rel" '$1 == r {print $2; exit}' "$tmp/hashes")"
    if [[ -z "$vmh" ]]; then printf 'skip\037%s\037\037\037could not read it\n' "$rel" >> "$out"; continue; fi
    mach="$(mac_hash "$(pull_mac_file "$src" "$rel")")"
    base="$(pull_baseline "$src" "$rel")"
    printf '%s\037%s\037%s\037%s\037\n' "$(pull_classify "$vmh" "$mach" "$base")" "$rel" "$vmh" "$mach" >> "$out"
  done < "$tmp/names"

  # Allowed files that exist only on the Mac are reported, never deleted.
  if [[ "$mode" == "dir" && -d "$src" ]]; then
    while IFS= read -r -d '' rec; do
      rel="${rec#"$src"/}"
      pull_valid_rel "$rel" dir && pull_ext_allowed "$rel" || continue
      grep -qF -- "$(printf '\037%s\037' "$rel")" "$out" && continue
      printf 'mac-only\037%s\037\037\037only on your Mac (kept)\n' "$rel" >> "$out"
    done < <(find "$src" -type f -print0)
  fi
}

# pull_classify <machine hash> <mac hash> <hash when both last matched>
pull_classify() {
  local vmh="$1" mach="$2" base="$3"
  if [[ "$vmh" == "$mach" ]]; then echo unchanged
  elif [[ -z "$mach" ]]; then
    if [[ -z "$base" ]]; then echo new
    elif [[ "$vmh" == "$base" ]]; then echo mac-deleted
    else echo conflict; fi
  elif [[ -z "$base" || "$mach" == "$base" ]]; then echo changed
  elif [[ "$vmh" == "$base" ]]; then echo mac-newer
  else echo conflict; fi
}

# pull_machine_ahead <src> <dest>: true if the machine has changes the Mac doesn't (used by --sync).
# Sets PULL_AHEAD to a short list of the files involved.
pull_machine_ahead() {
  local tmp; temp_dir_into tmp
  pull_scan "$1" "$2" "$tmp/scan"
  PULL_AHEAD="$(grep -E '^(new|changed|conflict)'$'\037' "$tmp/scan" | cut -d $'\037' -f1,2 |
    awk -F $'\037' '{printf "%s%s (%s)", (NR > 1 ? ", " : ""), $2, $1} NR == 5 {printf ", …"; exit}')"
  [[ -n "$PULL_AHEAD" ]]
}

# ---------- the --pull command ----------

pull_run() {
  local stage n=0 entry status rel vmh mach note f staged size applied=0 total=0
  temp_dir_into stage
  local -a srcs=() dests=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    copy_resolve "$entry"
    [[ -n "$C_PULL" ]] || continue
    n=$((n + 1)); srcs+=("$C_SRC"); dests+=("$C_DEST")
  done < <(copy_entries)
  (( n )) || { info "No copy entries have \"pull\": true — nothing to pull."; return 0; }

  : > "$stage/apply"; : > "$stage/state"
  local i
  for (( i = 0; i < n; i++ )); do
    local src="${srcs[$i]}" dest="${dests[$i]}"
    info "Checking $dest → $src"
    pull_scan "$src" "$dest" "$stage/scan.$i"

    # Fetch new and changed files into staging, then re-check them on the Mac.
    while IFS=$'\037' read -r status rel vmh mach note; do
      case "$status" in new|changed) ;; *) continue ;; esac
      staged="$stage/files.$i/$rel"; [[ "$rel" == "." ]] && staged="$stage/files.$i/.file"
      mkdir -p "$(dirname "$staged")"
      if [[ -n "$PULL_MAX" ]]; then
        in_machine cat -- "$(pull_vm_file "$dest" "$rel")" | head -c $(( PULL_MAX + 1 )) > "$staged" || true
      else
        in_machine cat -- "$(pull_vm_file "$dest" "$rel")" > "$staged" || true
      fi
      size="$(wc -c < "$staged" | tr -d ' ')"
      if [[ -n "$PULL_MAX" ]] && (( size > PULL_MAX )); then
        rm -f "$staged"; printf 'skip\037%s\037\037\037larger than pull.max_file_size\n' "$rel" >> "$stage/scan.$i.final"; continue
      fi
      vmh="$(mac_hash "$staged")"
      if [[ "$vmh" == "$mach" ]]; then status=unchanged; fi
      printf '%s\037%s\037%s\037%s\037%s\n' "$status" "$rel" "$vmh" "$mach" "$note" >> "$stage/scan.$i.final"
    done < "$stage/scan.$i"
    grep -vE '^(new|changed)'$'\037' "$stage/scan.$i" >> "$stage/scan.$i.final" || true

    pull_review "$src" "$i" "$stage"
  done

  total="$(wc -l < "$stage/apply" | tr -d ' ')"
  if (( total == 0 )); then
    [[ -s "$stage/state" ]] && pull_state_merge "$stage/state"
    ok "Nothing to pull — your Mac is up to date."
    return 0
  fi
  echo
  local answer=""
  if ! { : </dev/tty; } 2>/dev/null; then
    [[ -s "$stage/state" ]] && pull_state_merge "$stage/state"
    warn "No terminal to confirm in, so nothing was applied. Run workon --pull in a terminal."
    return 0
  fi
  read -r -p "Apply these $total file(s) to your Mac? [y/N] " answer </dev/tty || true
  if [[ "$answer" != [yY] && "$answer" != [yY][eE][sS] ]]; then
    [[ -s "$stage/state" ]] && pull_state_merge "$stage/state"
    info "Nothing applied."
    return 0
  fi

  local src file stamp; stamp="$(printf '%x' "$(date +%s)")"
  while IFS=$'\037' read -r src rel staged vmh; do
    file="$(pull_mac_file "$src" "$rel")"
    mkdir -p "$(dirname "$file")"
    if [[ -f "$file" ]]; then
      cat "$staged" > "$file"          # keeps the existing file's permissions
    else
      (umask 022; cat "$staged" > "$file"); chmod 644 "$file"
    fi
    chmod a-x "$file"
    xattr -w com.apple.quarantine "0081;$stamp;workon;" "$file" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$src" "$rel" "$vmh" >> "$stage/state"
    applied=$((applied + 1))
  done < "$stage/apply"
  pull_state_merge "$stage/state"
  ok "Pulled $applied file(s)."
}

# pull_review <src> <index> <stage>: show one entry's results and queue its files.
pull_review() {
  local src="$1" i="$2" stage="$3" status rel vmh mach note staged file count
  local scan="$stage/scan.$i.final"
  [[ -f "$scan" ]] || return 0
  echo
  printf '\033[1m%s\033[0m\n' "$src"

  # Matching files are recorded as in sync.
  while IFS=$'\037' read -r status rel vmh mach note; do
    [[ "$status" == "unchanged" ]] && printf '%s\t%s\t%s\n' "$src" "$rel" "$vmh" >> "$stage/state"
  done < "$scan"

  for status in new changed; do
    while IFS=$'\037' read -r s rel vmh mach note; do
      [[ "$s" == "$status" ]] || continue
      staged="$stage/files.$i/$rel"; [[ "$rel" == "." ]] && staged="$stage/files.$i/.file"
      file="$(pull_mac_file "$src" "$rel")"
      if [[ "$status" == "new" ]]; then
        printf '  \033[32m+ new\033[0m      %s\n' "$rel"
        head -n 15 "$staged" | sanitize | sed 's/^/      │ /'
        count="$(wc -l < "$staged" | tr -d ' ')"
        (( count > 15 )) && printf '      │ … %s more lines\n' $(( count - 15 ))
      else
        printf '  \033[33m~ changed\033[0m  %s\n' "$rel"
        # diff exits 1 when the files differ, which pipefail would treat as an error.
        { diff -u "$file" "$staged" 2>/dev/null || true; } | tail -n +3 | sanitize | head -n 40 | sed 's/^/      │ /'
        count="$({ diff -u "$file" "$staged" 2>/dev/null || true; } | wc -l | tr -d ' ')"
        (( count > 42 )) && printf '      │ … diff continues (%s lines)\n' $(( count - 2 ))
      fi
      printf '%s\037%s\037%s\037%s\n' "$src" "$rel" "$staged" "$vmh" >> "$stage/apply"
    done < "$scan"
  done

  # Files of types you haven't allowed are expected, so they're summarized in one line.
  local others
  others="$(awk -F $'\037' '$1 == "skip" && $5 == "file type not allowed" {
      n++; e = $2; if (e ~ /\.[^.\/]+$/) { sub(/.*\./, "", e); e = tolower(e) } else e = "no extension"; c[e]++ }
    END { if (n) { s = ""; for (k in c) s = s (s == "" ? "" : ", ") c[k] " " k
                   printf "%d file(s) of types not in pull.extensions: %s", n, s } }' "$scan")"
  if [[ -n "$others" ]]; then printf '  \033[2m- skipped\033[0m    %s\n' "$others"; fi

  local label
  while IFS=$'\037' read -r status rel vmh mach note; do
    [[ "$status" == "skip" && "$note" == "file type not allowed" ]] && continue
    case "$status" in
      conflict)    label='\033[31m! conflict\033[0m   %s — changed on both sides, skipped\n' ;;
      mac-newer)   label='\033[2m· mac newer\033[0m  %s — push it with workon --sync\n' ;;
      mac-deleted) label='\033[2m· deleted\033[0m    %s — deleted on your Mac, left deleted\n' ;;
      mac-only)    label='\033[2m· mac only\033[0m   %s — kept\n' ;;
      skip)        label="\033[2m- skipped\033[0m    %s — $note\n" ;;
      *) continue ;;
    esac
    # shellcheck disable=SC2059
    printf "  $label" "$rel"
  done < "$scan"

  if ! grep -qvE '^(unchanged)'$'\037' "$scan"; then echo "  no changes"; fi
}
