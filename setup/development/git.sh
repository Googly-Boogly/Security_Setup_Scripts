#!/usr/bin/env bash
# Git with conservative defaults and a global ignore list for secret files.
#
# Only keys the user has not set are written, and SSH/GPG keys are never
# generated or modified: key material is the user's decision.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# key value — why
SAFE_DEFAULTS=(
  "transfer.fsckObjects true"   # reject malformed/malicious objects on fetch and push
  "fetch.fsckObjects true"
  "receive.fsckObjects true"
  "init.defaultBranch main"
)

user_git() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then git "$@"; else sudo -H -u "$TARGET_USER" -- git "$@"; fi
}

apply_safe_defaults() {
  local entry key value current
  for entry in "${SAFE_DEFAULTS[@]}"; do
    key="${entry%% *}"; value="${entry#* }"
    current="$(user_git config --global --get "$key" 2>/dev/null || true)"
    if [[ -z "$current" ]]; then
      run_as_target_user git config --global "$key" "$value"
      record_change GIT_CONFIG "$key" "$TARGET_USER"
    elif [[ "$current" == "$value" ]]; then
      log_ok "git $key already $value"
    else
      log_info "Leaving your git $key=$current as is (recommended: $value)"
    fi
  done

  local helper
  helper="$(user_git config --global --get credential.helper 2>/dev/null || true)"
  if [[ "$helper" == "store"* ]]; then
    log_warn "git credential.helper=store keeps tokens in plaintext (~/.git-credentials). Prefer 'libsecret' or 'cache'."
  fi
}

# Git reads ~/.config/git/ignore automatically unless core.excludesFile is set.
install_global_ignore() {
  local file owner
  file="$(user_git config --global --get core.excludesFile 2>/dev/null || true)"
  file="${file/#\~/$TARGET_HOME}"
  [[ -n "$file" ]] || file="$TARGET_HOME/.config/git/ignore"
  owner="$TARGET_USER:$(id -gn "$TARGET_USER")"
  ensure_managed_block "$file" secrets 0644 "$owner" <<'EOF'
# Secrets must never be committed (a repo-level .gitignore can re-include).
.env
.env.*
!.env.example
*.pem
*.key
*.p12
*.pfx
id_rsa
id_ed25519
id_ecdsa
.git-credentials
.netrc
secrets/
EOF
}

main() {
  parse_common_args "$@"
  init_module git
  require_root
  module_enabled_or_exit ENABLE_GIT

  ensure_package git
  require_target_user || return 0
  if ! command_exists git; then log_dry "git not installed yet; skipping user configuration"; return 0; fi

  [[ "${GIT_APPLY_SAFE_DEFAULTS:-true}" == "true" ]] && apply_safe_defaults
  install_global_ignore

  if [[ -z "$(user_git config --global --get user.signingkey 2>/dev/null || true)" ]]; then
    log_info "Commit signing is not configured (optional). See README 'Git' for SSH-key signing."
  fi
  log_info "SSH keys were not created or changed. Create one yourself with: ssh-keygen -t ed25519"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
