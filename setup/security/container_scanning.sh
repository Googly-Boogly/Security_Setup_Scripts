#!/usr/bin/env bash
# Trivy vulnerability / misconfiguration / secret scanning.
#
#   sudo ./setup/security/container_scanning.sh          install Trivy (default)
#   ./setup/security/container_scanning.sh image IMAGE    scan an image
#   ./setup/security/container_scanning.sh config PATH    Dockerfiles, compose, k8s, terraform
#   ./setup/security/container_scanning.sh fs PATH        vulns + misconfig + secrets in a directory
#   ./setup/security/container_scanning.sh deps PATH      dependency vulnerabilities (lock files)
#
# Scans report HIGH and CRITICAL by default; set TRIVY_SEVERITY to change.
# Trivy masks detected secret values in its output.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"

install_trivy() {
  require_root
  module_enabled_or_exit ENABLE_CONTAINER_SCANNING
  if ! package_installed trivy; then
    ensure_apt_repo trivy "https://aquasecurity.github.io/trivy-repo/deb/public.key" \
      "${TRIVY_KEY_FINGERPRINT:-}" \
      "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main"
  fi
  ensure_package trivy
  log_info "Examples: $0 image python:3.12-slim | $0 fs . | $0 config ./Dockerfile"
}

need_trivy() { command_exists trivy || die "trivy is not installed. Run: sudo $0"; }

main() {
  parse_common_args "$@"
  init_module container_scanning
  local cmd="${MODULE_ARGS[0]:-install}" target="${MODULE_ARGS[1]:-}"
  case "$cmd" in
    install) install_trivy; return 0 ;;
    image|config|fs|deps) [[ -n "$target" ]] || die "Usage: $0 $cmd <target>"; need_trivy ;;
    *) die "Unknown command '$cmd' (install|image|config|fs|deps)" ;;
  esac
  case "$cmd" in
    image)  trivy image --scanners vuln,secret --severity "$SEVERITY" "$target" ;;
    config) trivy config --severity "$SEVERITY" "$target" ;;
    fs)     trivy fs --scanners vuln,misconfig,secret --severity "$SEVERITY" "$target" ;;
    deps)   trivy fs --scanners vuln --severity "$SEVERITY" "$target" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
