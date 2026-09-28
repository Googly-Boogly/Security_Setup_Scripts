#!/usr/bin/env bash
# Make sure AppArmor is installed, enabled and enforcing its shipped profiles.
#
# We intentionally do not write new profiles: a wrong profile silently breaks
# applications. Docker and Podman already confine containers with their own
# default AppArmor profile when AppArmor is active.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

main() {
  parse_common_args "$@"
  init_module apparmor
  require_root
  module_enabled_or_exit ENABLE_APPARMOR

  ensure_package apparmor apparmor-utils
  ensure_service_enabled apparmor.service

  if grep -qwE 'apparmor=0|security=(selinux|smack|tomoyo)' /proc/cmdline 2>/dev/null; then
    log_warn "The kernel command line disables AppArmor ($(cat /proc/cmdline)). Fix GRUB_CMDLINE_LINUX in /etc/default/grub."
  fi

  if command_exists aa-enabled && aa-enabled --quiet 2>/dev/null; then
    log_ok "AppArmor is enabled in the kernel"
  else
    log_warn "AppArmor is not enabled in the running kernel (a reboot may be required)"
    return 0
  fi

  if is_root && command_exists aa-status; then
    local enforced complain
    enforced="$(aa-status --enforced 2>/dev/null || echo '?')"
    complain="$(aa-status --complaining 2>/dev/null || echo '?')"
    log_info "Profiles: $enforced enforcing, $complain complain-mode"
  fi

  local userns
  userns="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || true)"
  if [[ -n "$userns" ]]; then
    log_info "Unprivileged user namespace restriction (Ubuntu 24.04+): $userns (left as is)"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
