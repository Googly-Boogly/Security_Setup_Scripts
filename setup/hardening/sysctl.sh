#!/usr/bin/env bash
# Kernel and network hardening via sysctl.
#
# The settings live in hardening/files/60-ai-workstation-hardening.conf,
# where each one is documented. Before the first change we record the
# running values so rollback can restore them without a reboot.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SYSCTL_SOURCE="$SETUP_ROOT/hardening/files/60-ai-workstation-hardening.conf"
SYSCTL_DEST="/etc/sysctl.d/60-ai-workstation-hardening.conf"

record_previous_values() {
  local key want current
  while read -r key want; do
    current="$(sysctl_value "$key")" || continue
    if ! manifest_has SYSCTL_PREV "$key" any; then record_change SYSCTL_PREV "$key" "$current"; fi
  done < <(parse_sysctl_file "$SYSCTL_SOURCE")
}

# Apply key by key so one unsupported or locked key does not abort the rest.
apply_values() {
  local key want current rc applied=0 skipped=0
  while read -r key want; do
    rc=0; current="$(sysctl_value "$key")" || rc=$?
    if ((rc == 1)); then
      log_info "Kernel does not have $key; skipping"
      skipped=$((skipped + 1)); continue
    fi
    [[ "$current" == "$want" ]] && continue
    # rc 2: unreadable without root (dry-run as a normal user); assume a change.
    if run_cmd sysctl -q -w "$key=$want"; then
      applied=$((applied + 1))
    else
      log_warn "Could not set $key=$want (current: ${current:-unknown})"
      skipped=$((skipped + 1))
    fi
  done < <(parse_sysctl_file "$SYSCTL_SOURCE")

  if ((applied == 0 && skipped == 0)); then log_ok "All sysctl settings already in effect"
  else log_info "Applied $applied setting(s), skipped $skipped"; fi
}

# Files applied after ours (later name, or /etc/sysctl.conf via 99-sysctl.conf)
# win at boot. Report disagreements; never edit files we do not own.
report_conflicts() {
  local -A want=()
  local key val f found=0 ours
  ours="$(basename "$SYSCTL_DEST")"
  while read -r key val; do want["$key"]="$val"; done < <(parse_sysctl_file "$SYSCTL_SOURCE")
  for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
    [[ -r "$f" && "$f" != "$SYSCTL_DEST" ]] || continue
    while read -r key val; do
      [[ -n "${want[$key]+x}" && "${want[$key]}" != "$val" ]] || continue
      found=1
      if [[ "$f" == /etc/sysctl.conf || "$(basename "$f")" > "$ours" ]]; then
        log_warn "$f sets $key=$val and is applied after $ours, so it wins at boot (wanted ${want[$key]})"
      else
        log_info "$f sets $key=$val; $ours is applied later and overrides it"
      fi
    done < <(parse_sysctl_file "$f")
  done
  ((found == 0)) && log_ok "No conflicting sysctl values in /etc/sysctl.conf or /etc/sysctl.d"
  return 0
}

main() {
  parse_common_args "$@"
  init_module sysctl
  require_root
  module_enabled_or_exit ENABLE_SYSCTL_HARDENING

  record_previous_values
  install_managed_file "$SYSCTL_DEST" 0644 <"$SYSCTL_SOURCE"
  apply_values
  report_conflicts
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
