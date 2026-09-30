#!/usr/bin/env bash
# Log retention, integrity and review.
#
#   sudo ./setup/security/log_management.sh                 configure (default)
#   sudo ./setup/security/log_management.sh review [DAYS]   digest of security events (default: 1 day)
#   sudo ./setup/security/log_management.sh setup-sealing   enable journal forward-secure sealing (interactive)
#   sudo ./setup/security/log_management.sh verify          check journal integrity (detects tampering once sealed)
#
# What "configure" does:
#   * logrotate: rotation for this project's logs (and Suricata's, if enabled);
#   * journald: persistent, compressed, size-capped storage;
#   * auditd: its own rotation and disk sizing;
#   * optional: TLS forwarding of syslog + audit events to a remote server,
#     which is the only control here that survives an attacker with root;
#   * optional: fail2ban for SSH (only when the SSH server is enabled).
#
# Local logs can always be edited or deleted by root. Sealing makes that
# detectable; remote forwarding makes it ineffective.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

LOGROTATE_SOURCE="$SETUP_ROOT/security/files/logrotate-ai-workstation"
LOGROTATE_DEST=/etc/logrotate.d/ai-workstation
SURICATA_LOGROTATE=/etc/logrotate.d/suricata
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/60-ai-workstation.conf
AUDITD_CONF=/etc/audit/auditd.conf
AUDIT_SYSLOG_PLUGIN=/etc/audit/plugins.d/syslog.conf
RSYSLOG_FORWARD=/etc/rsyslog.d/60-ai-workstation-forward.conf
FAIL2BAN_JAIL=/etc/fail2ban/jail.d/60-ai-workstation.conf

# ---------------------------------------------------------------------------
# logrotate
# ---------------------------------------------------------------------------

