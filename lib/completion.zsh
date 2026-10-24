# completion.zsh — zsh tab completion for workon. Loaded from ~/.zshrc (see install.sh).
_workon() {
  _arguments '1:project:->proj' '2:project:->proj2' && return
  case $state in
    proj)  _alternative "projects:project:($(workon --names 2>/dev/null))" \
             'opts:option:(--list --shell --down --stop --sync --provision --show --init --edit --help)' ;;
    proj2) _values project $(workon --names 2>/dev/null) ;;
  esac
}
compdef _workon workon
