#!/usr/bin/env bash
# Network policies for agent containers.
#
#   offline     --network none: no interfaces except loopback.
#   restricted  internal network with no route off the host; the only way
#               out is an allowlisting HTTP(S) egress proxy (squid).
#   internet    ordinary outbound access on a dedicated bridge. No ports are
#               ever published, so nothing can connect in.
#
# Usage (as your normal user; the runner calls `ensure` automatically):
#   ./setup/agents/network_policy.sh check               validate allowlist, show state (default)
#   ./setup/agents/network_policy.sh ensure MODE         create networks / proxy for MODE
#   ./setup/agents/network_policy.sh reload              recreate the proxy after editing the allowlist
#   ./setup/agents/network_policy.sh logs                show proxy access log (allowed/denied requests)
#   ./setup/agents/network_policy.sh teardown            remove proxy and agent networks
# Add --runtime docker|podman to choose the runtime (default: config / auto).
#
# Limits: container networking is not a hostile-code boundary on its own.
# A kernel or runtime escape bypasses all of this. "internet" mode can reach
# your LAN; use "restricted" for untrusted work.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/agent.sh
source "$SETUP_ROOT/lib/agent.sh"

show_state() {
  local rt="$1" net
  for net in "$AGENT_NET_INTERNET" "$AGENT_NET_RESTRICTED" "$AGENT_NET_EGRESS"; do
    if network_exists "$rt" "$net"; then log_info "$rt network present: $net"; else log_info "$rt network not created yet: $net"; fi
  done
  local state
  state="$("$rt" inspect -f '{{ .State.Status }}' "$AGENT_PROXY_NAME" 2>/dev/null || true)"
  log_info "Egress proxy ($AGENT_PROXY_NAME): ${state:-not created}"
}

main() {
  local runtime_pref=""
  local args=() a
  while (($#)); do
    case "$1" in
      --runtime) runtime_pref="${2:?--runtime needs a value}"; shift ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  parse_common_args "${args[@]}"
  init_module network_policy
  local cmd="${MODULE_ARGS[0]:-check}"

  if [[ "$cmd" == "check" ]]; then
    module_enabled_or_exit ENABLE_AGENT_SANDBOX
    local entries
    entries="$(render_allowlist "$(agent_allowlist_file)")" || die "Allowlist invalid: $(agent_allowlist_file)"
    log_ok "Restricted-mode allowlist valid ($(grep -c . <<<"$entries" || true) entries): $(agent_allowlist_file)"
    log_info "Default agent network mode: ${AGENT_DEFAULT_NETWORK:-offline}"
    if is_root; then
      log_info "Networks and the proxy are created per user on first use (rootless Podman keeps them per user)."
      return 0
    fi
  fi

  local rt
  rt="$(select_agent_runtime "$runtime_pref")" || die "No container runtime found (install Docker or Podman)"
  is_root && [[ "$rt" == podman ]] && log_warn "Running as root manages ROOTFUL podman networks; run as your user instead."
  runtime_usable "$rt" || exit 1

  case "$cmd" in
    check) show_state "$rt" ;;
    ensure)
      a="${MODULE_ARGS[1]:-}"
      is_valid_network_mode "$a" || die "Usage: $0 ensure offline|restricted|internet"
      ensure_agent_network "$rt" "$a"
      log_ok "Network mode '$a' ready ($rt)" ;;
    reload)
      run_cmd "$rt" rm -f "$AGENT_PROXY_NAME"
      ensure_agent_network "$rt" restricted
      log_ok "Egress proxy recreated with the current allowlist" ;;
    logs) "$rt" logs --tail "${MODULE_ARGS[1]:-100}" "$AGENT_PROXY_NAME" ;;
    teardown)
      confirm_or_skip "Remove the egress proxy and the agent networks? (running agents lose network access)" || exit 0
      run_cmd "$rt" rm -f "$AGENT_PROXY_NAME" || true
      for a in "$AGENT_NET_RESTRICTED" "$AGENT_NET_EGRESS" "$AGENT_NET_INTERNET"; do
        if network_exists "$rt" "$a"; then run_cmd "$rt" network rm "$a" || true; fi
      done ;;
    *) die "Unknown command '$cmd' (check|ensure|reload|logs|teardown)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