configure_logrotate() {
  ensure_package logrotate
  # Validation needs root: the policy's `su root root` switches user.
  if is_root && command_exists logrotate && ! logrotate --debug --state /dev/null "$LOGROTATE_SOURCE" >/dev/null 2>&1; then
    log_error "logrotate rejects $LOGROTATE_SOURCE; not installing it"
    return 1
  fi
  install_managed_file "$LOGROTATE_DEST" 0644 <"$LOGROTATE_SOURCE"

  # Suricata's eve.json grows fast; Ubuntu ships a policy, add one if absent.
  if is_enabled ENABLE_SURICATA && [[ ! -f "$SURICATA_LOGROTATE" ]]; then
    install_managed_file "$SURICATA_LOGROTATE" 0644 <<'EOF'
# Managed by ai-workstation setup (setup/security/log_management.sh)
/var/log/suricata/*.log /var/log/suricata/*.json {
    daily
    rotate 14
    maxsize 500M
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        /bin/systemctl kill -s HUP suricata.service >/dev/null 2>&1 || true
    endscript
}
EOF
  fi
  unit_exists logrotate.timer && ensure_service_enabled logrotate.timer
  return 0
}

# ---------------------------------------------------------------------------
# journald
# ---------------------------------------------------------------------------

configure_journald() {
  # Without persistent storage the journal lives in /run and vanishes at
  # reboot, taking the evidence of what happened before it with it.
  install_managed_file "$JOURNALD_DROPIN" 0644 <<EOF
# Managed by ai-workstation setup (setup/security/log_management.sh)
[Journal]
Storage=persistent
Compress=yes
Seal=yes
SystemMaxUse=${JOURNAL_MAX_USE:-2G}
MaxRetentionSec=${JOURNAL_MAX_RETENTION:-6month}
EOF
  if [[ "$FILE_CHANGED" == "true" ]]; then
    run_cmd systemctl restart systemd-journald.service
    run_cmd journalctl --flush
  fi
  if [[ -d /var/log/journal ]] && is_root; then
    local mode
    mode="$(stat -c '%a' /var/log/journal)"
    mode_exceeds "$mode" 2755 && log_warn "/var/log/journal is mode $mode; expected 2755 or tighter"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# auditd log handling
# ---------------------------------------------------------------------------

configure_auditd_logs() {
  if ! package_installed auditd; then
    log_info "auditd not installed; skipping audit log settings"
    return 0
  fi
  local changed=false key value
  # Rotate at 50 MB and keep 10 files (500 MB); warn via syslog when space
  # runs low. disk_full_action stays at Ubuntu's SUSPEND so a full disk stops
  # auditing instead of halting the workstation. log_group stays root: the
  # desktop user is in "adm", and audit logs record every root command.
  local settings=(
    "max_log_file 50"
    "num_logs 10"
    "max_log_file_action ROTATE"
    "space_left_action SYSLOG"
  )
  local entry
  for entry in "${settings[@]}"; do
    key="${entry%% *}"; value="${entry#* }"
    ensure_kv "$AUDITD_CONF" "$key" "$value" " = "
    [[ "$FILE_CHANGED" == "true" ]] && changed=true
  done
  if [[ "$changed" == "true" ]]; then
    reload_auditd || log_warn "Reload auditd to apply settings: sudo pkill -HUP -x auditd"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Remote forwarding (optional)
# ---------------------------------------------------------------------------

# Pure: prints the rsyslog forwarding config for the given settings.
render_rsyslog_forward() {
  local host="$1" port="$2" tls="$3" ca="$4"
  echo "# Managed by ai-workstation setup (setup/security/log_management.sh)"
  echo "# Forward all syslog (including audit events, via the audit syslog plugin)"
  echo "# to a remote collector. A disk-assisted queue keeps messages while the"
  echo "# collector is unreachable, so an outage does not lose events."
  if [[ "$tls" == "true" ]]; then
    cat <<EOF
action(type="omfwd" target="$host" port="$port" protocol="tcp"
       StreamDriver="gtls" StreamDriverMode="1"
       StreamDriverAuthMode="x509/name" StreamDriverPermittedPeers="$host"
       StreamDriver.CAFile="$ca"
       queue.type="LinkedList" queue.filename="aiws_forward"
       queue.maxDiskSpace="512m" queue.saveOnShutdown="on"
       action.resumeRetryCount="-1")
EOF
  else
    cat <<EOF
# WARNING: plaintext forwarding (LOG_REMOTE_TLS=false). Use only on a trusted network.
action(type="omfwd" target="$host" port="$port" protocol="tcp"
       queue.type="LinkedList" queue.filename="aiws_forward"
       queue.maxDiskSpace="512m" queue.saveOnShutdown="on"
       action.resumeRetryCount="-1")
EOF
  fi
}

configure_remote_forwarding() {
  if ! is_enabled ENABLE_REMOTE_LOGGING; then
    log_info "Remote log forwarding disabled (ENABLE_REMOTE_LOGGING=false); local logs can be erased by anyone with root"
    return 0
  fi
  local host="${LOG_REMOTE_HOST:-}" port="${LOG_REMOTE_PORT:-6514}" tls="${LOG_REMOTE_TLS:-true}" ca="${LOG_REMOTE_CA_FILE:-}"
  [[ -n "$host" ]] || { log_error "ENABLE_REMOTE_LOGGING=true but LOG_REMOTE_HOST is empty"; return 1; }
  is_positive_int "$port" || { log_error "Invalid LOG_REMOTE_PORT '$port'"; return 1; }
  if [[ "$tls" == "true" ]]; then
    [[ -n "$ca" && -f "$ca" ]] || { log_error "LOG_REMOTE_TLS=true needs LOG_REMOTE_CA_FILE pointing to the collector's CA certificate"; return 1; }
    ensure_package rsyslog rsyslog-gnutls
  else
    log_warn "Forwarding logs WITHOUT TLS: anyone on the path can read and alter them"
    ensure_package rsyslog
  fi

  render_rsyslog_forward "$host" "$port" "$tls" "$ca" | install_managed_file "$RSYSLOG_FORWARD" 0644
  local rsyslog_changed="$FILE_CHANGED"
  if [[ "$rsyslog_changed" == "true" ]] && ! is_dry_run; then
    if ! rsyslogd -N1 >>"${LOG_FILE:-/dev/null}" 2>&1; then
      log_error "rsyslog rejected the forwarding config; removing it"
      local backup="$AIWS_BACKUP_ROOT/$RUN_ID$RSYSLOG_FORWARD"
      if [[ -f "$backup" ]]; then cp -a -- "$backup" "$RSYSLOG_FORWARD"; else rm -f -- "$RSYSLOG_FORWARD"; fi
      return 1
    fi
    run_cmd systemctl restart rsyslog.service
  fi
  ensure_service_enabled rsyslog.service

  # Send audit events to syslog too, so they are forwarded with everything else.
  if package_installed auditd; then
    ensure_package audispd-plugins
    if [[ -f "$AUDIT_SYSLOG_PLUGIN" ]]; then
      ensure_kv "$AUDIT_SYSLOG_PLUGIN" active yes " = "
      [[ "$FILE_CHANGED" == "true" ]] && { reload_auditd || true; }
    elif ! is_dry_run; then
      log_warn "Audit syslog plugin not found at $AUDIT_SYSLOG_PLUGIN; audit events stay local"
    fi
  fi
  log_ok "Forwarding logs to $host:$port (tls=$tls)"
}

# ---------------------------------------------------------------------------
# fail2ban (optional, SSH only)
# ---------------------------------------------------------------------------

configure_fail2ban() {
  is_enabled ENABLE_FAIL2BAN || return 0
  if ! is_enabled ENABLE_SSH_SERVER; then
    log_info "fail2ban skipped: no SSH server is enabled, so there is nothing for it to protect"
    return 0
  fi
  ensure_package fail2ban
  # UFW already rate-limits new SSH connections; fail2ban adds bans based
  # on failed authentications read from the journal.
  install_managed_file "$FAIL2BAN_JAIL" 0644 <<EOF
# Managed by ai-workstation setup (setup/security/log_management.sh)
[DEFAULT]
backend = systemd
banaction = ufw
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ${SSH_PORT:-22}
EOF
  if [[ "$FILE_CHANGED" == "true" ]]; then run_cmd systemctl restart fail2ban.service; fi
  ensure_service_enabled fail2ban.service
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

configure() {
  require_root
  module_enabled_or_exit ENABLE_LOG_MANAGEMENT
  configure_logrotate
  configure_journald
  configure_auditd_logs
  configure_remote_forwarding
  configure_fail2ban
}

# A short, human-readable digest; it prints counts and names, never
# message bodies that might contain secrets.
review() {
  local days="${1:-1}" since
  is_positive_int "$days" || die "Usage: $0 review [DAYS]"
  require_root
  since="$(date -d "-$days days" '+%Y-%m-%d %H:%M:%S')"
  printf '%sSecurity log review since %s%s\n' "$_C_BOLD" "$since" "$_C_RESET"

  local failed sudo_n
  failed="$(journalctl --since "$since" -q --no-pager 2>/dev/null | grep -cE 'authentication failure|Failed password|FAILED SU' || true)"
  printf '  Failed authentications:      %s\n' "$failed"
  sudo_n="$(journalctl --since "$since" -q --no-pager _COMM=sudo 2>/dev/null | grep -c 'COMMAND=' || true)"
  printf '  sudo commands:               %s\n' "$sudo_n"
  printf '  UFW blocked packets:         %s\n' "$(journalctl -k --since "$since" -q --no-pager 2>/dev/null | grep -c 'UFW BLOCK' || true)"

  if command_exists ausearch; then
    local start_date start_time
    start_date="$(date -d "-$days days" '+%m/%d/%Y')"; start_time="$(date -d "-$days days" '+%H:%M:%S')"
    printf '  Audit events by key:\n'
    { ausearch --start "$start_date" "$start_time" -k aiws -i 2>/dev/null || true; } |
      grep -oE 'key=aiws_[a-z_]+' | sort | uniq -c | sort -rn | sed 's/^/      /' || true
  fi

  printf '  Agent sessions (from journal):\n'
  { journalctl --since "$since" -q --no-pager -t ai-agent-runner -o cat 2>/dev/null || true; } |
    jq -r 'select(.action == "container_exit") | "      \(.timestamp)  \(.agent_id)  \(.network)  \(.result) (exit \(.exit_code), \(.duration_s)s)"' 2>/dev/null || true

  local disk
  disk="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -n1 || true)"
  printf '  Journal disk usage:          %s\n' "${disk:-unknown}"
}

setup_sealing() {
  require_root
  is_dry_run && { log_dry "would run: journalctl --setup-keys (interactive)"; return 0; }
  [[ -t 0 && -t 1 ]] || die "Run this interactively: the verification key is shown once on screen"
  cat >&2 <<'EOF'
Forward-secure sealing (FSS) makes later tampering with journal files
detectable. journalctl will print a VERIFICATION KEY once:
  * store it OFFLINE (password manager, paper) - never on this machine;
  * anyone holding it can verify, not forge; losing it means you cannot verify.
This output is NOT written to any log.
EOF
  confirm_or_skip "Generate sealing keys now?" || return 0
  journalctl --setup-keys
  record_change CREATED /var/log/journal/fss "journal sealing key (not restored by rollback)"
  log_ok "Sealing enabled. Verify later with: sudo $0 verify --verify-key <key>"
}

verify_journal() {
  require_root
  log_info "Verifying journal files (this can take a minute)..."
  if journalctl --verify "$@"; then
    log_ok "Journal verification passed"
  else
    log_error "Journal verification reported problems (corruption or tampering). Investigate before trusting these logs."
    return 1
  fi
}

main() {
  parse_common_args "$@"
  init_module log_management
  local cmd="${MODULE_ARGS[0]:-configure}"
  case "$cmd" in
    configure) configure ;;
    review) review "${MODULE_ARGS[1]:-1}" ;;
    setup-sealing) setup_sealing ;;
    verify) verify_journal "${MODULE_ARGS[@]:1}" ;;
    *) die "Unknown command '$cmd' (configure|review|setup-sealing|verify)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
