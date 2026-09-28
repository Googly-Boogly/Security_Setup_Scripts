#!/usr/bin/env bash
# Verify container runtime configuration and running containers.
# Usage: sudo ./setup/verification/check_containers.sh
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/report.sh
source "$SETUP_ROOT/lib/report.sh"

DAEMON_JSON=/etc/docker/daemon.json

check_docker_daemon() {
  local exposed=0 cfg="{}"
  [[ -r "$DAEMON_JSON" ]] && cfg="$(cat "$DAEMON_JSON")"
  if ! jq -e . >/dev/null 2>&1 <<<"$cfg"; then report_fail "$DAEMON_JSON is not valid JSON"; cfg="{}"; fi

  if jq -e '(.hosts // []) | map(select(startswith("tcp://"))) | length > 0' >/dev/null <<<"$cfg"; then
    report_fail "Docker API exposed over TCP in $DAEMON_JSON"; exposed=1
  fi
  if systemctl cat docker.service 2>/dev/null | grep -qE '^ExecStart=.*-H[= ]*tcp://'; then
    report_fail "Docker API exposed over TCP in the docker.service unit"; exposed=1
  fi
  if is_root && ss -H -ltnp 2>/dev/null | grep -q '"dockerd"'; then
    report_fail "dockerd is listening on a TCP port"; exposed=1
  fi
  ((exposed == 0)) && report_pass "Docker daemon not exposed over TCP"

  local insecure
  insecure="$(jq -r '(."insecure-registries" // []) | join(", ")' <<<"$cfg")"
  if [[ -n "$insecure" ]]; then report_warn "Insecure registries configured: $insecure"; else report_pass "No insecure registries configured"; fi

  if [[ "$(jq -r '.ip // empty' <<<"$cfg")" == "127.0.0.1" ]]; then
    report_pass "Published container ports default to 127.0.0.1"
  else
    report_warn "Published container ports bind to all interfaces and bypass UFW (set DOCKER_PUBLISH_LOCALHOST_ONLY=true)"
  fi
  if [[ "$(jq -r '."live-restore" // false' <<<"$cfg")" == "true" ]]; then report_info "live-restore enabled"; fi

  local sock=/var/run/docker.sock mode
  if [[ -S "$sock" ]]; then
    mode="$(stat -c '%a' "$sock")"
    if mode_exceeds "$mode" 0660; then report_fail "$sock has mode $mode (anyone can control Docker)"
    else report_pass "Docker socket permissions $mode"; fi
  fi
  local members
  members="$(getent group docker | cut -d: -f4)"
  if [[ -n "$members" ]]; then report_warn "docker group members (root-equivalent): $members"
  else report_pass "No users in the docker group"; fi
}

# Inspect running Docker containers for dangerous settings.
check_running_containers() {
  report_needs_root "Running Docker containers" || return 0
  local ids
  ids="$(docker ps -q 2>/dev/null || true)"
  if [[ -z "$ids" ]]; then report_info "No running Docker containers"; return 0; fi

  local findings
  # shellcheck disable=SC2086  # ids is a whitespace-separated list
  findings="$(docker inspect $ids | jq -r '
    .[] | . as $c
    | ($c.Name | ltrimstr("/")) as $n
    | ($c.Config.Labels["ai-agent.managed"] // "") as $agent
    | [
        (if $c.HostConfig.Privileged then "FAIL|\($n): privileged container" else empty end),
        ($c.Mounts[]? | select(.Source | test("docker\\.sock$")) | "FAIL|\($n): Docker socket mounted (\(.Source))"),
        (if $c.HostConfig.NetworkMode == "host" then "WARN|\($n): uses host network" else empty end),
        (if $c.HostConfig.PidMode == "host" then "WARN|\($n): shares host PID namespace" else empty end),
        (($c.HostConfig.CapAdd // [])[] | select(. == "SYS_ADMIN" or . == "ALL" or . == "CAP_SYS_ADMIN")
          | "WARN|\($n): adds capability \(.)"),
        (if $agent == "true" then
          (if $c.HostConfig.ReadonlyRootfs != true then "FAIL|\($n): agent without read-only root" else empty end),
          (if (($c.HostConfig.CapDrop // []) | index("ALL")) == null then "FAIL|\($n): agent keeps capabilities" else empty end),
          (if (($c.HostConfig.SecurityOpt // []) | map(startswith("no-new-privileges")) | any) | not then "FAIL|\($n): agent without no-new-privileges" else empty end),
          (if ($c.HostConfig.Memory // 0) == 0 then "FAIL|\($n): agent without memory limit" else empty end),
          (if ($c.HostConfig.PidsLimit // 0) <= 0 then "FAIL|\($n): agent without PID limit" else empty end),
          "INFO|\($n): agent container, network \($c.HostConfig.NetworkMode)"
         else empty end)
      ] | .[]')"
  local line fails=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "${line%%|*}" in
      FAIL) report_fail "${line#*|}"; fails=$((fails + 1)) ;;
      WARN) report_warn "${line#*|}" ;;
      *) report_info "${line#*|}" ;;
    esac
  done <<<"$findings"
  ((fails == 0)) && report_pass "No unexpected privileged containers"
  return 0
}

check_agent_sandbox() {
  is_enabled ENABLE_AGENT_SANDBOX || { report_info "Agent sandbox disabled in config"; return 0; }
  if [[ -f /etc/systemd/system/ai-agents.slice ]]; then report_pass "Aggregate agent resource slice installed"
  else report_warn "ai-agents.slice not installed (run agents/resource_limits.sh)"; fi
  if command_exists podman; then
    report_pass "Podman available (rootless agent runtime)"
    if [[ -n "$TARGET_USER" ]] && ! grep -qs "^$TARGET_USER:" /etc/subuid; then
      report_warn "$TARGET_USER has no /etc/subuid range; rootless Podman will not work"
    fi
  fi
  if [[ -n "$TARGET_HOME" && -d "$TARGET_HOME/agent-workspaces" ]]; then
    local mode
    mode="$(stat -c '%a' "$TARGET_HOME/agent-workspaces")"
    if mode_exceeds "$mode" 0700; then report_warn "agent-workspaces is mode $mode (expected 700)"
    else report_pass "Agent workspaces are private ($mode)"; fi
  fi
  report_info "Agent limits: memory=${AGENT_MAX_MEMORY} cpus=${AGENT_MAX_CPUS} pids=${AGENT_MAX_PIDS} timeout=${AGENT_TIMEOUT}s default-network=${AGENT_DEFAULT_NETWORK}"
}

run_containers_checks() {
  report_section "Containers"
  if command_exists docker || [[ -f "$DAEMON_JSON" ]]; then
    check_docker_daemon
    check_running_containers
  else
    report_info "Docker not installed"
  fi
  check_agent_sandbox
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then run_check_standalone run_containers_checks "$@"; fi
