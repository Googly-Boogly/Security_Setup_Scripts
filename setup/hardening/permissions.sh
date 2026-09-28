#!/usr/bin/env bash
# Conservative permission fixes.
#
# Fixes only ever REMOVE permission bits (never add, never change owners),
# and every change is recorded so rollback can restore the old mode.
# Ownership problems are reported, not changed.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/permissions_policy.sh
source "$SETUP_ROOT/lib/permissions_policy.sh"

# Clamp PATH to at most MAX (octal), recording the previous mode.
clamp_mode() {
  local path="$1" max="$2" current new
  [[ -e "$path" && ! -L "$path" ]] || return 0
  current="$(stat -c '%a' "$path")"
  mode_exceeds "$current" "$max" || return 0
  new="$(mode_clamp "$current" "$max")"
  log_info "Tightening $path: $current -> $new"
  record_change PERM "$path" "$current"
  run_cmd chmod "$new" "$path"
}

fix_system_files() {
  local entry path max
  for entry in "${SENSITIVE_SYSTEM_FILES[@]}"; do
    path="${entry%%:*}"; max="${entry##*:}"
    clamp_mode "$path" "$max"
  done
  for path in /etc/sudoers.d/*; do [[ -f "$path" ]] && clamp_mode "$path" 0440; done
  for path in /etc/ssh/ssh_host_*_key; do [[ -f "$path" ]] && clamp_mode "$path" 0600; done
}

# World-writable files under /etc and /usr/local let any local user (or a
# compromised agent running as your user) plant code that root later runs.
fix_world_writable() {
  local path count=0
  while IFS= read -r -d '' path; do
    clamp_mode "$path" "$(printf '%o' $(( 8#$(stat -c '%a' "$path") & ~8#0002 )))"
    count=$((count + 1))
  done < <(find_world_writable_system_paths)
  ((count == 0)) && log_ok "No world-writable files or unsticky directories in ${WORLD_WRITABLE_SCAN_DIRS[*]}"
  return 0
}

fix_user_files() {
  require_target_user || return 0
  local entry rel max path mode
  for entry in "${SENSITIVE_USER_PATHS[@]}"; do
    rel="${entry%%:*}"; max="${entry##*:}"
    clamp_mode "$TARGET_HOME/$rel" "$max"
  done
  # Private keys: anything in ~/.ssh that is not public or config-like.
  if [[ -d "$TARGET_HOME/.ssh" ]]; then
    for path in "$TARGET_HOME/.ssh"/*; do
      [[ -f "$path" ]] || continue
      case "${path##*/}" in
        *.pub|known_hosts*|config|authorized_keys*|environment) continue ;;
      esac
      clamp_mode "$path" 0600
    done
  fi
  mode="$(stat -c '%a' "$TARGET_HOME")"
  clamp_mode "$TARGET_HOME" "$(printf '%o' $(( 8#$mode & ~8#0002 )))"
  if (( 8#$mode & 8#0004 )); then
    log_warn "$TARGET_HOME is world-readable ($mode). Consider: chmod 750 '$TARGET_HOME' (not changed automatically)."
  fi
}

main() {
  parse_common_args "$@"
  init_module permissions
  require_root
  module_enabled_or_exit ENABLE_PERMISSION_FIXES

  fix_system_files
  fix_world_writable
  fix_user_files
  log_info "Ownership is only reported (see verification/check_permissions.sh), never changed."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
