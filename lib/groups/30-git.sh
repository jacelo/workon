# git — identity, deploy key, and cloning the repo into the workspace path.
#
# "git": {
#   "user":    "Your Name",
#   "email":   "you@example.com",
#   "repo":    "git@github.com:acme/web.git",   // optional: cloned on first run
#   "branch":  "main",                          // optional
#   "ssh_key": "~/.ssh/acme-github"             // optional: copied in, used only by this repo
# }
# Without "repo", the workspace folder is just created.
register_group git

git::load() {
  REPO="$(field git.repo "")"
  BRANCH="$(field git.branch "")"
  SSH_KEY="$(field git.ssh_key "")"
  GIT_USER="$(field git.user "")"
  GIT_EMAIL="$(field git.email "")"
  GIT_SSH=""
}

git::setup() {
  git_ensure_tools
  git_configure_identity
  git_install_ssh_key
  git_ensure_project_dir
}

git_ssh_client_pkg() {
  as_root sh -c 'command -v apt-get >/dev/null && echo openssh-client && exit
                 command -v dnf >/dev/null || command -v zypper >/dev/null && echo openssh-clients && exit
                 command -v pacman >/dev/null && echo openssh && exit
                 echo openssh-client'
}

# Make sure git (and ssh, for git@ URLs) exist when they're needed.
git_ensure_tools() {
  [[ -n "$REPO$GIT_USER$GIT_EMAIL" ]] || return 0
  local need=()
  in_machine sh -c 'command -v git' >/dev/null || need+=(git)
  if [[ -n "$REPO" && "$REPO" != http* ]] && ! in_machine sh -c 'command -v ssh' >/dev/null; then
    need+=("$(git_ssh_client_pkg)")
  fi
  install_packages "${need[@]+"${need[@]}"}"
}

# Identity is set globally in the machine: each machine belongs to one project.
git_configure_identity() {
  [[ -n "$GIT_USER$GIT_EMAIL" ]] || return 0
  [[ -n "$GIT_USER"  ]] && in_machine git config --global user.name  "$GIT_USER"
  [[ -n "$GIT_EMAIL" ]] && in_machine git config --global user.email "$GIT_EMAIL"
  ok "git identity: ${GIT_USER:-?} <${GIT_EMAIL:-?}>"
}

# The key goes to the machine's ~/.ssh and is used only by this project's repo (core.sshCommand).
git_install_ssh_key() {
  [[ -n "$SSH_KEY" ]] || return 0
  local key name; key="$(host_path "$SSH_KEY")"
  [[ -f "$key" ]] || die "SSH key not found: $key"
  name="$(basename "$key")"
  info "Copying SSH key '$name' into the machine"
  in_machine sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
  push_file "$key" "$VM_HOME/.ssh/$name" 600
  if [[ -f "$key.pub" ]]; then push_file "$key.pub" "$VM_HOME/.ssh/$name.pub" 644; fi
  GIT_SSH="ssh -i ~/.ssh/$name -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
}

git_ensure_project_dir() {
  if [[ -z "$REPO" ]]; then
    if ! in_machine test -d "$PROJ_PATH"; then info "Creating ${PROJ_PATH}…"; in_machine mkdir -p "$PROJ_PATH"; fi
    return 0
  fi
  # A finished clone has a HEAD commit; a leftover from an interrupted clone doesn't.
  if in_machine git -C "$PROJ_PATH" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    if [[ -n "$GIT_SSH" ]]; then in_machine git -C "$PROJ_PATH" config core.sshCommand "$GIT_SSH"; fi
    return 0
  fi
  if in_machine test -e "$PROJ_PATH" && [[ -n "$(in_machine ls -A "$PROJ_PATH")" ]]; then
    die "$PROJ_PATH exists in the machine but isn't a git repo; not cloning over it."
  fi
  info "Cloning $REPO into ${PROJ_PATH}…"
  [[ -n "$GIT_SSH" ]] && info "If your SSH key has a passphrase, type it at the prompt below."
  local args=(clone --progress); [[ -n "$BRANCH" ]] && args+=(--branch "$BRANCH")
  in_machine mkdir -p "$(dirname "$PROJ_PATH")"
  # The clone keeps stdin attached so a key passphrase prompt can be answered.
  if [[ -n "$GIT_SSH" ]]; then
    in_machine_stdin git -c core.sshCommand="$GIT_SSH" "${args[@]}" "$REPO" "$PROJ_PATH"
    in_machine git -C "$PROJ_PATH" config core.sshCommand "$GIT_SSH"
  else
    in_machine_stdin git "${args[@]}" "$REPO" "$PROJ_PATH"
  fi
}
