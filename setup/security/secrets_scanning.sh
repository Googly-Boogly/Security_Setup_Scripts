#!/usr/bin/env bash
# Gitleaks secret detection. Output is always redacted (--redact), so
# running a scan never prints the secret it found.
#
#   sudo ./setup/security/secrets_scanning.sh           install gitleaks (default)
#   ./setup/security/secrets_scanning.sh scan [PATH]     scan a repo (full history) or directory
#   ./setup/security/secrets_scanning.sh staged          scan staged changes (what a hook runs)
#   ./setup/security/secrets_scanning.sh install-hook [REPO]  add a pre-commit hook to a repo
#
# pre-commit framework users: see security/files/pre-commit-config.example.yaml
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

HOOK_SOURCE="$SETUP_ROOT/security/files/pre-commit-gitleaks.sh"

install_gitleaks() {
  require_root
  module_enabled_or_exit ENABLE_SECRETS_SCANNING
  if package_installed gitleaks || is_dry_run || package_available gitleaks; then
    ensure_package gitleaks
  else
    log_warn "gitleaks is not packaged for this Ubuntu release. Install a release from"
    log_warn "https://github.com/gitleaks/gitleaks/releases and verify its checksum."
  fi
}

need_gitleaks() { command_exists gitleaks || die "gitleaks is not installed. Run: sudo $0"; }

scan_path() {
  local path="${1:-.}"
  need_gitleaks
  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Scanning git history of $path"
    gitleaks detect --source "$path" --redact --no-banner -v
  else
    log_info "Scanning directory $path (not a git repository)"
    gitleaks detect --source "$path" --no-git --redact --no-banner -v
  fi
}

install_hook() {
  local repo="${1:-.}" hooks_dir hook
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "$repo is not a git repository"
  hooks_dir="$(git -C "$repo" rev-parse --git-path hooks)"
  [[ "$hooks_dir" = /* ]] || hooks_dir="$repo/$hooks_dir"
  hook="$hooks_dir/pre-commit"
  if [[ -e "$hook" ]] && ! cmp -s "$hook" "$HOOK_SOURCE"; then
    die "$hook already exists. Call $HOOK_SOURCE from it instead of replacing it."
  fi
  if is_dry_run; then log_dry "would install $hook"; return 0; fi
  mkdir -p -- "$hooks_dir"
  install -m 0755 "$HOOK_SOURCE" "$hook"
  log_ok "Installed gitleaks pre-commit hook: $hook"
}

main() {
  parse_common_args "$@"
  init_module secrets_scanning
  local cmd="${MODULE_ARGS[0]:-install}"
  case "$cmd" in
    install) install_gitleaks ;;
    scan) scan_path "${MODULE_ARGS[1]:-.}" ;;
    staged) need_gitleaks; gitleaks protect --staged --redact --no-banner -v ;;
    install-hook) install_hook "${MODULE_ARGS[1]:-.}" ;;
    *) die "Unknown command '$cmd' (install|scan|staged|install-hook)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
