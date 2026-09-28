#!/usr/bin/env bash
# Automatic security updates via unattended-upgrades.
#
# We only switch the periodic jobs on and add a small override file. The
# distro's 50unattended-upgrades (which limits upgrades to the security
# pocket by default) is left untouched so it keeps receiving package fixes.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

main() {
  parse_common_args "$@"
  init_module updates
  require_root
  module_enabled_or_exit ENABLE_AUTO_UPDATES

  ensure_package unattended-upgrades

  install_managed_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
// Managed by ai-workstation setup (setup/hardening/updates.sh)
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  install_managed_file /etc/apt/apt.conf.d/52ai-workstation-unattended-upgrades 0644 <<EOF
// Managed by ai-workstation setup (setup/hardening/updates.sh).
// Allowed origins are NOT changed here: Ubuntu's 50unattended-upgrades
// already restricts automatic upgrades to the security pocket.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Automatic-Reboot "${UNATTENDED_AUTO_REBOOT:-false}";
Unattended-Upgrade::Automatic-Reboot-Time "${UNATTENDED_REBOOT_TIME:-03:30}";
EOF

  ensure_service_enabled unattended-upgrades.service
  local timer
  for timer in apt-daily.timer apt-daily-upgrade.timer; do
    unit_exists "$timer" && ensure_service_enabled "$timer"
  done

  if [[ -f /var/run/reboot-required ]]; then
    log_warn "A reboot is pending to finish applying updates (/var/run/reboot-required)"
  fi
  log_info "Check what would be upgraded with: sudo unattended-upgrade --dry-run --debug"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
