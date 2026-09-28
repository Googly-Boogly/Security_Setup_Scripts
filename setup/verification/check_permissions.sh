#!/usr/bin/env bash
# Check permissions of sensitive files and look for world-writable paths.
# Usage: sudo ./setup/verification/check_permissions.sh
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/report.sh
source "$SETUP_ROOT/lib/report.sh"
# shellcheck source=../lib/permissions_policy.sh
source "$SETUP_ROOT/lib/permissions_policy.sh"

check_max_mode() {
  local path="$1" max="$2" label="$3" mode
  [[ -e "$path" && ! -L "$path" ]] || return 0
  mode="$(stat -c '%a' "$path")"
  if mode_exceeds "$mode" "$max"; then
    report_fail "$label $path has mode $mode (should be at most $max)"
    return 1
  fi
  return 0
}

run_permissions_checks() {
  report_section "Permissions"
  local entry bad=0
  for entry in "${SENSITIVE_SYSTEM_FILES[@]}"; do
    check_max_mode "${entry%%:*}" "${entry##*:}" "System file" || bad=$((bad + 1))
  done
  local f
  for f in /etc/sudoers.d/* /etc/ssh/ssh_host_*_key; do
    [[ -f "$f" ]] || continue
    case "$f" in /etc/sudoers.d/*) check_max_mode "$f" 0440 "Sudoers file" || bad=$((bad + 1)) ;;
                 *) check_max_mode "$f" 0600 "Host key" || bad=$((bad + 1)) ;; esac
  done
  ((bad == 0)) && report_pass "Sensitive system files have safe permissions"

  local ww=() path
  while IFS= read -r -d '' path; do ww+=("$path"); done < <(find_world_writable_system_paths)
  if ((${#ww[@]} == 0)); then
    report_pass "No world-writable sensitive configuration detected (${WORLD_WRITABLE_SCAN_DIRS[*]})"
  else
    report_fail "${#ww[@]} world-writable path(s) under ${WORLD_WRITABLE_SCAN_DIRS[*]}, e.g.: ${ww[*]:0:5}"
  fi

  local suid=()
  while IFS= read -r -d '' path; do suid+=("$path"); done < <(find /usr/local -xdev -type f \( -perm -4000 -o -perm -2000 \) -print0 2>/dev/null)
  if ((${#suid[@]} > 0)); then report_warn "setuid/setgid binaries in /usr/local: ${suid[*]:0:5}"; fi

  if [[ -z "$TARGET_HOME" ]]; then
    report_info "User file checks skipped (no target user; run via sudo from your account)"
    return 0
  fi
  bad=0
  for entry in "${SENSITIVE_USER_PATHS[@]}"; do
    check_max_mode "$TARGET_HOME/${entry%%:*}" "${entry##*:}" "User path" || bad=$((bad + 1))
  done
  if [[ -d "$TARGET_HOME/.ssh" ]]; then
    for f in "$TARGET_HOME/.ssh"/*; do
      [[ -f "$f" ]] || continue
      case "${f##*/}" in *.pub|known_hosts*|config|authorized_keys*|environment) continue ;; esac
      check_max_mode "$f" 0600 "SSH private key" || bad=$((bad + 1))
    done
  fi
  ((bad == 0)) && report_pass "Credential files in $TARGET_HOME have safe permissions"

  local hmode
  hmode="$(stat -c '%a' "$TARGET_HOME")"
  if (( 8#$hmode & 8#0002 )); then report_fail "$TARGET_HOME is world-writable ($hmode)"
  elif (( 8#$hmode & 8#0004 )); then report_warn "$TARGET_HOME is world-readable ($hmode); consider chmod 750"
  else report_pass "$TARGET_HOME is private ($hmode)"; fi

  local owner
  for f in "$TARGET_HOME/.ssh" "$TARGET_HOME/agent-workspaces"; do
    [[ -e "$f" ]] || continue
    owner="$(stat -c '%U' "$f")"
    [[ "$owner" == "$TARGET_USER" ]] || report_warn "$f is owned by $owner, expected $TARGET_USER"
  done
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then run_check_standalone run_permissions_checks "$@"; fi
