# Sourced by the local build scripts: loads this machine's private settings from
# `.env.local` at the repository root (git-ignored; `.env.local.example` lists what
# goes in it). Claude Code copies it into the worktrees it creates (.worktreeinclude).
# A variable already set in the environment wins over the file.
local_env_load() {
  local file="$1/.env.local" line key value
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      key="${line%%=*}"; value="${line#*=}"
      [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
      [ -n "${!key:-}" ] || export "$key=$value"
    done < "$file"
    echo "local settings: $file"
  else
    echo "local settings: none ($file not found)"
  fi
}
