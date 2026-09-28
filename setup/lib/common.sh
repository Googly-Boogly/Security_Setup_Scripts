#!/usr/bin/env bash
# shellcheck disable=SC2034  # library: globals are read by the scripts that source it
# Shared helpers for every setup module. Source this file; do not execute it.
#
# Rules enforced here so the individual modules stay small:
#   * every mutation goes through run_cmd / install_managed_file, so
#     --dry-run is honoured in one place;
#   * every file we change is backed up first and recorded in the change
#     manifest, which is what uninstall/rollback.sh replays;
#   * nothing here prints secret values (see redact_secrets in logging.sh).

[[ -n "${_AIWS_COMMON_LOADED:-}" ]] && return 0
_AIWS_COMMON_LOADED=1

# `producer | install_managed_file ...` must run the function in this shell
# so FILE_CHANGED is visible to the caller (scripts are non-interactive, so
# job control is off and lastpipe applies).
shopt -s lastpipe

AIWS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_ROOT="$(cd "$AIWS_LIB_DIR/.." && pwd)"
export SETUP_ROOT

# shellcheck source=logging.sh
source "$AIWS_LIB_DIR/logging.sh"
# shellcheck source=detection.sh
source "$AIWS_LIB_DIR/detection.sh"
# shellcheck source=validate.sh
source "$AIWS_LIB_DIR/validate.sh"

: "${AIWS_STATE_DIR:=/var/lib/ai-workstation}"
: "${AIWS_BACKUP_ROOT:=/var/backups/ai-workstation}"
: "${AIWS_LOG_DIR:=/var/log/ai-workstation-bootstrap}"
: "${AIWS_CONFIG_FILE:=$SETUP_ROOT/config/workstation.conf}"
: "${DRY_RUN:=false}"
: "${ASSUME_YES:=false}"
: "${FORCE:=false}"
: "${RUN_ID:=$(date '+%Y%m%d-%H%M%S')-$$}"
CHANGE_MANIFEST="$AIWS_STATE_DIR/changes.log"
export AIWS_STATE_DIR AIWS_BACKUP_ROOT AIWS_LOG_DIR AIWS_CONFIG_FILE DRY_RUN ASSUME_YES RUN_ID

MODULE_ARGS=()
FILE_CHANGED=false
TARGET_USER=""
TARGET_HOME=""

# ---------------------------------------------------------------------------
# Module lifecycle
# ---------------------------------------------------------------------------

# Handles flags shared by all modules; anything else lands in MODULE_ARGS.
parse_common_args() {
  MODULE_ARGS=()
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --yes|-y) ASSUME_YES=true ;;
      --force) FORCE=true ;;
      --config)
        [[ $# -ge 2 ]] || die "--config requires a file path"
        AIWS_CONFIG_FILE="$2"; shift ;;
      *) MODULE_ARGS+=("$1") ;;
    esac
    shift
  done
  export DRY_RUN ASSUME_YES AIWS_CONFIG_FILE
}

init_module() {
  LOG_MODULE="$1"
  trap '_aiws_on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
  load_config
  resolve_target_user
  _init_log_file
}

_aiws_on_error() {
  log_error "Command failed (exit $1) at ${BASH_SOURCE[1]:-?}:$2: $3"
}

_init_log_file() {
  if [[ -n "${LOG_FILE:-}" && -w "${LOG_FILE}" ]]; then return 0; fi
  LOG_FILE=""
  # Dry runs leave no trace on the system, not even a log file.
  if is_root && ! is_dry_run; then
    install -d -m 0750 "$AIWS_LOG_DIR"
    LOG_FILE="$AIWS_LOG_DIR/${LOG_MODULE}-${RUN_ID}.log"
    install -m 0640 /dev/null "$LOG_FILE"
  fi
  export LOG_FILE
}

is_dry_run() { [[ "$DRY_RUN" == "true" ]]; }

is_enabled() { [[ "${!1:-false}" == "true" ]]; }

