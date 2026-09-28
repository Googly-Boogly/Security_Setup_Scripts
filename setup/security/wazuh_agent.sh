#!/usr/bin/env bash
# Optional Wazuh agent that ships logs and integrity events to an EXISTING
# Wazuh manager. The manager/indexer/dashboard stack is intentionally not
# installed locally: it needs several GB of RAM and belongs on a server.
#
# Requirements: WAZUH_MANAGER set in the config and reachable on TCP 1514
# (events) and 1515 (enrollment). Keep the agent version <= the manager's.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

main() {
  parse_common_args "$@"
  init_module wazuh_agent
  require_root
  module_enabled_or_exit ENABLE_WAZUH_AGENT

  [[ -n "${WAZUH_MANAGER:-}" ]] || die "ENABLE_WAZUH_AGENT=true but WAZUH_MANAGER is empty in the config"

  if package_installed wazuh-agent; then
    log_ok "wazuh-agent already installed"
  else
    ensure_apt_repo wazuh "https://packages.wazuh.com/key/GPG-KEY-WAZUH" "${WAZUH_KEY_FINGERPRINT:-}" \
      "deb [signed-by=/etc/apt/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main"
    apt_update_once
    # The package reads these variables at install time to enroll the agent.
    log_info "Installing wazuh-agent for manager $WAZUH_MANAGER"
    run_cmd env DEBIAN_FRONTEND=noninteractive WAZUH_MANAGER="$WAZUH_MANAGER" \
      WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP:-default}" apt-get install -y -q wazuh-agent
    record_change PACKAGE_INSTALLED wazuh-agent
  fi
  run_cmd systemctl daemon-reload
  ensure_service_enabled wazuh-agent.service
  log_info "Consider 'sudo apt-mark hold wazuh-agent' so it is upgraded together with the manager."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
