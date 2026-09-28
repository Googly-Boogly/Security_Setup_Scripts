#!/usr/bin/env bash
# shellcheck disable=SC2034  # library: globals are read by the scripts that source it
# Result reporting for verification scripts: [PASS] / [WARN] / [FAIL] / [INFO].
# Source this file; do not execute it.

[[ -n "${_AIWS_REPORT_LOADED:-}" ]] && return 0
_AIWS_REPORT_LOADED=1

REPORT_PASS=0
REPORT_WARN=0
REPORT_FAIL=0
REPORT_INFO=0
: "${REPORT_FILE:=}"

_report() {
  local status="$1" color="$2"; shift 2
  printf '%s[%s]%s %s\n' "$color" "$status" "$_C_RESET" "$*"
  if [[ -n "$REPORT_FILE" ]]; then
    printf '[%s] %s\n' "$status" "$*" >>"$REPORT_FILE" 2>/dev/null || true
  fi
}

report_pass() { REPORT_PASS=$((REPORT_PASS + 1)); _report PASS "$_C_GREEN" "$@"; }
report_warn() { REPORT_WARN=$((REPORT_WARN + 1)); _report WARN "$_C_YELLOW" "$@"; }
report_fail() { REPORT_FAIL=$((REPORT_FAIL + 1)); _report FAIL "$_C_RED" "$@"; }
report_info() { REPORT_INFO=$((REPORT_INFO + 1)); _report INFO "$_C_BLUE" "$@"; }

report_section() {
  printf '\n%s-- %s --%s\n' "$_C_BOLD" "$*" "$_C_RESET"
  if [[ -n "$REPORT_FILE" ]]; then printf '\n-- %s --\n' "$*" >>"$REPORT_FILE" 2>/dev/null || true; fi
}

report_summary() {
  local line="Summary: ${REPORT_PASS} pass, ${REPORT_WARN} warn, ${REPORT_FAIL} fail, ${REPORT_INFO} info"
  printf '\n%s%s%s\n' "$_C_BOLD" "$line" "$_C_RESET"
  if [[ -n "$REPORT_FILE" ]]; then printf '\n%s\n' "$line" >>"$REPORT_FILE" 2>/dev/null || true; fi
}

# Some checks need root to read state (ufw status, auditctl, other users' files).
report_needs_root() {
  is_root && return 0
  report_info "$1: skipped (needs root to inspect)"
  return 1
}

# Standalone entry point shared by check_*.sh scripts.
run_check_standalone() {
  local fn="$1"; shift
  parse_common_args "$@"
  LOG_MODULE="verify"
  load_config
  resolve_target_user
  detect_os || true
  "$fn"
  report_summary
  ((REPORT_FAIL == 0))
}
