#!/usr/bin/env bash
# Verify UFW state and inbound exposure. Usage: sudo ./setup/verification/check_firewall.sh
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/report.sh
source "$SETUP_ROOT/lib/report.sh"

run_firewall_checks() {
  report_section "Firewall"
  if ! command_exists ufw; then report_fail "UFW is not installed"; return 0; fi
  report_needs_root "UFW status" || return 0

  local status
  status="$(ufw status verbose 2>/dev/null || true)"
  if [[ "$status" == "Status: active"* ]]; then report_pass "UFW enabled"; else report_fail "UFW is not active"; fi

  local defaults
  defaults="$(grep -m1 '^Default:' <<<"$status" || true)"
  if [[ -z "$defaults" ]]; then
    report_warn "Could not read UFW default policies"
  else
    if [[ "$defaults" =~ (deny|reject)\ \(incoming\) ]]; then report_pass "Default inbound policy: ${BASH_REMATCH[1]}"
    else report_fail "Default inbound policy is not deny ($defaults)"; fi
    if [[ "$defaults" =~ (deny|reject|disabled)\ \(routed\) ]]; then report_pass "Default routed policy: ${BASH_REMATCH[1]}"
    else report_warn "Default routed policy allows forwarding ($defaults)"; fi
    [[ "$defaults" =~ allow\ \(outgoing\) ]] && report_info "Outbound traffic allowed (expected for a workstation)"
  fi

  if grep -qsx 'IPV6=yes' /etc/default/ufw; then report_pass "UFW filters IPv6"
  else report_fail "UFW IPv6 filtering disabled (IPV6=no in /etc/default/ufw): inbound IPv6 is unfiltered"; fi

  local rules
  rules="$(awk '/ALLOW|LIMIT/ && !/ALLOW OUT/' <<<"$status" || true)"
  if [[ -z "$rules" ]]; then
    report_pass "No inbound allow rules"
  else
    local line
    while IFS= read -r line; do
      if [[ "$line" =~ (^|[^0-9])(22|${SSH_PORT:-22})(/tcp)?[[:space:]] ]] && ! is_enabled ENABLE_SSH_SERVER; then
        report_warn "SSH port allowed but ENABLE_SSH_SERVER=false: $line"
      elif [[ "$line" == *LIMIT* ]]; then
        report_info "Rate-limited inbound rule: $line"
      else
        report_warn "Inbound allow rule (confirm it is needed): $line"
      fi
    done <<<"$rules"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then run_check_standalone run_firewall_checks "$@"; fi
