#!/usr/bin/env bash
# Pure validation and parsing helpers: no system mutation, no root needed.
# Kept separate so setup/tests/run_tests.sh can exercise them safely.

[[ -n "${_AIWS_VALIDATE_LOADED:-}" ]] && return 0
_AIWS_VALIDATE_LOADED=1

is_bool() { [[ "${1:-}" == "true" || "${1:-}" == "false" ]]; }

is_positive_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }

# Docker/Podman memory syntax: 512m, 2g, 1073741824.
is_valid_memory() { [[ "${1:-}" =~ ^[1-9][0-9]*[bkmgBKMG]?$ ]]; }

# Fractional CPU count greater than zero: 0.5, 2, 1.25.
is_valid_cpus() {
  [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [[ ! "$1" =~ ^0*(\.0*)?$ ]]
}

# Agent IDs end up in container names, hostnames and file paths.
is_valid_agent_id() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9_.-]{0,62}$ ]]; }

is_valid_env_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

is_valid_network_mode() {
  case "${1:-}" in offline|restricted|internet) return 0 ;; *) return 1 ;; esac
}

# Allowlist entry for the egress proxy: "example.com" or ".example.com".
is_valid_domain_pattern() {
  local re='^\.?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
  [[ "${1:-}" =~ $re ]]
}

# True when an octal mode grants any permission bit that max does not.
# Example: mode_exceeds 0644 0640 -> true (0640 does not allow other-read).
mode_exceeds() {
  local actual="$1" max="$2"
  (( (8#$actual & ~8#$max & 8#7777) != 0 ))
}

# Mode with the bits not allowed by max removed (never adds permissions).
mode_clamp() {
  printf '%o' $(( 8#$1 & 8#$2 ))
}

path_is_within() {
  local child="$1" parent="$2"
  [[ "$parent" == "/" ]] && return 0
  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

# Decide whether a host path may be bind-mounted into an agent container.
# Prints the reason and returns 0 when the mount must be refused.
# Usage: mount_denial_reason <resolved-path> <home> [extra protected paths...]
mount_denial_reason() {
  local path="$1" home="$2"; shift 2
  local p
  local protected=(
    "$home/.ssh" "$home/.aws" "$home/.azure" "$home/.config" "$home/.gnupg"
    "$home/.kube" "$home/.docker" "$home/.password-store" "$home/.netrc"
    "$home/.git-credentials" "$home/.npmrc" "$home/.pypirc"
    "$home/.local/share/keyrings" "$home/.local/state/ai-agent-runner"
    /etc /root /boot /usr /bin /sbin /lib /lib64 /proc /sys /dev /run /var/run
    /var/lib/docker /var/lib/containers /var/log
  )
  protected+=("$@")

  if [[ "$path" == "/" ]]; then echo "it is the root filesystem"; return 0; fi
  if [[ "$path" == "$home" ]]; then echo "it is your entire home directory"; return 0; fi
  for p in "${protected[@]}"; do
    [[ -n "$p" ]] || continue
    if path_is_within "$path" "$p"; then echo "it is inside protected path $p"; return 0; fi
    if path_is_within "$p" "$path"; then echo "it contains protected path $p"; return 0; fi
  done
  return 1
}

# Address part of an ss "Local Address:Port" column is loopback-only.
is_loopback_address() {
  local addr="${1%:*}"
  addr="${addr#[}"; addr="${addr%]}"
  case "$addr" in
    127.*|::1|::ffff:127.*|*%lo) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints "key value" pairs from a sysctl.d-style file, skipping comments.
parse_sysctl_file() {
  awk -F'=' '
    /^[[:space:]]*([#;]|$)/ { next }
    {
      key = $1; val = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (key != "") print key, val
    }' "$1"
}

# Minimal JSON string escaping for the audit log (no jq dependency needed).
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  # Drop any remaining control characters rather than emit invalid JSON.
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# Replace (or append) a delimited block in a text file's content.
# Usage: render_managed_block <file|/dev/null> <block-id>  (new body on stdin)
render_managed_block() {
  local file="$1" id="$2" body
  body="$(cat)"
  local begin="# >>> ai-workstation:${id} >>>" end="# <<< ai-workstation:${id} <<<"
  { [[ -f "$file" ]] && cat -- "$file"; true; } |
    AIWS_B="$begin" AIWS_E="$end" AIWS_BODY="$body" awk '
      $0 == ENVIRON["AIWS_B"] { print; print ENVIRON["AIWS_BODY"]; skip = 1; done = 1; next }
      skip && $0 == ENVIRON["AIWS_E"] { print; skip = 0; next }
      skip { next }
      { print }
      END {
        if (!done) { print ENVIRON["AIWS_B"]; print ENVIRON["AIWS_BODY"]; print ENVIRON["AIWS_E"] }
      }'
}

# Set KEY=VALUE in shell-style config content, replacing an existing
# uncommented assignment or appending one. Usage: render_kv <file> <key> <value>
render_kv() {
  local file="$1" key="$2" value="$3"
  { [[ -f "$file" ]] && cat -- "$file"; true; } |
    AIWS_K="$key" AIWS_V="$value" awk '
      index($0, ENVIRON["AIWS_K"] "=") == 1 && !done { print ENVIRON["AIWS_K"] "=" ENVIRON["AIWS_V"]; done = 1; next }
      { print }
      END { if (!done) print ENVIRON["AIWS_K"] "=" ENVIRON["AIWS_V"] }'
}
