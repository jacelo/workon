# workspace — where the project lives inside the machine.
#
# "workspace": {
#   "path": "~/web",                    // default: ~/<last part of the project name>
#   "file": "~/web.code-workspace"      // optional: open this Cursor workspace instead of the folder
# }
register_group workspace

workspace::load() {
  RAW_PATH="$(field workspace.path "~/${P##*.}")"
  WORKSPACE_FILE="$(field workspace.file "")"
}

workspace::attach() {
  PROJ_PATH="$(vm_path "$RAW_PATH")"
}
