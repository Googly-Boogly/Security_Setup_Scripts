#!/usr/bin/env bash
# Node.js LTS from the NodeSource apt repository, plus TypeScript (and
# optionally pnpm) installed per user.
#
# Global npm packages go to ~/.npm-global instead of /usr: that avoids
# `sudo npm install -g`, which runs arbitrary package install scripts as root.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

install_node() {
  local major="${NODE_MAJOR:-24}" arch current
  arch="$(os_arch)"
  if command_exists node; then
    current="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
    if [[ "$current" == "$major" ]] && package_installed nodejs; then
      log_ok "Node.js $(node --version) already installed"
      return 0
    fi
    log_info "Found Node.js v${current:-?}; installing the v${major} LTS line from NodeSource"
  fi
  ensure_apt_repo nodesource "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    "${NODESOURCE_KEY_FINGERPRINT:-}" \
    "deb [arch=$arch signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${major}.x nodistro main"
  # Prefer NodeSource's nodejs over Ubuntu's older package of the same name.
  install_managed_file /etc/apt/preferences.d/nodesource 0644 <<'EOF'
# Managed by ai-workstation setup (setup/development/node.sh)
Package: nodejs
Pin: origin deb.nodesource.com
Pin-Priority: 600
EOF
  ensure_package nodejs
}

configure_user_npm() {
  require_target_user || return 0
  local prefix="$TARGET_HOME/.npm-global" owner
  owner="$TARGET_USER:$(id -gn "$TARGET_USER")"

  {
    echo "prefix=$prefix"
    [[ "${NPM_IGNORE_SCRIPTS:-false}" == "true" ]] && echo "ignore-scripts=true"
    echo "audit=true"
    echo "fund=false"
  } | ensure_managed_block "$TARGET_HOME/.npmrc" npm 0600 "$owner"

  ensure_managed_block "$TARGET_HOME/.profile" npm-path 0644 "$owner" <<'EOF'
if [ -d "$HOME/.npm-global/bin" ]; then PATH="$HOME/.npm-global/bin:$PATH"; fi
EOF

  local pkgs=(typescript) missing=() p bin
  [[ "${ENABLE_PNPM:-true}" == "true" ]] && pkgs+=(pnpm)
  for p in "${pkgs[@]}"; do
    bin="$p"; [[ "$p" == typescript ]] && bin=tsc
    if [[ -x "$prefix/bin/$bin" ]]; then log_ok "Already installed for $TARGET_USER: $p"; else missing+=("$p"); fi
  done
  ((${#missing[@]} == 0)) && return 0
  if ! is_dry_run && ! command_exists npm; then log_error "npm not found after installing nodejs"; return 1; fi
  log_info "Installing for $TARGET_USER (into $prefix): ${missing[*]}"
  run_as_target_user npm install --global --prefix "$prefix" --no-fund "${missing[@]}"
}

main() {
  parse_common_args "$@"
  init_module node
  require_root
  module_enabled_or_exit ENABLE_NODE
  detect_os

  install_node
  configure_user_npm
  log_info "Open a new login shell (or run: source ~/.profile) to get ~/.npm-global/bin on PATH."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
