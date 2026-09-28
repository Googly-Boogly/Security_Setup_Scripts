#!/usr/bin/env bash
# Optional Terraform from HashiCorp's signed apt repository (key fingerprint
# pinned in the config).
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

main() {
  parse_common_args "$@"
  init_module terraform
  require_root
  module_enabled_or_exit ENABLE_TERRAFORM
  detect_os

  if ! package_installed terraform; then
    ensure_apt_repo hashicorp "https://apt.releases.hashicorp.com/gpg" "${HASHICORP_KEY_FINGERPRINT:-}" \
      "deb [arch=$(os_arch) signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $OS_CODENAME main"
  fi
  ensure_package terraform
  log_info "Keep provider credentials out of .tf files; use environment variables or a secret manager."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
