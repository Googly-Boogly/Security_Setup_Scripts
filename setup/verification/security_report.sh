#!/usr/bin/env bash
# Workstation security report: runs every check_*.sh and summarises.
#
#   sudo ./setup/verification/security_report.sh
#
# Exit status is 1 if any check FAILed, so it can be used from cron/CI.
# The report checks configuration against this project's expectations. It
# does not, and cannot, prove that the system is secure.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/report.sh
source "$SETUP_ROOT/lib/report.sh"

CHECKS=(check_firewall check_services check_sysctl check_permissions check_containers)

main() {
  parse_common_args "$@"
  LOG_MODULE="report"
  load_config
  resolve_target_user
  detect_os || true

  local check
  for check in "${CHECKS[@]}"; do
    # shellcheck source=/dev/null
    source "$SETUP_ROOT/verification/$check.sh"
  done

  if is_root && ! is_dry_run; then
    install -d -m 0750 "$AIWS_LOG_DIR"
    REPORT_FILE="$AIWS_LOG_DIR/security-report-$(date +%Y%m%d-%H%M%S).txt"
    install -m 0640 /dev/null "$REPORT_FILE"
  fi

  printf '%sAI workstation security report%s\n' "$_C_BOLD" "$_C_RESET"
  printf 'Host: %s | %s | kernel %s | %s\n' "$(hostname)" "${OS_PRETTY_NAME:-unknown OS}" "$(uname -r)" "$(date -Is)"
  is_root || printf 'Note: not running as root; some checks are skipped.\n'
  [[ -n "$REPORT_FILE" ]] && printf 'Host: %s | %s | %s\n' "$(hostname)" "${OS_PRETTY_NAME:-}" "$(date -Is)" >>"$REPORT_FILE"

  run_firewall_checks
  run_services_checks
  run_sysctl_checks
  run_permissions_checks
  run_containers_checks

  report_summary
  echo "This report checks configuration only. Passing checks reduce risk; they do not make a system secure."
  [[ -n "$REPORT_FILE" ]] && echo "Saved to $REPORT_FILE"
  ((REPORT_FAIL == 0))
}

main "$@"
