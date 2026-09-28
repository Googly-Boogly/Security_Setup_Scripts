#!/usr/bin/env bash
# Host firewall with UFW: deny incoming, allow outgoing, deny routed.
#
# Outbound traffic (web, apt, DNS, VPN clients, git) is locally originated and
# unaffected. Replies to it are allowed by connection tracking, so no inbound
# port 443/80/53 rule is ever needed for normal use. Docker and libvirt
# install their own forwarding rules, so "deny routed" does not break them.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

UFW_FILES=(/etc/default/ufw /etc/ufw/ufw.conf /etc/ufw/user.rules /etc/ufw/user6.rules)

ufw_active() {
  local status
  status="$(ufw status 2>/dev/null || true)"
  [[ "$status" == "Status: active"* ]]
}

# Value of KEY="VALUE" in /etc/default/ufw.
ufw_default() {
  sed -nE "s/^$1=\"?([^\"]*)\"?\$/\\1/p" /etc/default/ufw 2>/dev/null | tail -n 1
}

# Report existing inbound allows so contradictory rules are visible rather
# than silently kept or silently deleted.
inspect_existing_rules() {
  local rules line
  is_root || return 0
  rules="$(ufw status 2>/dev/null | awk '/ALLOW|LIMIT/ && !/ALLOW OUT/' || true)"
  if [[ -z "$rules" ]]; then
    log_ok "No existing inbound allow rules"
    return 0
  fi
  log_info "Existing inbound rules:"
  while IFS= read -r line; do
    printf '    %s\n' "$line" >&2
    if [[ "$line" =~ (^|[^0-9])22(/tcp)?[[:space:]] || "$line" == OpenSSH* ]] && ! is_enabled ENABLE_SSH_SERVER; then
      log_warn "Rule allows SSH but ENABLE_SSH_SERVER=false. Review: sudo ufw status numbered; remove: sudo ufw delete <n>"
    fi
    if [[ "$line" =~ ^(80|443)(/tcp)?[[:space:]] ]]; then
      log_warn "Rule opens port ${BASH_REMATCH[1]} inbound. Browsing does NOT need this; remove it unless you serve web traffic."
    fi
  done <<<"$rules"
}

apply_defaults() {
  # UFW reads these from /etc/default/ufw; checking the file avoids
  # re-running commands that would reload the firewall for nothing.
  [[ "$(ufw_default DEFAULT_INPUT_POLICY)" == "DROP" ]] || run_cmd ufw default deny incoming
  [[ "$(ufw_default DEFAULT_OUTPUT_POLICY)" == "ACCEPT" ]] || run_cmd ufw default allow outgoing
  [[ "$(ufw_default DEFAULT_FORWARD_POLICY)" == "DROP" ]] || run_cmd ufw default deny routed
}

apply_rules() {
  local rule
  if is_enabled ENABLE_SSH_SERVER; then
    # "limit" = deny an address after 6 connection attempts in 30 seconds.
    if [[ -n "${SSH_ALLOW_FROM:-}" ]]; then
      run_cmd ufw limit from "$SSH_ALLOW_FROM" to any port "$SSH_PORT" proto tcp comment 'ai-workstation ssh'
    else
      log_warn "SSH is reachable from any address (rate-limited). Set SSH_ALLOW_FROM to restrict it."
      run_cmd ufw limit "$SSH_PORT/tcp" comment 'ai-workstation ssh'
    fi
  fi
  for rule in "${FIREWALL_ALLOW_INBOUND[@]}"; do
    # shellcheck disable=SC2086  # rule is an intentional word list for ufw
    run_cmd ufw allow $rule
  done
}

main() {
  parse_common_args "$@"
  init_module firewall
  require_root
  module_enabled_or_exit ENABLE_FIREWALL

  ensure_package ufw
  if ! command_exists ufw; then
    is_dry_run && { log_dry "ufw not installed yet; remaining steps depend on it"; return 0; }
    die "ufw is not available"
  fi

  local was_active=false
  ufw_active && was_active=true

  # Enabling a deny-incoming firewall over SSH keeps the current session
  # (conntrack) but blocks new logins: an easy way to lock yourself out.
  if [[ "$was_active" == "false" ]] && in_ssh_session && ! is_enabled ENABLE_SSH_SERVER; then
    confirm_or_skip "You are on SSH but ENABLE_SSH_SERVER=false: enabling UFW will block NEW SSH logins. Continue?" ||
      { log_warn "Firewall left unchanged to avoid lockout"; return 0; }
  fi

  inspect_existing_rules

  local f
  for f in "${UFW_FILES[@]}"; do backup_file "$f"; done
  if ! is_dry_run && ! manifest_has UFW_STATE ufw any; then
    record_change UFW_STATE ufw "$([[ "$was_active" == "true" ]] && echo active || echo inactive)"
  fi

  # With IPV6=no, UFW does not filter IPv6 at all: inbound IPv6 would be open.
  ensure_kv /etc/default/ufw IPV6 yes
  local ipv6_changed="$FILE_CHANGED"

  apply_defaults
  apply_rules
  run_cmd ufw logging "${UFW_LOGGING:-low}"

  if [[ "$was_active" == "true" ]]; then
    log_ok "UFW already active"
    if [[ "$ipv6_changed" == "true" ]]; then run_cmd ufw reload; fi
  else
    run_cmd ufw --force enable
  fi

  log_info "Note: Docker-published ports bypass UFW; see DOCKER_PUBLISH_LOCALHOST_ONLY in the config."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
