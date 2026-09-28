#!/usr/bin/env bash
# Logging helpers. Source this file; do not execute it.
#
# Messages go to the terminal (stderr) and, when LOG_FILE is set, to the
# bootstrap log file. Every message passes through redact_secrets first so a
# careless log line cannot persist an API key to disk.

[[ -n "${_AIWS_LOGGING_LOADED:-}" ]] && return 0
_AIWS_LOGGING_LOADED=1

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _C_RED=$'\033[31m'; _C_YELLOW=$'\033[33m'; _C_GREEN=$'\033[32m'
  _C_BLUE=$'\033[34m'; _C_MAGENTA=$'\033[35m'; _C_BOLD=$'\033[1m'; _C_RESET=$'\033[0m'
else
  _C_RED=''; _C_YELLOW=''; _C_GREEN=''; _C_BLUE=''; _C_MAGENTA=''; _C_BOLD=''; _C_RESET=''
fi

# Best-effort masking of secrets in free text. It covers NAME=value style
# assignments where NAME looks secret, common token formats, and credentials
# embedded in URLs. It is a safety net, not a licence to log secrets.
redact_secrets() {
  sed -E \
    -e 's/([A-Za-z0-9_]*(API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Za-z0-9_]*[[:space:]]*[=:][[:space:]]*)[^[:space:]"'\'']+/\1[REDACTED]/Ig' \
    -e 's/sk-[A-Za-z0-9_-]{16,}/[REDACTED]/g' \
    -e 's/(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g' \
    -e 's#(://[^:/@[:space:]]+:)[^@[:space:]]+@#\1[REDACTED]@#g'
}

_log() {
  local level="$1" color="$2"; shift 2
  local msg ts
  msg="$(printf '%s' "$*" | redact_secrets)"
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s[%-5s]%s %s%s\n' "$color" "$level" "$_C_RESET" \
    "${LOG_MODULE:+[$LOG_MODULE] }" "$msg" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s [%s] [%s] %s\n' "$ts" "$level" "${LOG_MODULE:-main}" "$msg" \
      >>"$LOG_FILE" 2>/dev/null || true
  fi
}

# Write only to the log file (for command traces that would clutter the terminal).
log_file_only() {
  [[ -n "${LOG_FILE:-}" ]] || return 0
  printf '%s [TRACE] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${LOG_MODULE:-main}" \
    "$(printf '%s' "$*" | redact_secrets)" >>"$LOG_FILE" 2>/dev/null || true
}

log_info()  { _log INFO  "$_C_BLUE"    "$@"; }
log_ok()    { _log OK    "$_C_GREEN"   "$@"; }
log_warn()  { _log WARN  "$_C_YELLOW"  "$@"; }
log_error() { _log ERROR "$_C_RED"     "$@"; }
log_dry()   { _log DRY   "$_C_MAGENTA" "$@"; }

log_section() {
  printf '\n%s== %s ==%s\n' "$_C_BOLD" "$*" "$_C_RESET" >&2
  log_file_only "== $* =="
}

die() {
  log_error "$@"
  exit 1
}
