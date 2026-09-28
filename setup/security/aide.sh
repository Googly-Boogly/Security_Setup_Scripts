#!/usr/bin/env bash
# AIDE file integrity monitoring.
#
#   sudo ./setup/security/aide.sh            install + configure (default)
#   sudo ./setup/security/aide.sh init       build the initial baseline (slow)
#   sudo ./setup/security/aide.sh check      compare the system to the baseline
#   sudo ./setup/security/aide.sh update     build a NEW candidate baseline (not trusted yet)
#   sudo ./setup/security/aide.sh accept     promote the candidate after you reviewed the changes
#
# The baseline is never replaced automatically: if an attacker changed a
# file, auto-updating would bless the change. Review, then accept.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

AIDE_CONF=/etc/aide/aide.conf
AIDE_DB=/var/lib/aide/aide.db
AIDE_DB_NEW=/var/lib/aide/aide.db.new
# Files in aide.conf.d must match ^[a-zA-Z0-9_-]+$ (no dots) to be included.
EXCLUDES_FILE=/etc/aide/aide.conf.d/99_ai_workstation_excludes

aide_cmd() { aide --config="$AIDE_CONF" "$@"; }

install_aide() {
  ensure_package aide aide-common
  # Paths that change constantly on a dev box; left in, they bury real
  # findings in noise and people stop reading the reports.
  install_managed_file "$EXCLUDES_FILE" 0644 <<'EOF'
# Managed by ai-workstation setup (setup/security/aide.sh)
!/var/lib/docker
!/var/lib/containerd
!/var/lib/containers
!/var/lib/ai-workstation
!/var/backups/ai-workstation
!/var/log/ai-workstation-bootstrap
!/var/lib/suricata
!/home/[^/]+/agent-workspaces
!/home/[^/]+/\.cache
!/home/[^/]+/\.npm
!/home/[^/]+/\.npm-global
!/home/[^/]+/\.local/share/containers
!/home/[^/]+/\.local/state/ai-agent-runner
EOF
  local timer
  for timer in dailyaidecheck.timer aide.timer; do
    if unit_exists "$timer"; then ensure_service_enabled "$timer"; break; fi
  done

  if [[ -f "$AIDE_DB" ]]; then
    log_ok "AIDE baseline exists ($AIDE_DB)"
  elif [[ "${AIDE_INIT_DB:-false}" == "true" ]]; then
    init_db
  else
    log_warn "No AIDE baseline yet. Build it when convenient (5-20 min): sudo $0 init"
  fi
}

init_db() {
  if [[ -f "$AIDE_DB" && "$FORCE" != "true" ]]; then
    die "A baseline already exists. Use 'update' + 'accept' to change it, or 'init --force' to rebuild."
  fi
  log_info "Building AIDE baseline; this can take a while..."
  run_cmd aide_cmd --init
  is_dry_run && return 0
  backup_file "$AIDE_DB"
  mv -f -- "$AIDE_DB_NEW" "$AIDE_DB"
  chmod 0600 "$AIDE_DB"
  log_ok "Baseline written to $AIDE_DB"
}

check_db() {
  [[ -f "$AIDE_DB" ]] || die "No baseline. Run: sudo $0 init"
  local rc=0
  aide_cmd --check || rc=$?
  # Exit status is a bitmask: 1 added, 2 removed, 4 changed; >= 14 is an error.
  if ((rc == 0)); then log_ok "No changes against the baseline"
  elif ((rc < 14)); then log_warn "Differences found (exit $rc). Review them; if expected, run: sudo $0 update && sudo $0 accept"
  else log_error "AIDE failed (exit $rc)"; fi
  return "$rc"
}

update_db() {
  [[ -f "$AIDE_DB" ]] || die "No baseline. Run: sudo $0 init"
  local rc=0
  aide_cmd --update || rc=$?
  ((rc < 14)) || die "AIDE update failed (exit $rc)"
  log_warn "Candidate baseline written to $AIDE_DB_NEW. It is NOT trusted until you run: sudo $0 accept"
}

accept_db() {
  [[ -f "$AIDE_DB_NEW" ]] || die "No candidate baseline ($AIDE_DB_NEW). Run: sudo $0 update"
  confirm_or_skip "Replace the trusted AIDE baseline with $AIDE_DB_NEW? Only do this if every reported change is expected." ||
    { log_info "Baseline unchanged"; return 0; }
  is_dry_run && return 0
  local archive
  archive="$AIDE_DB.$(date +%Y%m%d-%H%M%S)"
  cp -a -- "$AIDE_DB" "$archive"
  mv -f -- "$AIDE_DB_NEW" "$AIDE_DB"
  chmod 0600 "$AIDE_DB"
  log_ok "Baseline accepted (previous one kept at $archive)"
}

main() {
  parse_common_args "$@"
  init_module aide
  require_root
  local cmd="${MODULE_ARGS[0]:-install}"
  case "$cmd" in
    install) module_enabled_or_exit ENABLE_AIDE; install_aide ;;
    init) init_db ;;
    check) check_db ;;
    update) update_db ;;
    accept) accept_db ;;
    *) die "Unknown command '$cmd' (install|init|check|update|accept)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
