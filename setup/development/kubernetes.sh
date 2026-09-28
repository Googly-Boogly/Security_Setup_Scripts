#!/usr/bin/env bash
# Optional Kubernetes client tooling: kubectl (pkgs.k8s.io apt repo) and kind
# (checksum-verified release binary). No cluster is created: `kind create
# cluster` is left to the user because it starts privileged containers.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

install_kubectl() {
  local minor="${KUBERNETES_MINOR:-v1.34}"
  ensure_apt_repo kubernetes "https://pkgs.k8s.io/core:/stable:/${minor}/deb/Release.key" \
    "${KUBERNETES_KEY_FINGERPRINT:-}" \
    "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/${minor}/deb/ /"
  ensure_package kubectl
}

install_kind() {
  local version="${KIND_VERSION:-v0.30.0}" arch dest=/usr/local/bin/kind tmp sha url
  if [[ -x "$dest" ]] && [[ "$("$dest" version 2>/dev/null)" == *"$version "* ]]; then
    log_ok "kind $version already installed"
    return 0
  fi
  arch="$(os_arch)"
  url="https://github.com/kubernetes-sigs/kind/releases/download/${version}/kind-linux-${arch}"
  if is_dry_run; then log_dry "would download kind $version from $url, verify SHA-256, install to $dest"; return 0; fi

  sha="${KIND_SHA256:-}"
  if [[ -z "$sha" ]]; then
    # Same-origin checksum: protects against corruption, not a compromised
    # release. Pin KIND_SHA256 in the config for stronger guarantees.
    sha="$(curl -fsSL --proto '=https' "${url}.sha256sum" | awk '{print $1}')"
  fi
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { log_error "Could not obtain a valid checksum for kind $version"; return 1; }
  tmp="$(mktemp)"
  download_verified "$url" "$sha" "$tmp" || { rm -f -- "$tmp"; return 1; }
  backup_file "$dest"
  install -m 0755 -o root -g root "$tmp" "$dest"
  rm -f -- "$tmp"
  log_ok "Installed kind $version"
}

main() {
  parse_common_args "$@"
  init_module kubernetes
  require_root
  module_enabled_or_exit ENABLE_KUBERNETES
  detect_os

  install_kubectl
  [[ "${ENABLE_KIND:-true}" == "true" ]] && install_kind
  log_info "kind clusters run as privileged containers; create one only when needed: kind create cluster"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
