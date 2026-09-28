#!/usr/bin/env bash
# Compare running kernel parameters with the managed sysctl file.
# Usage: ./setup/verification/check_sysctl.sh   (root not required)
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/report.sh
source "$SETUP_ROOT/lib/report.sh"

run_sysctl_checks() {
  report_section "Kernel parameters (sysctl)"
  local source="$SETUP_ROOT/hardening/files/60-ai-workstation-hardening.conf"
  local installed="/etc/sysctl.d/60-ai-workstation-hardening.conf"

  if [[ ! -f "$installed" ]]; then
    if is_enabled ENABLE_SYSCTL_HARDENING; then report_warn "Sysctl hardening file not installed ($installed)"
    else report_info "Sysctl hardening disabled in config"; fi
  elif ! cmp -s "$source" "$installed"; then
    report_warn "$installed differs from the repository version (re-run hardening/sysctl.sh)"
  fi

  local key want have rc total=0 ok=0
  while read -r key want; do
    total=$((total + 1))
    rc=0; have="$(sysctl_value "$key")" || rc=$?
    if ((rc == 1)); then
      report_info "$key not supported by this kernel"
    elif ((rc == 2)); then
      report_info "$key readable by root only (run as root to verify)"
    elif [[ "$have" == "$want" ]]; then
      ok=$((ok + 1))
    else
      report_warn "$key = $have (expected $want)"
    fi
  done < <(parse_sysctl_file "$source")
  if ((ok == total)); then report_pass "All $total hardened sysctl values in effect"
  else report_info "$ok of $total hardened sysctl values in effect"; fi

  # ip_forward is expected to be 1 when Docker/Podman/VPNs are in use; it is
  # informational only. UFW's "deny routed" governs what is forwarded.
  report_info "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?') (1 is normal with containers)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then run_check_standalone run_sysctl_checks "$@"; fi
