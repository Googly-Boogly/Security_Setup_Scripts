#!/usr/bin/env bash
# shellcheck disable=SC2034  # library: globals are read by the scripts that source it
# Expected maximum permissions, shared by hardening/permissions.sh (fixes)
# and verification/check_permissions.sh (checks) so they cannot drift apart.

[[ -n "${_AIWS_PERMPOLICY_LOADED:-}" ]] && return 0
_AIWS_PERMPOLICY_LOADED=1

# path:max-mode
SENSITIVE_SYSTEM_FILES=(
  /etc/passwd:0644
  /etc/group:0644
  /etc/shadow:0640
  /etc/gshadow:0640
  /etc/sudoers:0440
  /etc/ssh/sshd_config:0644
  /etc/crontab:0644
  /etc/docker/daemon.json:0644
  /etc/audit/auditd.conf:0640
  /etc/default/ufw:0644
  /root:0700
)

# Relative to the user's home. path:max-mode
SENSITIVE_USER_PATHS=(
  .ssh:0700
  .ssh/authorized_keys:0644
  .ssh/config:0644
  .gnupg:0700
  .aws:0700
  .aws/credentials:0600
  .kube/config:0600
  .docker/config.json:0600
  .netrc:0600
  .git-credentials:0600
  .pypirc:0600
  .npmrc:0600
  .config/gh/hosts.yml:0600
  .local/state/ai-agent-runner:0700
  agent-workspaces:0700
)

WORLD_WRITABLE_SCAN_DIRS=(/etc /usr/local)

# NUL-separated: world-writable regular files, and world-writable
# directories without the sticky bit, under the scan dirs.
find_world_writable_system_paths() {
  find "${WORLD_WRITABLE_SCAN_DIRS[@]}" -xdev \
    \( \( -type f -perm -0002 \) -o \( -type d -perm -0002 ! -perm -1000 \) \) \
    -print0 2>/dev/null || true
}
