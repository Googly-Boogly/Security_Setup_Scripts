#!/usr/bin/env bash
# Git pre-commit hook: block commits that contain secrets.
# Installed by: setup/security/secrets_scanning.sh install-hook <repo>
# Bypass for a known false positive: add it to .gitleaksignore (preferred)
# or commit with --no-verify (then fix the root cause).
set -Eeuo pipefail

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "pre-commit: gitleaks not installed; secret scan skipped" >&2
  exit 0
fi

# --redact: the finding is reported without printing the secret itself.
if ! gitleaks protect --staged --redact --no-banner; then
  echo "pre-commit: possible secret in staged changes. Remove it (and rotate it if it was real)." >&2
  exit 1
fi
