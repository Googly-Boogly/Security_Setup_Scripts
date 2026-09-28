#!/usr/bin/env bash
# shellcheck disable=SC2034  # library: globals are read by the scripts that source it
# Shared logic for the agent sandbox (runner + network policy).
# Source after common.sh; do not execute.

[[ -n "${_AIWS_AGENT_LOADED:-}" ]] && return 0
_AIWS_AGENT_LOADED=1

AGENT_NET_INTERNET="ai-agents-internet"
AGENT_NET_RESTRICTED="ai-agents-restricted"   # --internal: no route off the host
AGENT_NET_EGRESS="ai-agents-egress"           # only the proxy is attached here
AGENT_PROXY_NAME="ai-agents-egress-proxy"
AGENT_PROXY_PORT=3128
AGENT_PROXY_UID=13                            # "proxy" user in Ubuntu images
AGENT_SLICE="ai-agents.slice"

agent_state_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/ai-agent-runner"; }

agent_allowlist_file() {
  printf '%s' "${AGENT_PROXY_ALLOWLIST:-$SETUP_ROOT/agents/policies/restricted-allowlist.txt}"
}

# Rootless Podman is preferred: a container escape then lands as your
# unprivileged user instead of root.
select_agent_runtime() {
  local pref="${1:-${AGENT_CONTAINER_RUNTIME:-auto}}"
  case "$pref" in
    auto)
      if command_exists podman; then echo podman
      elif command_exists docker; then echo docker
      else return 1; fi ;;
    podman|docker) command_exists "$pref" && echo "$pref" ;;
    *) return 1 ;;
  esac
}

runtime_usable() {
  local rt="$1" err
  if err="$("$rt" info 2>&1 >/dev/null)"; then return 0; fi
  if [[ "$rt" == docker && "$err" == *"permission denied"* ]]; then
    log_error "Your user cannot reach the Docker daemon. Options (see README 'Agent runtime'):"
    log_error "  - use rootless Podman (recommended): sudo apt install podman, then --runtime podman"
    log_error "  - or join the docker group (root-equivalent): sudo usermod -aG docker \$USER"
  else
    log_error "$rt is not usable: $(head -n 3 <<<"$err")"
  fi
  return 1
}

# Normalise an allowlist file: drop comments/blanks, validate, de-duplicate.
# Prints clean entries; returns 1 if any line is invalid.
render_allowlist() {
  local file="$1" line bad=0 entries=()
  [[ -f "$file" ]] || { log_error "Allowlist not found: $file"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    line="${line,,}"
    [[ -n "$line" ]] || continue
    if is_valid_domain_pattern "$line"; then entries+=("$line")
    else log_error "Invalid allowlist entry: '$line'"; bad=1; fi
  done <"$file"
  if ((${#entries[@]} > 0)); then printf '%s\n' "${entries[@]}" | sort -u; fi
  return "$bad"
}

network_exists() { "$1" network inspect "$2" >/dev/null 2>&1; }

create_network() {
  local rt="$1" name="$2"; shift 2
  if network_exists "$rt" "$name"; then return 0; fi
  log_info "Creating $rt network $name"
  run_cmd "$rt" network create "$@" "$name" >/dev/null
}

ensure_agent_network() {
  local rt="$1" mode="$2"
  case "$mode" in
    offline) return 0 ;;
    internet)
      # Docker: disable inter-container traffic so agents cannot reach each other.
      if [[ "$rt" == docker ]]; then
        create_network "$rt" "$AGENT_NET_INTERNET" --driver bridge -o com.docker.network.bridge.enable_icc=false \
          --label ai-agent.managed=true
      else
        create_network "$rt" "$AGENT_NET_INTERNET" --label ai-agent.managed=true
      fi ;;
    restricted)
      create_network "$rt" "$AGENT_NET_RESTRICTED" --internal --label ai-agent.managed=true
      create_network "$rt" "$AGENT_NET_EGRESS" --label ai-agent.managed=true
      ensure_egress_proxy "$rt" ;;
    *) die "Unknown network mode: $mode" ;;
  esac
}

