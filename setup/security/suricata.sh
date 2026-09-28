#!/usr/bin/env bash
# Optional Suricata network IDS in passive mode.
#
# Runs af-packet capture on one interface (IDS only, no inline/IPS mode), so a
# bad rule or a crash can never drop your traffic. The interface is detected
# from the default route unless SURICATA_INTERFACE is set; if you move
# between Wi-Fi and Ethernet, re-run this module.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DROPIN=/etc/systemd/system/suricata.service.d/10-ai-workstation.conf

pick_interface() {
  local iface="${SURICATA_INTERFACE:-}"
  [[ -n "$iface" ]] || iface="$(default_route_interface)"
  [[ -n "$iface" ]] || { log_error "No default route; set SURICATA_INTERFACE in the config"; return 1; }
  [[ -e "/sys/class/net/$iface" ]] || { log_error "Interface '$iface' does not exist"; return 1; }
  case "$iface" in
    lo|docker*|br-*|veth*|virbr*|podman*|cni*)
      log_error "Refusing to monitor virtual interface '$iface'; set SURICATA_INTERFACE to a physical one"; return 1 ;;
  esac
  printf '%s' "$iface"
}

install_rule_updates() {
  install_managed_file /etc/systemd/system/suricata-update.service 0644 <<'EOF'
# Managed by ai-workstation setup (setup/security/suricata.sh)
[Unit]
Description=Update Suricata rules (ET Open)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/suricata-update --quiet
ExecStartPost=/bin/systemctl try-restart suricata.service
EOF
  local svc_changed="$FILE_CHANGED"
  install_managed_file /etc/systemd/system/suricata-update.timer 0644 <<'EOF'
# Managed by ai-workstation setup (setup/security/suricata.sh)
[Unit]
Description=Daily Suricata rule update

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  [[ "$svc_changed" == "true" || "$FILE_CHANGED" == "true" ]] && run_cmd systemctl daemon-reload
  ensure_service_enabled suricata-update.timer
}

main() {
  parse_common_args "$@"
  init_module suricata
  require_root
  module_enabled_or_exit ENABLE_SURICATA

  ensure_package suricata suricata-update
  local iface
  iface="$(pick_interface)"
  log_info "Monitoring interface: $iface (passive af-packet IDS)"

  # Type=simple without -D keeps systemd in charge of the process regardless
  # of how the packaged unit was written.
  install_managed_file "$DROPIN" 0644 <<EOF
# Managed by ai-workstation setup (setup/security/suricata.sh)
[Service]
Type=simple
ExecStart=
ExecStart=/usr/bin/suricata -c /etc/suricata/suricata.yaml --pidfile /run/suricata.pid --af-packet=$iface
EOF
  local unit_changed="$FILE_CHANGED"
  is_dry_run && { install_rule_updates; return 0; }

  if [[ ! -s /var/lib/suricata/rules/suricata.rules ]]; then
    log_info "Downloading initial ruleset (ET Open) with suricata-update"
    run_cmd suricata-update --quiet
  fi
  if ! run_cmd suricata -T -c /etc/suricata/suricata.yaml --af-packet="$iface"; then
    log_error "Suricata configuration test failed; not (re)starting it. See the log for details."
    return 1
  fi
  [[ "$unit_changed" == "true" ]] && run_cmd systemctl daemon-reload
  ensure_service_enabled suricata.service
  [[ "$unit_changed" == "true" ]] && run_cmd systemctl restart suricata.service
  install_rule_updates

  [[ -f /etc/logrotate.d/suricata ]] || log_warn "No logrotate policy for Suricata logs (/var/log/suricata); eve.json can grow large"
  log_info "Alerts: sudo tail -f /var/log/suricata/fast.log   Full events: /var/log/suricata/eve.json"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
