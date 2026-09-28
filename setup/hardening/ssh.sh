#!/usr/bin/env bash
# SSH server policy.
#
# ENABLE_SSH_SERVER=false (default): an installed sshd is stopped and
# disabled, unless we are running inside an SSH session (lockout guard).
# The package is never removed.
#
# ENABLE_SSH_SERVER=true: install openssh-server and add a drop-in with a
# hardened configuration. The firewall module adds a rate-limited rule.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SSHD_DROPIN="/etc/ssh/sshd_config.d/10-ai-workstation.conf"
SSH_UNITS=(ssh.socket ssh.service)

disable_sshd() {
  package_installed openssh-server || { log_ok "openssh-server is not installed"; return 0; }
  local unit active_units=()
  for unit in "${SSH_UNITS[@]}"; do
    unit_exists "$unit" || continue
    if unit_enabled "$unit" || unit_active "$unit"; then active_units+=("$unit"); fi
  done
  if ((${#active_units[@]} == 0)); then
    log_ok "openssh-server is installed but disabled"
    return 0
  fi
  if [[ "${SSH_DISABLE_WHEN_NOT_ENABLED:-true}" != "true" ]]; then
    log_warn "SSH server is running but ENABLE_SSH_SERVER=false (left running: SSH_DISABLE_WHEN_NOT_ENABLED=false)"
    return 0
  fi
  if in_ssh_session; then
    log_warn "SSH server is running and you are connected over SSH; not disabling it. Set ENABLE_SSH_SERVER=true to harden it instead."
    return 0
  fi
  for unit in "${active_units[@]}"; do
    log_info "Disabling $unit (ENABLE_SSH_SERVER=false)"
    disable_unit "$unit"
  done
}

# Modern algorithms only. ML-KEM hybrid key exchange (post-quantum) is used
# when the installed OpenSSH supports it (9.9+).
crypto_settings() {
  local version major minor kex
  version="$(openssh_version)"
  major="${version%%.*}"; minor="${version#*.}"
  kex="sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org"
  if [[ -n "$version" ]] && (( major > 9 || (major == 9 && minor >= 9) )); then
    kex="mlkem768x25519-sha256,$kex"
  fi
  cat <<EOF
KexAlgorithms $kex
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
PubkeyAcceptedAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,sk-ecdsa-sha2-nistp256@openssh.com,rsa-sha2-512,rsa-sha2-256
EOF
}

configure_sshd() {
  ensure_package openssh-server

  # Only disable passwords when key login is actually set up; otherwise we
  # would lock the user out of a server they just asked for.
  local password_auth="no"
  if [[ -z "$TARGET_HOME" || ! -s "$TARGET_HOME/.ssh/authorized_keys" ]]; then
    password_auth="yes"
    log_warn "No ~/.ssh/authorized_keys for ${TARGET_USER:-the target user}: keeping password login enabled."
    log_warn "Add your public key, then re-run this module to switch to key-only login."
  fi

  local forwarding="no"
  [[ "${SSH_ALLOW_TCP_FORWARDING:-true}" == "true" ]] && forwarding="yes"

  # Drop-ins are read before the main sshd_config, and for sshd the first
  # value wins, so these settings take precedence over the distro defaults.
  {
    echo "# Managed by ai-workstation setup (setup/hardening/ssh.sh)"
    echo "Port ${SSH_PORT:-22}"
    echo "PermitRootLogin no"
    echo "PubkeyAuthentication yes"
    echo "PasswordAuthentication $password_auth"
    echo "KbdInteractiveAuthentication no"
    echo "PermitEmptyPasswords no"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    echo "MaxStartups 10:30:60"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
    echo "X11Forwarding no"
    echo "AllowAgentForwarding no"
    echo "AllowTcpForwarding $forwarding"
    echo "PermitTunnel no"
    echo "LogLevel VERBOSE"
    [[ -n "${SSH_ALLOW_USERS:-}" ]] && echo "AllowUsers $SSH_ALLOW_USERS"
    crypto_settings
  } | install_managed_file "$SSHD_DROPIN" 0644

  [[ "$FILE_CHANGED" == "true" ]] || { ensure_service_enabled ssh.service; return 0; }
  is_dry_run && return 0

  # Never reload an invalid config: that would take SSH down.
  if ! sshd -t 2>>"${LOG_FILE:-/dev/null}"; then
    log_error "sshd rejected the new configuration; restoring the previous state"
    local backup
    backup="$AIWS_BACKUP_ROOT/$RUN_ID$SSHD_DROPIN"
    if [[ -f "$backup" ]]; then cp -a -- "$backup" "$SSHD_DROPIN"; else rm -f -- "$SSHD_DROPIN"; fi
    return 1
  fi

  run_cmd systemctl daemon-reload
  if unit_exists ssh.socket && unit_enabled ssh.socket; then
    # Ubuntu 24.04+ socket activation: the listening port comes from the socket.
    run_cmd systemctl restart ssh.socket
  fi
  if unit_active ssh.service; then run_cmd systemctl reload ssh.service; fi
  ensure_service_enabled ssh.service
  log_ok "sshd configured on port ${SSH_PORT:-22} (root login disabled, password login: $password_auth)"
}

main() {
  parse_common_args "$@"
  init_module ssh
  require_root
  if is_enabled ENABLE_SSH_SERVER; then
    configure_sshd
  else
    disable_sshd
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
