#!/usr/bin/env bash
# Python 3 toolchain. Deliberately installs no application stacks globally:
# project dependencies belong in per-project virtual environments, and CLI
# tools in pipx, so a malicious or broken package cannot alter the system Python.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

main() {
  parse_common_args "$@"
  init_module python
  require_root
  module_enabled_or_exit ENABLE_PYTHON

  ensure_package python3 python3-venv python3-pip python3-dev build-essential pipx

  # PEP 668 protects the system Python from `sudo pip install`; a global
  # override silently removes that protection.
  if grep -qsE '^\s*break-system-packages\s*=\s*(true|1|yes)' /etc/pip.conf "${TARGET_HOME:-/nonexistent}/.config/pip/pip.conf"; then
    log_warn "pip is configured with break-system-packages=true; consider removing it and using venvs"
  fi

  log_info "Python $(python3 --version 2>/dev/null | awk '{print $2}') ready. Per-project environment:"
  cat >&2 <<'EOF'
      python3 -m venv .venv && . .venv/bin/activate
      pip install --upgrade pip && pip install -r requirements.txt
    CLI tools (isolated per tool):  pipx install <tool>
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
