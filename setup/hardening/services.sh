#!/usr/bin/env bash
# Review listening and enabled services.
#
# Only services in SERVICES_TO_DISABLE (short, uncontroversial list in the
# config) are disabled automatically. Everything else is reported for a
# human to decide: guessing wrong here breaks printers, VPNs or databases.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Commonly present services worth a conscious decision on a workstation.
REVIEW_SERVICES=(
  avahi-daemon.service cups.service rpcbind.service nfs-server.service
  smbd.service nmbd.service apache2.service nginx.service mysql.service
  mariadb.service postgresql.service redis-server.service mongod.service
  vsftpd.service snmpd.service xrdp.service vncserver.service
  rsync.service
)

# Ports that are normal to see bound on all interfaces on a client machine.
is_expected_listener() {
  local proto="$1" port="$2"
  [[ "$proto" == "udp" && ( "$port" == "68" || "$port" == "546" || "$port" == "5353" ) ]]
}

report_listeners() {
  local proto state recvq sendq local_addr peer process port exposed=0
  if ! is_root; then log_info "Run as root to see which process owns each listening socket"; fi
  while read -r proto state recvq sendq local_addr peer process; do
    [[ -n "$local_addr" ]] || continue
    is_loopback_address "$local_addr" && continue
    port="${local_addr##*:}"
    if is_expected_listener "$proto" "$port"; then
      log_info "Expected client listener: $proto $local_addr ${process:-} (DHCP/mDNS)"
      continue
    fi
    exposed=$((exposed + 1))
    log_warn "Listening on a non-loopback address: $proto $local_addr ${process:-}"
  done < <(ss -H -tulpn 2>/dev/null || true)
  if ((exposed == 0)); then
    log_ok "No unexpected services listening on external interfaces"
  else
    log_warn "$exposed listener(s) reachable from the network if the firewall allowed it. Bind dev servers to 127.0.0.1."
  fi
  : "$state" "$recvq" "$sendq" "$peer"
}

disable_safe_services() {
  local unit
  for unit in "${SERVICES_TO_DISABLE[@]}"; do
    unit_exists "$unit" || continue
    if unit_enabled "$unit" || unit_active "$unit"; then
      log_info "Disabling $unit (listed in SERVICES_TO_DISABLE)"
      disable_unit "$unit"
    else
      log_ok "Already disabled: $unit"
    fi
  done
}

report_review_services() {
  local unit found=0
  for unit in "${REVIEW_SERVICES[@]}"; do
    unit_exists "$unit" || continue
    if unit_enabled "$unit"; then
      log_warn "Enabled, review whether you need it: $unit (disable: sudo systemctl disable --now $unit)"
      found=$((found + 1))
    fi
  done
  ((found == 0)) && log_ok "No commonly unnecessary server daemons enabled"
  return 0
}

main() {
  parse_common_args "$@"
  init_module services
  require_root
  module_enabled_or_exit ENABLE_SERVICE_REVIEW

  report_listeners
  disable_safe_services
  report_review_services

  local failed
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' || true)"
  [[ -n "$failed" ]] && log_warn "Failed systemd units (not changed): $failed"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
