# vm — the OrbStack machine itself.
#
# "vm": {
#   "name":            "acme-web",      // default: project name with dots → dashes
#   "user":            "you",           // default: your Mac user name
#   "distro":          "ubuntu:noble",  // default: ubuntu
#   "arch":            "arm64",         // optional
#   "cpus": 4, "memory": "8G", "disk": "64G",   // optional
#   "isolate_network": true,            // default true: no route to your Mac's network
#   "ssh_host":        "my-alias",      // optional: your own SSH host for Cursor (see cursor)
#   "packages":        ["git", "curl"]  // installed on first run
# }
register_group vm

vm::load() {
  MACHINE="$(field vm.name "$(machine_default "$P")")"
  USER_NAME="$(field vm.user "$(whoami)")"
  DISTRO="$(field vm.distro "ubuntu")"
  ARCH="$(field vm.arch "")"
  CPUS="$(field vm.cpus "")"
  MEMORY="$(field vm.memory "")"
  DISK="$(field vm.disk "")"
  ISOLATE_NET="$(field vm.isolate_network true)"
  [[ "$MACHINE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "Invalid machine name: $MACHINE"
}

vm::provision() {
  local pkgs=() p
  while IFS= read -r p; do [[ -n "$p" ]] && pkgs+=("$p"); done < <(field vm.packages "")
  install_packages "${pkgs[@]+"${pkgs[@]}"}"
}
