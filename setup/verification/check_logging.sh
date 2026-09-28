#!/usr/bin/env bash
# Verify log retention, integrity and exposure.
# Usage: sudo ./setup/verification/check_logging.sh
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/report.sh
source "$SETUP_ROOT/lib/report.sh"

# Logs that record authentication or commands must not be world-readable.
SENSITIVE_LOGS=(/var/log/auth.log /var/log/syslog /var/log/kern.log /var/log/audit/audit.log)

check_rotation() {
  if ! command_exists logrotate; then report_fail "logrotate is not installed"; return 0; fi
  if unit_enabled logrotate.timer || [[ -x /etc/cron.daily/logrotate ]]; then report_pass "logrotate runs daily"
  else report_warn "logrotate is installed but not scheduled (logrotate.timer disabled)"; fi
  local policy=/etc/logrotate.d/ai-workstation
  if [[ ! -f "$policy" ]]; then
    report_warn "Rotation policy for bootstrap logs not installed ($policy)"
  elif ! cmp -s "$policy" "$SETUP_ROOT/security/files/logrotate-ai-workstation"; then
    report_warn "$policy differs from the repository version (re-run security/log_management.sh)"
  else
    report_pass "Bootstrap log rotation policy installed"
  fi
  if is_enabled ENABLE_SURICATA && [[ ! -f /etc/logrotate.d/suricata ]]; then
    report_warn "Suricata is enabled but its logs have no rotation policy"
  fi
  return 0
}

check_journal() {
  local storage
  storage="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | awk -F= '/^Storage=/ {v = $2} END {print v}')"
  if [[ -d /var/log/journal && "$storage" != "volatile" ]]; then
    report_pass "journald stores logs persistently (/var/log/journal)"
  else
    report_fail "journald logs are volatile and lost at reboot (set Storage=persistent)"
  fi
  report_info "Journal disk usage: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -n1 || echo unknown)"
  if report_needs_root "Journal sealing"; then
    if compgen -G "/var/log/journal/*/fss" >/dev/null; then report_pass "Journal forward-secure sealing enabled"
    else report_info "Journal sealing not set up (optional: security/log_management.sh setup-sealing)"; fi
  fi
}

check_auditd_logs() {
  package_installed auditd || return 0
  report_needs_root "auditd log settings" || return 0
  local action
  action="$(awk -F'=' '/^[[:space:]]*max_log_file_action/ {gsub(/[[:space:]]/, "", $2); print $2}' /etc/audit/auditd.conf 2>/dev/null)"
  if [[ "${action^^}" == "ROTATE" ]]; then report_pass "auditd rotates its own logs"
  else report_warn "auditd max_log_file_action is '${action:-unset}' (expected ROTATE)"; fi
}

check_log_permissions() {
  report_needs_root "Log file permissions" || return 0
  local f mode bad=0 ww=()
  for f in "${SENSITIVE_LOGS[@]}"; do
    [[ -f "$f" ]] || continue
    mode="$(stat -c '%a' "$f")"
    if (( 8#$mode & 8#0004 )); then report_warn "$f is world-readable ($mode)"; bad=$((bad + 1)); fi
  done
  while IFS= read -r -d '' f; do ww+=("$f"); done < <(find /var/log -xdev -type f -perm -0002 -print0 2>/dev/null || true)
  if ((${#ww[@]} > 0)); then report_fail "World-writable log files (anyone can forge or erase entries): ${ww[*]:0:5}"; bad=$((bad + 1)); fi
  ((bad == 0)) && report_pass "Sensitive logs are not world-readable or world-writable"
  return 0
}

check_forwarding() {
  if ! is_enabled ENABLE_REMOTE_LOGGING; then
    report_info "Logs are kept only on this machine (remote forwarding disabled); root can erase them"
    return 0
  fi
  if [[ -f /etc/rsyslog.d/60-ai-workstation-forward.conf ]] && unit_active rsyslog.service; then
    report_pass "Logs forwarded to ${LOG_REMOTE_HOST:-?}:${LOG_REMOTE_PORT:-6514} (tls=${LOG_REMOTE_TLS:-true})"
  else
    report_fail "Remote logging enabled in config but the forwarder is not configured or rsyslog is down"
  fi
  [[ "${LOG_REMOTE_TLS:-true}" == "true" ]] || report_warn "Log forwarding is unencrypted"
  return 0
}

check_fail2ban() {
  is_enabled ENABLE_FAIL2BAN || return 0
  is_enabled ENABLE_SSH_SERVER || { report_info "fail2ban enabled but unused (SSH server disabled)"; return 0; }
  if unit_active fail2ban.service; then report_pass "fail2ban protecting SSH"
  else report_fail "fail2ban enabled but not running"; fi
}

run_logging_checks() {
  report_section "Logging"
  check_rotation
  check_journal
  check_auditd_logs
  check_log_permissions
  check_forwarding
  check_fail2ban
  if [[ "${AGENT_LOG_TO_JOURNAL:-true}" == "true" ]]; then
    report_info "Agent runner events are copied to the journal (journalctl -t ai-agent-runner)"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then run_check_standalone run_logging_checks "$@"; fi