# Modules honour their config toggle even when run by hand; --force overrides.
module_enabled_or_exit() {
  local var="$1"
  if ! is_enabled "$var" && [[ "$FORCE" != "true" ]]; then
    log_info "Disabled in config ($var=false); nothing to do. Use --force to run anyway."
    exit 0
  fi
}

require_root() {
  is_root && return 0
  if is_dry_run; then
    log_warn "Not running as root: dry-run output may be incomplete (some state is root-readable only)."
    return 0
  fi
  die "This must be run as root (try: sudo $0 ${*:-})"
}

# The human user the workstation is being set up for (not root).
resolve_target_user() {
  TARGET_USER="${AIWS_TARGET_USER:-${SUDO_USER:-}}"
  if [[ -z "$TARGET_USER" ]] && ! is_root; then TARGET_USER="$(id -un)"; fi
  [[ "$TARGET_USER" == "root" ]] && TARGET_USER=""
  TARGET_HOME=""
  if [[ -n "$TARGET_USER" ]]; then
    TARGET_HOME="$(user_home "$TARGET_USER")"
    [[ -d "$TARGET_HOME" ]] || { log_warn "Home directory for $TARGET_USER not found"; TARGET_USER=""; TARGET_HOME=""; }
  fi
}

require_target_user() {
  [[ -n "$TARGET_USER" ]] && return 0
  log_warn "No non-root target user detected (run via sudo from your user account, or set AIWS_TARGET_USER)."
  return 1
}

# Ask before a risky action. Non-interactive runs skip unless --yes was given.
confirm_or_skip() {
  local question="$1" reply
  [[ "$ASSUME_YES" == "true" ]] && return 0
  if is_dry_run; then log_dry "Would ask: $question"; return 1; fi
  if [[ ! -t 0 ]]; then
    log_warn "Skipping (non-interactive, needs confirmation): $question  [re-run with --yes to accept]"
    return 1
  fi
  read -r -p "$question [y/N] " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

load_config() {
  local f
  [[ -f "$AIWS_CONFIG_FILE" ]] || die "Config file not found: $AIWS_CONFIG_FILE"
  for f in "$AIWS_CONFIG_FILE" "$SETUP_ROOT/config/workstation.local.conf"; do
    [[ -f "$f" ]] || continue
    _check_config_file_safe "$f"
    # shellcheck source=../config/workstation.conf
    source "$f"
  done
  validate_config
}

# The config is sourced as root, so a file others can edit would be a
# trivial privilege escalation.
_check_config_file_safe() {
  local f="$1" mode owner
  mode="$(stat -c '%a' "$f")"
  owner="$(stat -c '%U' "$f")"
  if (( 8#$mode & 8#002 )); then
    die "Refusing to load world-writable config $f (chmod o-w '$f')"
  fi
  case "$owner" in
    root|"${SUDO_USER:-root}"|"$(id -un)") ;;
    *) die "Refusing to load config $f owned by '$owner' (expected root or ${SUDO_USER:-$(id -un)})" ;;
  esac
}

validate_config() {
  local v errors=0
  for v in $(compgen -v | grep -E '^(ENABLE_|AGENT_.*_ENABLED$)' || true); do
    if ! is_bool "${!v}"; then log_error "Config: $v must be true or false (got '${!v}')"; errors=$((errors + 1)); fi
  done
  case "${CONTAINER_RUNTIME:-docker}" in docker|podman|both) ;; *)
    log_error "Config: CONTAINER_RUNTIME must be docker, podman or both"; errors=$((errors + 1)) ;; esac
  is_valid_memory "${AGENT_MAX_MEMORY:-2g}" || { log_error "Config: invalid AGENT_MAX_MEMORY"; errors=$((errors + 1)); }
  is_valid_cpus "${AGENT_MAX_CPUS:-2}" || { log_error "Config: invalid AGENT_MAX_CPUS"; errors=$((errors + 1)); }
  is_positive_int "${AGENT_MAX_PIDS:-256}" || { log_error "Config: invalid AGENT_MAX_PIDS"; errors=$((errors + 1)); }
  is_positive_int "${AGENT_TIMEOUT:-1800}" || { log_error "Config: invalid AGENT_TIMEOUT"; errors=$((errors + 1)); }
  is_valid_network_mode "${AGENT_DEFAULT_NETWORK:-offline}" || { log_error "Config: invalid AGENT_DEFAULT_NETWORK"; errors=$((errors + 1)); }
  ((errors == 0)) || die "Configuration has $errors error(s): $AIWS_CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

