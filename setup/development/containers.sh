#!/usr/bin/env bash
# Container runtimes: Docker Engine (from Docker's signed apt repository)
# and/or rootless Podman (from Ubuntu).
#
# Security posture:
#   * the Docker daemon is never exposed over TCP and no insecure registries
#     are configured (existing ones are reported);
#   * published ports bind to 127.0.0.1 by default, because Docker's own
#     iptables rules bypass UFW;
#   * the user is NOT added to the docker group unless configured: that
#     group is root-equivalent. Rootless Podman is the preferred agent runtime.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DAEMON_JSON=/etc/docker/daemon.json

wants_docker() { [[ "${CONTAINER_RUNTIME:-both}" == "docker" || "${CONTAINER_RUNTIME:-both}" == "both" ]]; }
wants_podman() { [[ "${CONTAINER_RUNTIME:-both}" == "podman" || "${CONTAINER_RUNTIME:-both}" == "both" ]]; }

install_docker() {
  if package_installed docker.io; then
    log_warn "Ubuntu's docker.io package is installed; keeping it (not replacing a working setup). Configuring it instead."
    return 0
  fi
  if package_installed docker-ce; then
    log_ok "Docker Engine already installed ($(docker --version 2>/dev/null || echo unknown))"
  else
    ensure_apt_repo docker "https://download.docker.com/linux/ubuntu/gpg" "${DOCKER_KEY_FINGERPRINT:-}" \
      "deb [arch=$(os_arch) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $OS_CODENAME stable"
  fi
  ensure_package docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

desired_daemon_settings() {
  jq -n \
    --arg size "${DOCKER_LOG_MAX_SIZE:-20m}" \
    --arg files "${DOCKER_LOG_MAX_FILE:-5}" \
    --argjson live "${DOCKER_LIVE_RESTORE:-true}" \
    --argjson nnp "${DOCKER_DEFAULT_NO_NEW_PRIVILEGES:-false}" \
    --argjson localhost "${DOCKER_PUBLISH_LOCALHOST_ONLY:-true}" '
    {
      "log-driver": "local",
      "log-opts": { "max-size": $size, "max-file": $files },
      "live-restore": $live,
      "features": { "buildkit": true }
    }
    + (if $localhost then { "ip": "127.0.0.1" } else {} end)
    + (if $nnp then { "no-new-privileges": true } else {} end)'
}

# Merge our keys into any existing daemon.json instead of overwriting it.
configure_docker_daemon() {
  local existing="{}" merged
  if [[ -f "$DAEMON_JSON" ]]; then
    existing="$(cat "$DAEMON_JSON")"
    if ! jq -e . >/dev/null 2>&1 <<<"$existing"; then
      log_error "$DAEMON_JSON is not valid JSON; not touching it. Fix it by hand and re-run."
      return 1
    fi
  fi

  if jq -e '(.hosts // []) | map(select(startswith("tcp://"))) | length > 0' >/dev/null <<<"$existing"; then
    log_error "$DAEMON_JSON exposes the Docker API over TCP (hosts). Anyone reaching it gets root. Remove the tcp:// entry."
  fi
  if jq -e '(."insecure-registries" // []) | length > 0' >/dev/null <<<"$existing"; then
    log_warn "$DAEMON_JSON configures insecure registries: $(jq -c '."insecure-registries"' <<<"$existing")"
  fi

  merged="$(jq -S -s '.[0] * .[1]' <(printf '%s' "$existing") <(desired_daemon_settings))"
  printf '%s\n' "$merged" | install_managed_file "$DAEMON_JSON" 0644
  [[ "$FILE_CHANGED" == "true" ]] || return 0
  is_dry_run && return 0

  if command_exists dockerd && ! dockerd --validate --config-file "$DAEMON_JSON" >>"${LOG_FILE:-/dev/null}" 2>&1; then
    log_error "dockerd rejected the new daemon.json; restoring the previous version"
    local backup="$AIWS_BACKUP_ROOT/$RUN_ID$DAEMON_JSON"
    if [[ -f "$backup" ]]; then cp -a -- "$backup" "$DAEMON_JSON"; else rm -f -- "$DAEMON_JSON"; fi
    return 1
  fi

  # Some settings (ip, log driver) need a full restart, which stops running
  # containers unless live-restore was already active.
  local ids running
  ids="$(docker ps -q 2>/dev/null || true)"
  running="$(grep -c . <<<"$ids" || true)"
  if ((running > 0)) && ! confirm_or_skip "Restart Docker now to apply daemon.json? ($running running container(s) may restart)"; then
    log_warn "Docker not restarted; run 'sudo systemctl restart docker' later to apply the new settings"
    return 0
  fi
  run_cmd systemctl restart docker
}

configure_docker_group() {
  require_target_user || return 0
  if [[ " $(id -nG "$TARGET_USER") " == *" docker "* ]]; then
    log_warn "$TARGET_USER is in the docker group: any process running as $TARGET_USER (including agents run outside a sandbox) can gain root."
    return 0
  fi
  if [[ "${DOCKER_ADD_USER_TO_GROUP:-false}" == "true" ]]; then
    log_warn "Adding $TARGET_USER to the docker group (root-equivalent) as configured"
    record_change GROUP_ADD "$TARGET_USER" docker
    run_cmd usermod -aG docker "$TARGET_USER"
  else
    log_info "$TARGET_USER is not in the docker group (use sudo docker, or rootless Podman for agents)."
  fi
}

install_podman() {
  local pkgs=(podman uidmap slirp4netns passt fuse-overlayfs dbus-user-session netavark aardvark-dns catatonit) available=() p
  for p in "${pkgs[@]}"; do
    if package_installed "$p" || is_dry_run || package_available "$p"; then available+=("$p"); fi
  done
  ensure_package "${available[@]}"

  # Rootless containers need subordinate ID ranges for the user.
  require_target_user || return 0
  if ! grep -qs "^$TARGET_USER:" /etc/subuid || ! grep -qs "^$TARGET_USER:" /etc/subgid; then
    log_warn "$TARGET_USER has no /etc/subuid or /etc/subgid range; rootless Podman needs one:"
    log_warn "  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $TARGET_USER"
  else
    log_ok "Subordinate UID/GID ranges present for $TARGET_USER"
  fi
}

main() {
  parse_common_args "$@"
  init_module containers
  require_root
  module_enabled_or_exit ENABLE_CONTAINERS
  detect_os

  if wants_docker; then
    install_docker
    if is_dry_run && ! command_exists docker; then
      log_dry "would write $DAEMON_JSON with: $(desired_daemon_settings | jq -c .)"
    else
      configure_docker_daemon
      ensure_service_enabled docker.service
    fi
    configure_docker_group
  fi
  if wants_podman; then install_podman; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
