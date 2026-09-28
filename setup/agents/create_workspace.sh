#!/usr/bin/env bash
# Create the agent workspace layout:
#
#   ~/agent-workspaces/          0700, only you
#   ├── shared/                  mounted READ-ONLY into agents that ask for it
#   ├── agent-001/               one writable workspace per agent
#   └── agent-002/
#
# Usage:
#   ./setup/agents/create_workspace.sh               base layout only
#   ./setup/agents/create_workspace.sh --new         next free agent-NNN
#   ./setup/agents/create_workspace.sh --name NAME   a named workspace
# Prints the created workspace path on stdout.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

make_dir() {
  local path="$1" mode="$2"
  if [[ -d "$path" ]]; then
    log_ok "Exists: $path"
    return 0
  fi
  if is_dry_run; then log_dry "would create $path (mode $mode)"; return 0; fi
  if is_root; then
    install -d -m "$mode" -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$path"
  else
    install -d -m "$mode" "$path"
  fi
  log_ok "Created $path"
}

next_agent_name() {
  local base="$1" n=1 name
  while :; do
    printf -v name 'agent-%03d' "$n"
    [[ -e "$base/$name" ]] || { printf '%s' "$name"; return 0; }
    n=$((n + 1))
  done
}

main() {
  local name="" new=false args=()
  while (($#)); do
    case "$1" in
      --name) name="${2:?--name needs a value}"; shift ;;
      --new) new=true ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  parse_common_args "${args[@]}"
  init_module create_workspace
  is_root && module_enabled_or_exit ENABLE_AGENT_SANDBOX
  require_target_user || die "Run as your normal user, or via sudo from your account"

  local base="${AGENT_WORKSPACES_DIR:-}"
  [[ -n "$base" ]] || base="$TARGET_HOME/agent-workspaces"

  make_dir "$base" 0700
  make_dir "$base/shared" 0750

  [[ "$new" == "true" ]] && name="$(next_agent_name "$base")"
  [[ -n "$name" ]] || return 0
  is_valid_agent_id "$name" || die "Invalid workspace name '$name' (lowercase letters, digits, . _ -)"
  make_dir "$base/$name" 0700
  printf '%s\n' "$base/$name"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