# The proxy is the only container on both the internal agent network and an
# outbound network, so it is the single, allowlist-enforcing path out.
ensure_egress_proxy() {
  local rt="$1" dir allow conf hash current running
  dir="$(agent_state_dir)/proxy"
  allow="$dir/allowlist.txt"; conf="$dir/squid.conf"
  if ! is_dry_run; then install -d -m 0700 "$dir"; fi

  local rendered
  rendered="$(render_allowlist "$(agent_allowlist_file)")" || die "Fix the allowlist before using --network restricted"
  [[ -n "$rendered" ]] || log_warn "The restricted allowlist is empty: agents will not reach any external host"
  hash="$( { printf '%s\n' "$rendered"; cat "$SETUP_ROOT/agents/policies/squid.conf"; printf '%s' "$AGENT_PROXY_IMAGE"; } | sha256sum | cut -c1-16)"

  current="$("$rt" inspect -f '{{ index .Config.Labels "ai-agent.config-hash" }}' "$AGENT_PROXY_NAME" 2>/dev/null || true)"
  running="$("$rt" inspect -f '{{ .State.Running }}' "$AGENT_PROXY_NAME" 2>/dev/null || true)"
  if [[ "$current" == "$hash" && "$running" == "true" ]]; then
    return 0
  fi
  if is_dry_run; then log_dry "would (re)start egress proxy $AGENT_PROXY_NAME"; return 0; fi

  printf '%s\n' "$rendered" >"$allow"
  cp -- "$SETUP_ROOT/agents/policies/squid.conf" "$conf"
  chmod 0644 "$allow" "$conf"   # read by the proxy user inside the container

  "$rt" rm -f "$AGENT_PROXY_NAME" >/dev/null 2>&1 || true
  log_info "Starting egress proxy ($(grep -c . <<<"$rendered" || true) allowlisted domain(s))"
  "$rt" run -d --name "$AGENT_PROXY_NAME" \
    --network "$AGENT_NET_RESTRICTED" \
    --label ai-agent.managed=true --label "ai-agent.config-hash=$hash" \
    --user "$AGENT_PROXY_UID:$AGENT_PROXY_UID" \
    --read-only --cap-drop=ALL --security-opt=no-new-privileges \
    --memory 256m --pids-limit 128 --cpus 0.5 \
    --tmpfs /var/spool/squid:rw,mode=1777,size=64m \
    --tmpfs /var/log/squid:rw,mode=1777,size=64m \
    --tmpfs /run:rw,mode=1777,size=8m --tmpfs /tmp:rw,mode=1777,size=64m \
    --mount "type=bind,src=$conf,dst=/etc/squid/squid.conf,readonly" \
    --mount "type=bind,src=$allow,dst=/etc/squid/allowlist.txt,readonly" \
    --restart unless-stopped \
    --entrypoint /usr/sbin/squid \
    "$AGENT_PROXY_IMAGE" -N -f /etc/squid/squid.conf >/dev/null
  "$rt" network connect "$AGENT_NET_EGRESS" "$AGENT_PROXY_NAME"
}

proxy_url() { printf 'http://%s:%s' "$AGENT_PROXY_NAME" "$AGENT_PROXY_PORT"; }

# Size-based rotation for the per-user audit log (no logrotate dependency).
rotate_log_if_needed() {
  local file="$1" max="${2:-10485760}" keep="${3:-5}" size i
  [[ -f "$file" ]] || return 0
  size="$(stat -c '%s' "$file")"
  ((size >= max)) || return 0
  for ((i = keep - 1; i >= 1; i--)); do
    [[ -f "$file.$i" ]] && mv -f -- "$file.$i" "$file.$((i + 1))"
  done
  mv -f -- "$file" "$file.1"
  rm -f -- "$file.$((keep + 1))"
}
