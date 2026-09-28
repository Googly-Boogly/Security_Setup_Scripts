#!/usr/bin/env bash
# auditd with a small, high-signal rule set.
#
# Rules focus on privilege use, identity/auth configuration and common
# persistence locations. Every rule has a key starting with "aiws_", so:
#   sudo ausearch -k aiws_sudoers -i          # one topic
#   sudo aureport -k --summary                # overview
# Authentication events (logins, sudo auth) are recorded by PAM already.
# The ruleset is deliberately not made immutable (-e 2) so it can be updated
# without a reboot.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

RULES_FILE=/etc/audit/rules.d/60-ai-workstation.rules

# Emit a file watch only if the path exists; auditctl aborts loading the
# whole rule file on a watch whose parent directory is missing.
watch() {
  local path="$1" perms="$2" key="$3"
  [[ -e "$path" ]] && printf -- '-w %s -p %s -k %s\n' "$path" "$perms" "$key"
  return 0
}

generate_rules() {
  local arches=(b64)
  [[ "$(uname -m)" == "x86_64" ]] && arches+=(b32)   # 32-bit syscalls bypass b64-only rules
  local a

  echo "## Managed by ai-workstation setup (setup/security/auditd.sh)"
  echo "## Privilege escalation tools"
  watch /usr/bin/sudo x aiws_priv_exec
  watch /usr/bin/su x aiws_priv_exec
  watch /usr/bin/pkexec x aiws_priv_exec
  echo "## Identity, sudo, PAM and SSH configuration"
  watch /etc/sudoers wa aiws_sudoers
  watch /etc/sudoers.d wa aiws_sudoers
  watch /etc/passwd wa aiws_identity
  watch /etc/shadow wa aiws_identity
  watch /etc/group wa aiws_identity
  watch /etc/gshadow wa aiws_identity
  watch /etc/pam.d wa aiws_pam
  watch /etc/ssh/sshd_config wa aiws_sshd
  watch /etc/ssh/sshd_config.d wa aiws_sshd
  if [[ -n "$TARGET_HOME" ]]; then watch "$TARGET_HOME/.ssh" wa aiws_user_ssh; fi
  echo "## Security controls configured by this project"
  watch /etc/ufw wa aiws_firewall
  watch /etc/default/ufw wa aiws_firewall
  watch /etc/sysctl.conf wa aiws_sysctl
  watch /etc/sysctl.d wa aiws_sysctl
  watch /etc/apparmor.d wa aiws_apparmor
  watch /etc/audit wa aiws_audit_config
  watch /etc/docker wa aiws_docker_config
  echo "## Persistence locations"
  watch /etc/systemd/system wa aiws_systemd
  watch /etc/crontab wa aiws_cron
  watch /etc/cron.d wa aiws_cron
  watch /var/spool/cron wa aiws_cron
  watch /etc/ld.so.preload wa aiws_preload
  watch /etc/profile.d wa aiws_shell_init
  echo "## Kernel modules"
  for a in "${arches[@]}"; do
    echo "-a always,exit -F arch=$a -S init_module,finit_module,delete_module -k aiws_kernel_modules"
  done
  if [[ "${AUDITD_LOG_ROOT_COMMANDS:-true}" == "true" ]]; then
    echo "## Commands executed as root by a logged-in (non-system) user, e.g. via sudo"
    for a in "${arches[@]}"; do
      echo "-a always,exit -F arch=$a -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k aiws_root_cmd"
    done
  fi
}

main() {
  parse_common_args "$@"
  init_module auditd
  require_root
  module_enabled_or_exit ENABLE_AUDITD

  ensure_package auditd
  generate_rules | install_managed_file "$RULES_FILE" 0640
  local changed="$FILE_CHANGED"
  if is_dry_run && ! command_exists augenrules; then return 0; fi

  ensure_service_enabled auditd.service
  if [[ "$changed" == "true" ]] && ! is_dry_run; then
    if augenrules --check 2>/dev/null | grep -q 'No change'; then
      log_ok "Audit rules already loaded"
    elif ! run_cmd augenrules --load; then
      log_warn "Could not load audit rules. If rules are immutable (-e 2) a reboot is required."
    fi
  fi

  if is_root && command_exists auditctl; then
    local loaded
    loaded="$(auditctl -l 2>/dev/null | grep -c 'aiws_' || true)"
    log_info "$loaded ai-workstation audit rule(s) active. Query: sudo ausearch -k aiws_root_cmd -i --start today"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