# Run a system-changing command, or just print it in dry-run mode. Output
# goes to the log file to keep the terminal readable; on failure the tail is
# shown so the error is visible without opening the log.
run_cmd() {
  if is_dry_run; then
    log_dry "would run: $(printf '%q ' "$@")"
    return 0
  fi
  log_file_only "run: $*"
  local out rc=0
  out="$(mktemp)"
  "$@" >"$out" 2>&1 || rc=$?
  if [[ -n "${LOG_FILE:-}" ]]; then redact_secrets <"$out" >>"$LOG_FILE" 2>/dev/null || true; fi
  if ((rc != 0)); then
    log_error "Command failed (exit $rc): $*"
    tail -n 15 "$out" | redact_secrets | sed 's/^/    /' >&2
  fi
  rm -f -- "$out"
  return "$rc"
}

run_as_target_user() {
  require_target_user || return 1
  run_cmd sudo -H -u "$TARGET_USER" -- "$@"
}

# ---------------------------------------------------------------------------
# Change tracking and backups
# ---------------------------------------------------------------------------

_ensure_state_dirs() {
  install -d -m 0700 "$AIWS_STATE_DIR" "$AIWS_BACKUP_ROOT"
  [[ -f "$CHANGE_MANIFEST" ]] || install -m 0600 /dev/null "$CHANGE_MANIFEST"
}

# Manifest line: TYPE|RUN_ID|TIMESTAMP|MODULE|SUBJECT|DETAIL
record_change() {
  local type="$1" subject="$2" detail="${3:-}"
  is_dry_run && return 0
  if [[ "$subject$detail" == *"|"* || "$subject$detail" == *$'\n'* ]]; then
    log_warn "Not recording change with unsupported characters: $subject"; return 0
  fi
  _ensure_state_dirs
  printf '%s|%s|%s|%s|%s|%s\n' "$type" "$RUN_ID" "$(date -Is)" "${LOG_MODULE:-main}" \
    "$subject" "$detail" >>"$CHANGE_MANIFEST"
}

# True if TYPE was recorded for SUBJECT (in this run, or any run with "any").
manifest_has() {
  local type="$1" subject="$2" scope="${3:-run}"
  [[ -f "$CHANGE_MANIFEST" ]] || return 1
  awk -F'|' -v t="$type" -v s="$subject" -v r="$RUN_ID" -v scope="$scope" '
    $1 == t && $5 == s && (scope == "any" || $2 == r) { found = 1 }
    END { exit !found }' "$CHANGE_MANIFEST"
}

# Copy a file into this run's backup tree before we modify it (once per run).
# A file that does not exist yet is recorded as CREATED, so rollback knows
# to remove it rather than restore it.
backup_file() {
  local path="$1" dest
  is_dry_run && return 0
  _ensure_state_dirs
  if manifest_has BACKUP "$path" || manifest_has CREATED "$path"; then return 0; fi
  if [[ -e "$path" || -L "$path" ]]; then
    dest="$AIWS_BACKUP_ROOT/$RUN_ID$path"
    install -d -m 0700 "$(dirname "$dest")"
    cp -a -- "$path" "$dest"
    record_change BACKUP "$path" "$dest"
    log_info "Backed up $path -> $dest"
  else
    record_change CREATED "$path"
  fi
}

