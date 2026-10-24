# workon

Open any project in its own isolated Linux machine, with Cursor connected over SSH.

```bash
workon acme.web        # create or start the machine, set it up, open Cursor
workon --down web      # close Cursor, stop the project's services, stop the machine
```

Each project gets its own [OrbStack](https://orbstack.dev) machine. Code, dependencies, Docker,
databases and AI coding agents all run inside it, so nothing a project installs or runs can reach
your Mac's files, SSH keys or network.

## Contents

- [Security model](#security-model)
- [Requirements](#requirements)
- [Install](#install)
- [Uninstall](#uninstall)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Configuration](#configuration)
- [Lifecycle](#lifecycle)
- [Claude Code in the machine](#claude-code-in-the-machine)
- [Troubleshooting](#troubleshooting)
- [Extending workon](#extending-workon)
- [Project layout](#project-layout)

## Security model

Data only flows from the Mac into the machine:

- **Isolated machines.** Machines are created with `--isolated`: no shared folders, no `mac`
  command, no host integration. workon refuses to use a machine that isn't isolated, has Mac
  folders mounted, or has SSH agent forwarding on.
- **Network isolation** (on by default). The machine can reach the internet but not your Mac's IP
  addresses or other machines.
- **One-way copies.** Files go in by piping `tar`/`cat` over stdin. workon never reads files back
  out, and never mounts Mac folders.
- **Scoped secrets.** A project's git SSH key is copied in and used only by that project's repo.
  Agent and X11 forwarding to OrbStack machines are turned off in `~/.ssh/config`.

What's inside a machine is only as safe as the machine: its git key, `.env` files, data and Claude
token can be read by anything running in it. Keep each machine to one project.

Run AI coding agents (Claude Code, Cursor's agent) **inside** the machine, from Cursor's terminal.
An agent on the Mac can read and change every machine through the `orb` CLI, and would carry
anything it reads in a machine back to the Mac side.

## Requirements

- macOS with [OrbStack](https://orbstack.dev)
- [Cursor](https://cursor.com) with its `cursor` command (Cursor › *Install 'cursor' command*)
- `jq` (`brew install jq`)

## Install

```bash
git clone <this repo> ~/workon
~/workon/install.sh
```

Then open a new terminal so the `workon` command is available.

### What install.sh does

`install.sh` only touches the files listed below, and only inside lines it marks as its own, so
your other settings are left alone. Each step checks first and does nothing if it's already done,
so it's safe to run again. Run it again after moving this folder: it updates the paths.

1. **Checks your tools.** Looks for `jq`, OrbStack's `orb`, `ssh`, `osascript` and Cursor, and
   tells you how to install any that are missing. It doesn't install anything itself.

2. **Adds `workon` to your shell** (`~/.zshrc`). Adds this block, between markers it uses to find
   it again:

   ```bash
   # >>> workon >>>
   export PATH="<this folder>/bin:$PATH"           # makes the workon command available
   autoload -Uz compinit && compinit -C            # turns on zsh tab completion
   source "<this folder>/lib/completion.zsh"       # tab-completes workon commands and projects
   # <<< workon <<<
   ```

   If the block is already there but out of date, it's replaced, and the old file is kept as
   `~/.zshrc.bak-workon`.

3. **Hardens SSH to OrbStack machines** (`~/.ssh/config`). Adds a block that stops SSH from ever
   forwarding your Mac's SSH agent (and with it, the use of your keys) or X11 into a machine:

   ```
   # >>> workon hardening >>>
   Host orb
     ForwardAgent no
     ForwardX11 no
   # <<< workon hardening <<<
   ```

4. **Creates your config.** Copies `config/workon.example.json` to `config/workon.json` if you
   don't have one yet, and creates `config/claude-keys/` readable only by you.

Two more things are written later, by `workon` itself, the first time it opens a project in
Cursor (see [Troubleshooting](#troubleshooting) for why):

- an SSH alias per machine in `~/.ssh/workon/<machine>.conf`, and
- an `Include ~/.ssh/workon/*.conf` line at the top of `~/.ssh/config`.

## Uninstall

```bash
./uninstall.sh            # remove workon from your shell and SSH config
./uninstall.sh --purge    # also delete your config and Claude tokens (asks you to type "yes")
```

`uninstall.sh` undoes everything above and is safe to run again:

- removes the `workon` block from `~/.zshrc`,
- removes the hardening block and the `Include` line from `~/.ssh/config`, and deletes
  `~/.ssh/workon/`,
- backs up each file it changes as `<file>.bak-workon` first.

It never deletes machines, because they hold your work. It lists the ones that exist with the command
to delete each (`orb delete <machine>`). Without `--purge`, your config and Claude tokens stay, so
running `install.sh` again brings everything back. Delete this folder yourself when you're done
with it.

## Quick start

1. Edit your config: `workon --edit`. Start from the `acme.web` example: set the repo, your git
   identity, and the SSH key that can read the repo.
2. Run `workon acme.web` (or just `workon web`). The first run creates the machine, installs
   packages, clones the repo and runs your setup commands. It takes a few minutes and prints
   progress the whole time.
3. Cursor opens, connected to the machine. Use its terminal to work. It's a shell inside the machine.
4. When you're done: `workon --down web`. Run `workon web` to pick up where you left off.

## Commands

| Command | What it does |
| --- | --- |
| `workon <project>` | Create or start the machine, set it up, open Cursor |
| `workon -l`, `--list` | List projects |
| `workon -s`, `--shell <p>` | Open a shell in the machine, in the project folder |
| `workon -d`, `--down <p>` | Close the project's Cursor window, run `on_stop` hooks, stop the machine. Nothing is deleted |
| `workon --stop <p>` | Stop the machine only |
| `workon --sync <p>` | Re-apply settings and re-copy every `copy` entry, overwriting what's in the machine |
| `workon --provision <p>` | Re-run first-time installs and the `on_create_root` / `on_create` hooks |
| `workon --show <p>` | Print the project's settings after inheritance |
| `workon --init` | Create `config/workon.json` from the example |
| `workon -e`, `--edit` | Edit the config in `$EDITOR` |

Projects can be named in full (`acme.web`) or by a unique last part (`web`).

`WORKON_DEBUG=1 workon …` prints every command as it runs. `WORKON_CONFIG=/path/to.json`
uses a different config file.

To remove a machine for good: `orb delete <machine>`.

## Configuration

`config/workon.json` is your own file and is gitignored. `config/workon.example.json` is the shared
template and shows every option.

### Projects and inheritance

`projects` is a tree. A node with no child nodes is a project, named by its path:

```json
{
  "defaults": { "git": { "user": "Your Name", "email": "you@example.com" } },
  "projects": {
    "acme": {
      "git": { "email": "you@acme.example", "ssh_key": "~/.ssh/acme-github" },
      "web": { "git": { "repo": "git@github.com:acme/web.git" } },
      "api": { "git": { "repo": "git@github.com:acme/api.git" } }
    }
  }
}
```

This defines `acme.web` and `acme.api`. Settings merge from `defaults`, through each parent
level, to the project. Objects merge key by key. **Arrays are replaced, not appended:** a project's
`hooks.on_create` replaces any list it inherited. Check the result with `workon --show <project>`.

### Paths

- **Mac paths** (`copy.src`, `git.ssh_key`, `claude.token_file`, `claude.mcp_file`) must be
  absolute or start with `~`.
- **Machine paths** (`workspace.path`, `workspace.file`, `copy.dest`): `~` is the machine user's
  home. A relative path is relative to the project folder.

### Groups

Each top-level key is a group, handled by one module in `lib/groups/`.

#### `vm`: the machine

| Key | Default | |
| --- | --- | --- |
| `name` | project name, dots → dashes | OrbStack machine name |
| `user` | your Mac user name | user inside the machine |
| `distro` | `ubuntu` | e.g. `ubuntu:noble`, `debian`, `fedora` |
| `arch`, `cpus`, `memory`, `disk` | OrbStack defaults | e.g. `4`, `"8G"`, `"64G"` |
| `isolate_network` | `true` | block the machine from reaching your Mac's network |
| `packages` | `[]` | installed on the first run |
| `ssh_host` | `workon-<machine>` | your own SSH host for Cursor; workon then leaves your SSH config alone |

#### `workspace`: where the project lives in the machine

| Key | Default | |
| --- | --- | --- |
| `path` | `~/<last part of the project name>` | project folder (where the repo is cloned) |
| `file` | none | a `.code-workspace` file to open instead of the folder |

#### `git`

| Key | |
| --- | --- |
| `user`, `email` | git identity in the machine |
| `repo` | cloned into `workspace.path` on the first run. Without it, the folder is just created |
| `branch` | branch to clone |
| `ssh_key` | Mac key copied into the machine and used only for this repo. If it has a passphrase, you're asked for it during the clone and on every push/pull |

A GitHub [deploy key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
for just that repo limits the damage if a machine is compromised.

#### `copy`: Mac files into the machine

```json
"copy": [
  "~/notes/todo.md",
  { "src": "~/Work/acme/web/.env.local", "dest": ".env.local" },
  { "src": "~/Work/acme/assets", "dest": "~/assets", "sync": "always", "exclude": ["*.tmp"] }
]
```

A plain string copies into the project folder. `sync: "once"` (default) copies only when the
destination is missing, so your edits in the machine survive. `"always"` overwrites on every run.
`workon --sync` overwrites every entry.

Files copied from the Mac often contain Mac paths (`/Users/...`). Fix them in the machine's copy,
and remember that `--sync` will bring the Mac version back.

#### `claude`: Claude Code in the machine

See [Claude Code in the machine](#claude-code-in-the-machine).

#### `hooks`: your own commands

| Key | Runs | As |
| --- | --- | --- |
| `on_create_root` | first run, before the clone | root (`$WORKON_USER` = machine user) |
| `on_create` | first run, after the clone and copies | machine user, in the project folder |
| `on_start` | every `workon <project>`, before Cursor opens | machine user, in the project folder |
| `on_stop` | `workon --down`, before the machine stops | machine user, in the project folder |

Each hook is a list of shell commands, run with `bash -lc`. A failing command stops workon, except
in `on_stop`, where the machine still stops.

#### `cursor`

| Key | Default | |
| --- | --- | --- |
| `open` | `true` | `false` to set up the machine without opening Cursor |

## Lifecycle

Every command runs through the same phases. Each group handles the phases it needs.

```
workon <project>
  load       read settings                     (all groups; the machine isn't touched)
  machine    create or start it, check isolation
  attach     resolve paths in the machine
  provision  first run only: packages, on_create_root
  setup      every run: git, SSH key, Claude Code, copies
  create     first run only: on_create
  start      on_start
  open       Cursor

workon --sync      load → attach → setup (overwriting copies)
workon --down      load → down (in reverse group order: close Cursor, then on_stop) → stop machine
```

"First run" means the machine has no setup marker yet. `--provision` runs those steps again.

## Claude Code in the machine

Claude Code is installed in every machine by default (`claude.install`). Open Cursor's terminal and
run `claude`.

**Skip the login with a token.** Each project reads its token from `config/claude-keys/<project>`
(gitignored):

```bash
claude setup-token                    # on your Mac; copy the token it prints
(umask 077; pbpaste > ~/workon/config/claude-keys/acme.web)
```

The next run copies it into the machine, readable only by the machine user. Empty the file to
remove it from the machine. Without a token, log in by running `claude` in the machine.

| Key | Default | |
| --- | --- | --- |
| `install` | `true` | install Claude Code to `~/.local/bin` |
| `token_file` | `config/claude-keys/<project>` | Mac file with a `claude setup-token` token |
| `settings` | `{}` | merged into the machine's `~/.claude/settings.json` |
| `mcp` | `{}` | MCP servers, as for `claude mcp add-json` |
| `mcp_file` | none | Mac file `{ "mcpServers": { … } }` for servers with secrets |

```json
"claude": {
  "settings": { "theme": "dark" },
  "mcp": { "docs": { "type": "http", "url": "https://docs.acme.example/mcp" } },
  "mcp_file": "~/workon/config/mcp/acme.json"
}
```

MCP servers are re-applied on every run. Servers you remove from the config are removed from the
machine. `config/mcp/` is gitignored for files with secrets.

## Troubleshooting

**The clone hangs after the passphrase prompt.** Your typing isn't reaching the machine. This was
fixed in workon. If it happens again, press Ctrl+C. An interrupted clone is detected and retried on
the next run.

**Cursor: `Invalid SSH hostname "machine@orb"`.** Cursor can't use OrbStack's `user@machine@orb`
hosts, so workon writes an alias per machine to `~/.ssh/workon/<machine>.conf` and opens
`workon-<machine>`. Check it with `ssh workon-<machine>`.

**Docker builds fail in the machine.** Two errors are common in OrbStack machines:

- `failed to solve: mount source: "overlay" … operation not permitted`
- `dpkg: … Invalid cross-device link`

Both come from Docker's overlay storage, which these machines don't fully support. Switch Docker to
btrfs storage:

```bash
printf '{\n  "storage-driver": "btrfs",\n  "features": { "containerd-snapshotter": false }\n}\n' \
  | sudo tee /etc/docker/daemon.json && sudo systemctl restart docker && docker builder prune -af
```

Add the first part as an `on_create_root` hook so new machines get it. The example config shows the
Docker packages.

**A container can't read a mounted file: `permission denied`.** Containers that drop all
capabilities (`cap_drop: [ALL]`) can't read files owned by another user. On the Mac, Docker hides
file ownership, so this only shows up in the machine. Give root ownership of the file:
`sudo chown root:root <file>`.

**`mkdir: cannot create directory '/Users'`.** A file copied from the Mac (often `.env`) has Mac
paths. Point them at paths in the machine.

**Services in the machine from the Mac.** Ports the machine publishes on `127.0.0.1` are reachable at
`localhost` on the Mac. If one isn't, forward it: `ssh -L 8080:127.0.0.1:8080 workon-<machine>`.

**`--down` can't close the Cursor window.** Allow your terminal app in *System Settings › Privacy &
Security › Accessibility*. Until then, workon tells you to close the window yourself and stops the
rest anyway.

**Something else.** Run with `WORKON_DEBUG=1` to see every command.

## Extending workon

### Add a config group

Create `lib/groups/NN-<name>.sh`. The number sets its order among the other groups. Register
the group, then define a function for each [lifecycle phase](#lifecycle) it needs:

```bash
# lib/groups/45-dotfiles.sh
# "dotfiles": { "repo": "https://github.com/you/dotfiles.git" }
register_group dotfiles

dotfiles::load() {
  DOTFILES_REPO="$(field dotfiles.repo "")"
}

dotfiles::setup() {
  [[ -n "$DOTFILES_REPO" ]] || return 0
  in_machine test -d "$VM_HOME/.dotfiles" && return 0
  info "Cloning dotfiles…"
  in_machine git clone "$DOTFILES_REPO" "$VM_HOME/.dotfiles"
}
```

That's all: `dotfiles` now works at every config level and inherits like the other groups. Phases a
group doesn't define are skipped. `load` must not talk to the machine.

Helpers from `lib/`:

| Helper | |
| --- | --- |
| `field <group.key> [default]` | a setting (arrays print one per line) |
| `field_json <group.key> [default-json]` | a setting as JSON |
| `in_machine <cmd…>` / `as_root <cmd…>` | run in the machine (stdin closed) |
| `in_machine_stdin <cmd…>` | run in the machine with stdin attached |
| `push_file <src> <dest> [mode]`, `push_dir <src> <dest> [exclude…]` | copy into the machine |
| `install_packages <pkg…>` | install with the machine's package manager |
| `vm_merge_json` | merge `{"<path>": {…}}` from stdin into JSON files in the machine |
| `host_path`, `vm_path` | expand `~` on the Mac or in the machine |
| `info`, `ok`, `warn`, `die` | output |
| `with_heartbeat <label> <cmd…>` | run one long command with "still working" lines |

Variables available after `load`: `P` (project), `MACHINE`, `USER_NAME`. After `attach`: `VM_HOME`,
`PROJ_PATH`.

### Add a hook

Hooks map lifecycle phases to config keys in `lib/groups/60-hooks.sh`. To add, say,
`on_sync`, add `hooks::<phase>() { run_hooks on_sync; }` for the phase it should run in.

### Add a command

Add a `cmd_<name>` function and a line in `workon_main` in `lib/commands.sh`, then add it to
`usage`, `lib/completion.zsh` and this README.

### Rules

- Stay compatible with macOS's `/bin/bash` 3.2: no associative arrays, `mapfile` or `${x,,}`. Empty
  arrays need `"${arr[@]+"${arr[@]}"}"` under `set -u`.
- Never read files out of the machine onto the Mac.
- Run `tests/check.sh` before committing. It checks syntax with bash 3.2, runs shellcheck if
  installed, and tests config resolution against the example config.

## Project layout

```
bin/workon                 entry point: loads the modules, runs the command
lib/
  core.sh                  output, timing, path helpers
  lifecycle.sh             group registry and phases
  config.sh                config loading and inheritance
  machine.sh               OrbStack machine, isolation checks, copies into the machine
  commands.sh              CLI commands
  completion.zsh           zsh tab completion, loaded from ~/.zshrc
  groups/                  one module per config group, run in file-name order
    10-vm.sh  20-workspace.sh  30-git.sh  40-claude.sh  50-copy.sh  60-hooks.sh  70-cursor.sh
config/
  workon.example.json      template with every option (committed)
  workon.json              your config (gitignored)
  claude-keys/             per-project Claude Code tokens (gitignored)
install.sh                 one-time setup on a Mac; re-run after moving the folder
uninstall.sh               undo install.sh (keeps machines; --purge deletes config and tokens)
tests/check.sh             fast checks; no machine needed
```
