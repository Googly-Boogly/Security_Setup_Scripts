#!/usr/bin/env bash
# Host-side support for agent resource limits.
#
# Per-agent limits (memory, CPU, PIDs, timeout) are applied by
# agent_runner.sh on every container. This module makes them effective:
#   * checks cgroup v2 (needed for reliable limits);
#   * creates ai-agents.slice, an aggregate ceiling for ALL Docker agent
#     containers together, so ten agents cannot jointly exhaust the machine;
#   * for rootless Podman, delegates the cpu/io controllers to user sessions
#     (without this, --cpus is silently ignored for rootless containers).
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SLICE_UNIT=/etc/systemd/system/ai-agents.slice
DELEGATE_DROPIN=/etc/systemd/system/user@.service.d/60-ai-workstation-delegate.conf

install_slice() {
  {
    echo "# Managed by ai-workstation setup (setup/agents/resource_limits.sh)"
    echo "[Unit]"
    echo "Description=Aggregate resource ceiling for AI agent containers"
    echo "Before=slices.target"
    echo
    echo "[Slice]"
    [[ -n "${AGENTS_SLICE_MEMORY_MAX:-}" ]] && echo "MemoryMax=$AGENTS_SLICE_MEMORY_MAX"
    [[ -n "${AGENTS_SLICE_CPU_QUOTA:-}" ]] && echo "CPUQuota=$AGENTS_SLICE_CPU_QUOTA"
    [[ -n "${AGENTS_SLICE_TASKS_MAX:-}" ]] && echo "TasksMax=$AGENTS_SLICE_TASKS_MAX"
    true
  } | install_managed_file "$SLICE_UNIT" 0644
  if [[ "$FILE_CHANGED" == "true" ]]; then run_cmd systemctl daemon-reload; fi
}

ensure_podman_delegation() {
  command_exists podman || is_dry_run || return 0
  require_target_user || return 0
  local uid controllers
  uid="$(id -u "$TARGET_USER")"
  controllers="$(cat "/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers" 2>/dev/null || true)"
  if [[ " $controllers " == *" cpu "* && " $controllers " == *" memory "* && " $controllers " == *" pids "* ]]; then
    log_ok "cgroup controllers already delegated to $TARGET_USER: $controllers"
    return 0
  fi
  install_managed_file "$DELEGATE_DROPIN" 0644 <<'EOF'
# Managed by ai-workstation setup (setup/agents/resource_limits.sh)
# Let rootless containers enforce CPU, memory, IO and PID limits.
[Service]
Delegate=cpu cpuset io memory pids
EOF
  if [[ "$FILE_CHANGED" == "true" ]]; then
    run_cmd systemctl daemon-reload
    log_warn "Log out and back in (or reboot) for rootless Podman CPU limits to take effect"
  fi
}

main() {
  parse_common_args "$@"
  init_module resource_limits
  require_root
  module_enabled_or_exit ENABLE_AGENT_SANDBOX

  if cgroup_v2_enabled; then
    log_ok "cgroup v2 is active"
  else
    log_warn "cgroup v2 is not active; memory/CPU/PID limits may be partially enforced"
  fi
  install_slice
  ensure_podman_delegation
  log_info "Per-agent defaults: memory=${AGENT_MAX_MEMORY} cpus=${AGENT_MAX_CPUS} pids=${AGENT_MAX_PIDS} timeout=${AGENT_TIMEOUT}s"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