# ---------------------------------------------------------------------------
# File management
# ---------------------------------------------------------------------------

# Install content from stdin to DEST only if it differs. Sets FILE_CHANGED.
# Usage: install_managed_file DEST [MODE] [OWNER:GROUP] < content
install_managed_file() {
  local dest="$1" mode="${2:-0644}" owner="${3:-root:root}"
  local tmp current_mode parent
  tmp="$(mktemp)"
  cat >"$tmp"
  FILE_CHANGED=false

  if [[ -L "$dest" ]]; then
    rm -f -- "$tmp"
    log_error "Refusing to write through symlink: $dest"
    return 1
  fi

  if [[ -f "$dest" && -r "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f -- "$tmp"
    current_mode="$(stat -c '%a' "$dest")"
    if (( 8#$current_mode != 8#$mode )); then
      run_cmd chmod "$mode" "$dest"
    fi
    log_ok "Already configured: $dest"
    return 0
  fi

  FILE_CHANGED=true
  if is_dry_run; then
    if [[ -f "$dest" && -r "$dest" ]]; then
      log_dry "would update $dest:"
      if grep -Iq . "$tmp"; then
        diff -u "$dest" "$tmp" | tail -n +3 | redact_secrets | sed 's/^/    /' >&2 || true
      fi
    elif [[ -e "$dest" ]]; then
      log_dry "would update $dest (current content not readable without root)"
    else
      log_dry "would create $dest (mode $mode, owner $owner)"
      if grep -Iq . "$tmp"; then
        head -n 40 "$tmp" | redact_secrets | sed 's/^/    + /' >&2
      fi
    fi
    rm -f -- "$tmp"
    return 0
  fi

  parent="$(dirname "$dest")"
  if [[ ! -d "$parent" ]]; then
    # Parents inside a user's home must belong to that user, not root.
    if [[ "${owner%%:*}" != "root" ]]; then
      sudo -H -u "${owner%%:*}" mkdir -p -- "$parent"
    else
      install -d -m 0755 "$parent"
    fi
  fi
  backup_file "$dest"
  install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dest"
  rm -f -- "$tmp"
  log_ok "Wrote $dest"
}

# Insert/replace a marked block in a file we do not fully own (~/.profile etc.).
# Usage: ensure_managed_block FILE BLOCK_ID [MODE] [OWNER:GROUP] < body
ensure_managed_block() {
  local file="$1" id="$2" mode="${3:-0644}" owner="${4:-root:root}"
  if [[ -f "$file" ]]; then mode="$(stat -c '%a' "$file")"; fi
  render_managed_block "$file" "$id" | install_managed_file "$file" "$mode" "$owner"
}

# Set KEY=VALUE in a config file (e.g. /etc/default/ufw). An optional
# separator handles "key = value" formats such as auditd.conf.
ensure_kv() {
  local file="$1" key="$2" value="$3" sep="${4:-=}" mode="0644"
  [[ -f "$file" ]] && mode="$(stat -c '%a' "$file")"
  render_kv "$file" "$key" "$value" "$sep" | install_managed_file "$file" "$mode"
}

# ---------------------------------------------------------------------------
# Packages and repositories
# ---------------------------------------------------------------------------

apt_update_once() {
  [[ "${AIWS_APT_UPDATED:-false}" == "true" ]] && return 0
  log_info "Refreshing apt package index"
  run_cmd apt-get update -q
  AIWS_APT_UPDATED=true
  export AIWS_APT_UPDATED
}

ensure_package() {
  local missing=() p
  for p in "$@"; do package_installed "$p" || missing+=("$p"); done
  if ((${#missing[@]} == 0)); then
    log_ok "Already installed: $*"
    return 0
  fi
  apt_update_once
  if ! is_dry_run; then
    for p in "${missing[@]}"; do
      package_available "$p" || { log_error "Package '$p' is not available from the configured apt sources"; return 1; }
    done
  fi
  log_info "Installing: ${missing[*]}"
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${missing[@]}"
  for p in "${missing[@]}"; do record_change PACKAGE_INSTALLED "$p"; done
}

# Download a repository signing key, verify its fingerprint when one is
# pinned, and install it as /etc/apt/keyrings/NAME.gpg (binary keyring).
ensure_apt_key() {
  local name="$1" url="$2" expected="${3:-}" keyring="/etc/apt/keyrings/$1.gpg"
  local tmpd fprs
  expected="$(tr -d ' ' <<<"$expected" | tr '[:lower:]' '[:upper:]')"
  if is_dry_run; then
    log_dry "would fetch $name signing key from $url -> $keyring (pinned fingerprint: ${expected:-none})"
    return 0
  fi
  ensure_package curl gnupg ca-certificates
  tmpd="$(mktemp -d)"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmpd/key" "$url"; then
    rm -rf -- "$tmpd"; log_error "Could not download signing key for $name from $url"; return 1
  fi
  if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$tmpd/key"; then
    GNUPGHOME="$tmpd" gpg --batch --quiet --dearmor -o "$tmpd/key.gpg" "$tmpd/key"
  else
    cp -- "$tmpd/key" "$tmpd/key.gpg"
  fi
  fprs="$(GNUPGHOME="$tmpd" gpg --batch --show-keys --with-colons "$tmpd/key.gpg" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10 }')"
  if [[ -n "$expected" ]]; then
    if ! grep -qxF "$expected" <<<"$fprs"; then
      rm -rf -- "$tmpd"
      log_error "Signing key fingerprint mismatch for $name (expected $expected). Not installing."
      return 1
    fi
    log_ok "Verified $name signing key fingerprint $expected"
  else
    log_warn "No pinned fingerprint for $name; trusting the key fetched over HTTPS. Fingerprint(s): $(tr '\n' ' ' <<<"$fprs")"
  fi
  install -d -m 0755 /etc/apt/keyrings
  install_managed_file "$keyring" 0644 <"$tmpd/key.gpg"
  rm -rf -- "$tmpd"
}

# Add a third-party apt repository. If apt cannot use it, the source file is
# removed again so one bad repository never breaks `apt update` for the
# whole machine.
ensure_apt_repo() {
  local name="$1" key_url="$2" fingerprint="$3" line="$4"
  local list="/etc/apt/sources.list.d/${name}.list"
  ensure_apt_key "$name" "$key_url" "$fingerprint"
  printf '# Managed by ai-workstation setup (%s)\n%s\n' "$name" "$line" |
    install_managed_file "$list" 0644
  is_dry_run && return 0
  if ! apt-get update -q -o Dir::Etc::sourcelist="$list" -o Dir::Etc::sourceparts="-" \
      -o APT::Get::List-Cleanup="0" >>"${LOG_FILE:-/dev/null}" 2>&1; then
    log_error "apt cannot use the $name repository ($list). Removing it so apt keeps working."
    log_error "This usually means the vendor does not publish packages for '${OS_CODENAME:-this release}' yet."
    rm -f -- "$list"
    return 1
  fi
}

# Download a file and check it against a SHA-256 value.
download_verified() {
  local url="$1" sha256="$2" dest="$3"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$dest" "$url" || return 1
  if ! sha256sum -c - <<<"$sha256  $dest" >/dev/null 2>&1; then
    log_error "Checksum mismatch for $url"
    rm -f -- "$dest"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

ensure_service_enabled() {
  local unit="$1"
  if unit_enabled "$unit" && unit_active "$unit"; then
    log_ok "Service enabled and running: $unit"
    return 0
  fi
  run_cmd systemctl enable --now "$unit"
}

# Disable a unit and remember its previous state so rollback can restore it.
disable_unit() {
  local unit="$1" state
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  record_change SERVICE_DISABLED "$unit" "${state:-unknown}"
  run_cmd systemctl disable --now "$unit"
}
