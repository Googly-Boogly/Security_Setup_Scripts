#!/usr/bin/env bash
# Verify security services and network exposure. Usage: sudo ./setup/verification/check_services.sh
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/report.sh
source "$SETUP_ROOT/lib/report.sh"

check_updates() {
  local cfg
  cfg="$(apt-config dump 2>/dev/null || true)"
  if package_installed unattended-upgrades && grep -q 'APT::Periodic::Unattended-Upgrade "1"' <<<"$cfg"; then
    report_pass "Automatic updates enabled"
  else
    report_fail "Automatic security updates are not enabled"
  fi
  unit_enabled apt-daily-upgrade.timer || report_warn "apt-daily-upgrade.timer is not enabled"
  if [[ -f /var/run/reboot-required ]]; then report_warn "Reboot required to finish applying updates"; fi
  return 0
}

check_apparmor() {
  if command_exists aa-enabled && aa-enabled --quiet 2>/dev/null; then
    report_pass "AppArmor enabled"
    if is_root && command_exists aa-status; then
      report_info "AppArmor profiles enforcing: $(aa-status --enforced 2>/dev/null || echo '?'), complain: $(aa-status --complaining 2>/dev/null || echo '?')"
    fi
  else
    report_fail "AppArmor is not enabled"
  fi
}

check_auditd() {
  if unit_active auditd.service; then
    report_pass "auditd running"
    if is_root && command_exists auditctl; then
      local n
      n="$(auditctl -l 2>/dev/null | grep -c 'aiws_' || true)"
      if ((n > 0)); then report_pass "$n ai-workstation audit rules loaded"; else report_warn "ai-workstation audit rules not loaded"; fi
    fi
  elif is_enabled ENABLE_AUDITD && ! package_installed auditd; then
    report_fail "auditd is not installed (ENABLE_AUDITD=true): run sudo ./setup/security/auditd.sh"
  elif is_enabled ENABLE_AUDITD; then
    report_fail "auditd is installed but not running: see systemctl status auditd (containers/WSL cannot run auditd)"
  else
    report_warn "auditd disabled"
  fi
}

check_ssh() {
  if ! package_installed openssh-server; then
    report_pass "SSH server not installed"
    return 0
  fi
  local running=false
  { unit_active ssh.service || unit_active ssh.socket; } && running=true
  if ! is_enabled ENABLE_SSH_SERVER; then
    if [[ "$running" == "true" ]]; then report_warn "SSH server running although ENABLE_SSH_SERVER=false"
    else report_warn "SSH server installed (disabled)"; fi
    return 0
  fi
  [[ "$running" == "true" ]] && report_info "SSH server running (enabled in config)"
  if is_root && command_exists sshd; then
    local eff
    eff="$(sshd -T 2>/dev/null || true)"
    if grep -qx 'permitrootlogin no' <<<"$eff"; then report_pass "SSH root login disabled"; else report_fail "SSH root login not disabled"; fi
    if grep -qx 'passwordauthentication no' <<<"$eff"; then report_pass "SSH password login disabled"
    else report_warn "SSH password login enabled (add authorized_keys, re-run hardening/ssh.sh)"; fi
  fi
}

check_optional_tools() {
  if is_enabled ENABLE_SURICATA; then
    if unit_active suricata.service; then report_pass "Suricata running (passive IDS)"; else report_fail "Suricata enabled in config but not running"; fi
  else
    report_info "Suricata disabled (optional)"
  fi
  if package_installed aide || package_installed aide-common; then
    if [[ -f /var/lib/aide/aide.db ]]; then report_pass "AIDE baseline present"
    elif is_root; then report_warn "AIDE installed but no baseline: sudo ./setup/security/aide.sh init"
    else report_info "AIDE baseline: needs root to check"; fi
  elif is_enabled ENABLE_AIDE; then
    report_warn "AIDE enabled in config but not installed"
  fi
  command_exists trivy && report_info "Trivy available: $(trivy --version 2>/dev/null | head -n1)"
  command_exists gitleaks && report_info "Gitleaks available"
  if is_enabled ENABLE_MALWARE_SCANNING; then
    if unit_active clamav-freshclam.service; then report_pass "ClamAV signatures updating"; else report_warn "clamav-freshclam not running"; fi
  fi
  if is_enabled ENABLE_WAZUH_AGENT; then
    if unit_active wazuh-agent.service; then report_pass "Wazuh agent running"; else report_fail "Wazuh agent enabled but not running"; fi
  fi
  return 0
}

check_listeners() {
  local proto state rq sq local_addr peer process port exposed=0
  while read -r proto state rq sq local_addr peer process; do
    [[ -n "$local_addr" ]] || continue
    is_loopback_address "$local_addr" && continue
    port="${local_addr##*:}"
    [[ "$proto" == udp && ( "$port" == 68 || "$port" == 546 || "$port" == 5353 ) ]] && continue
    report_warn "Service listening on non-loopback address: $proto $local_addr ${process:-}"
    exposed=$((exposed + 1))
  done < <(ss -H -tulpn 2>/dev/null || true)
  ((exposed == 0)) && report_pass "No unexpected services listening on external interfaces"
  is_root || report_info "Run as root to see process names for listening sockets"
  : "$state" "$rq" "$sq" "$peer"
  return 0
}

check_failed_units() {
  local failed
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' || true)"
  if [[ -n "$failed" ]]; then report_warn "Failed systemd units: $failed"; else report_pass "No failed systemd units"; fi
}

run_services_checks() {
  report_section "Services"
  check_updates
  check_apparmor
  check_auditd
  check_ssh
  check_optional_tools
  check_listeners
  check_failed_units
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then run_check_standalone run_services_checks "$@"; fi
