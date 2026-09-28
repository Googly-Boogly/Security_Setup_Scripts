#!/usr/bin/env bash
# Run an agent workload inside a hardened, resource-limited container.
#
# Treat the agent as untrusted code: these boundaries are enforced by the
# kernel and container runtime, not by asking the model to behave.
#
#   ./setup/agents/agent_runner.sh --workspace ~/agent-workspaces/agent-001 \
#       --network restricted --memory 2g --cpus 2 --env ANTHROPIC_API_KEY -- python agent.py
#
# Run with --help for all options. Run as your normal user, never with sudo.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/agent.sh
source "$SETUP_ROOT/lib/agent.sh"

usage() {
  cat <<'EOF'
Usage: agent_runner.sh --workspace DIR [options] [-- COMMAND [ARGS...]]

Isolation
  --workspace DIR        Host directory mounted read-write at /workspace (required)
  --network MODE         offline | restricted | internet   (default from config: offline)
  --shared               Also mount ~/agent-workspaces/shared read-only at /shared
  --mount-ro HOST:DEST   Extra read-only bind mount (repeatable; sensitive paths are refused)
  --image IMAGE          Container image (default from config)
  --runtime RT           podman | docker (default: config, rootless podman preferred)

Limits
  --memory SIZE          e.g. 2g     --cpus N   e.g. 1.5
  --pids N               max processes/threads   --timeout SECONDS

Secrets (values are never logged; only variable names are)
  --env NAME             Pass one variable from YOUR environment (repeatable)
  --env-file FILE        Pass variables from a file (should be chmod 600)
  --secret NAME=FILE     Mount FILE read-only at /run/secrets/NAME (preferred over env vars)

Other
  --agent-id ID          Label for logs (default: workspace directory name)
  --session-id ID        Session identifier (default: generated)
  --save-output          Also save container stdout/stderr to the session directory
  --build-image          Build the default base image (agents/image/Dockerfile) and exit
  --dry-run              Print the container command without running it
  -h, --help             Show this help
EOF
}

AUDIT_LOG=""
SESSION_ID=""
AGENT_ID=""
CONTAINER_NAME=""
RT=""
START_TS=0

new_session_id() {
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
}

# One JSON object per line. Values here come from the runner itself (never
# from the agent) and contain no secret values: only env var NAMES.
audit_event() {
  local action="$1" result="$2" exit_code="${3:-null}" duration="${4:-null}"
  [[ -n "$AUDIT_LOG" ]] || return 0
  rotate_log_if_needed "$AUDIT_LOG" "${AGENT_LOG_MAX_BYTES:-10485760}" "${AGENT_LOG_KEEP:-5}"
  local envs="" n
  for n in "${ENV_NAMES[@]}"; do envs+="${envs:+,}\"$(json_escape "$n")\""; done
  local secrets="" s
  for s in "${SECRET_NAMES[@]}"; do secrets+="${secrets:+,}\"$(json_escape "$s")\""; done
  printf '{"timestamp":"%s","agent_id":"%s","session_id":"%s","tool":"agent_runner","action":"%s","target":"%s","result":"%s","exit_code":%s,"duration_s":%s,"user":"%s","runtime":"%s","image":"%s","network":"%s","limits":{"memory":"%s","cpus":"%s","pids":%s,"timeout_s":%s},"env_names":[%s],"secret_names":[%s],"container":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$AGENT_ID")" "$(json_escape "$SESSION_ID")" \
    "$(json_escape "$action")" "$(json_escape "$WORKSPACE")" "$(json_escape "$result")" \
    "$exit_code" "$duration" "$(json_escape "$(id -un)")" "$RT" "$(json_escape "$IMAGE")" "$NETWORK" \
    "$MEMORY" "$CPUS" "$PIDS" "$TIMEOUT" "$envs" "$secrets" "$CONTAINER_NAME" >>"$AUDIT_LOG"
}

cleanup() {
  [[ -n "$CONTAINER_NAME" && -n "$RT" ]] || return 0
  "$RT" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

on_interrupt() {
  log_warn "Interrupted; stopping $CONTAINER_NAME"
  cleanup
  audit_event container_exit interrupted 130 "$(( $(date +%s) - START_TS ))"
  exit 130
}

build_image() {
  local rt="$1"
  log_info "Building $IMAGE with $rt from agents/image/Dockerfile"
  "$rt" build --pull -t "$IMAGE" "$SETUP_ROOT/agents/image"
  log_ok "Built $IMAGE"
}

resolve_dir() {
  local p="$1"
  p="${p/#\~/$HOME}"
  [[ -d "$p" ]] || return 1
  realpath -e -- "$p"
}

check_mount_allowed() {
  local path="$1" reason repo_root
  repo_root="$(cd "$SETUP_ROOT/.." && pwd)"
  # The setup repo itself is protected: an agent that could edit it could
  # change its own sandbox policy (or a script you later run with sudo).
  if reason="$(mount_denial_reason "$path" "$HOME" "$repo_root" "$(agent_state_dir)" "${XDG_RUNTIME_DIR:-}")"; then
    die "Refusing to mount $path: $reason"
  fi
}

main() {
  WORKSPACE="" NETWORK="${AGENT_DEFAULT_NETWORK:-}" IMAGE="" MEMORY="" CPUS="" PIDS="" TIMEOUT=""
  ENV_NAMES=() SECRET_NAMES=()
  local env_files=() secret_specs=() ro_mounts=() cmd=()
  local shared=false save_output=false do_build=false runtime_pref=""

  LOG_MODULE=agent_runner
  load_config
  [[ -n "$NETWORK" ]] || NETWORK="${AGENT_DEFAULT_NETWORK:-offline}"

  while (($#)); do
    case "$1" in
      --workspace) WORKSPACE="${2:?}"; shift ;;
      --network) NETWORK="${2:?}"; shift ;;
      --image) IMAGE="${2:?}"; shift ;;
      --runtime) runtime_pref="${2:?}"; shift ;;
      --memory) MEMORY="${2:?}"; shift ;;
      --cpus) CPUS="${2:?}"; shift ;;
      --pids) PIDS="${2:?}"; shift ;;
      --timeout) TIMEOUT="${2:?}"; shift ;;
      --env) ENV_NAMES+=("${2:?}"); shift ;;
      --env-file) env_files+=("${2:?}"); shift ;;
      --secret) secret_specs+=("${2:?}"); shift ;;
      --mount-ro) ro_mounts+=("${2:?}"); shift ;;
      --shared) shared=true ;;
      --agent-id) AGENT_ID="${2:?}"; shift ;;
      --session-id) SESSION_ID="${2:?}"; shift ;;
      --save-output) save_output=true ;;
      --build-image) do_build=true ;;
      --dry-run) DRY_RUN=true ;;
      -h|--help) usage; exit 0 ;;
      --) shift; cmd=("$@"); break ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done

  if is_root; then
    die "Do not run agents as root. Run agent_runner.sh as your normal user (container user = your UID, not root)."
  fi

  IMAGE="${IMAGE:-$AGENT_IMAGE}"
  MEMORY="${MEMORY:-$AGENT_MAX_MEMORY}" CPUS="${CPUS:-$AGENT_MAX_CPUS}"
  PIDS="${PIDS:-$AGENT_MAX_PIDS}" TIMEOUT="${TIMEOUT:-$AGENT_TIMEOUT}"

  RT="$(select_agent_runtime "$runtime_pref")" || die "No usable container runtime (install podman or docker)"
  if [[ "$do_build" == "true" ]]; then runtime_usable "$RT" || exit 1; build_image "$RT"; exit 0; fi

  # ---- validation ---------------------------------------------------------
  [[ -n "$WORKSPACE" ]] || { usage >&2; die "--workspace is required"; }
  WORKSPACE="$(resolve_dir "$WORKSPACE")" ||
    die "Workspace does not exist. Create one with: ./setup/agents/create_workspace.sh --new"
  check_mount_allowed "$WORKSPACE"
  [[ -O "$WORKSPACE" ]] || log_warn "Workspace $WORKSPACE is not owned by you; the agent may not be able to write to it"

  is_valid_network_mode "$NETWORK" || die "Invalid --network '$NETWORK' (offline|restricted|internet)"
  is_valid_memory "$MEMORY" || die "Invalid --memory '$MEMORY' (e.g. 512m, 2g)"
  is_valid_cpus "$CPUS" || die "Invalid --cpus '$CPUS'"
  is_positive_int "$PIDS" || die "Invalid --pids '$PIDS'"
  is_positive_int "$TIMEOUT" || die "Invalid --timeout '$TIMEOUT'"

  if [[ -z "$AGENT_ID" ]]; then
    AGENT_ID="${WORKSPACE##*/}"
    AGENT_ID="$(printf '%s' "${AGENT_ID,,}" | tr -c 'a-z0-9_.-' '-' | sed 's/^[^a-z0-9]*//' | cut -c1-63)"
  fi
  is_valid_agent_id "$AGENT_ID" || die "Invalid agent id '$AGENT_ID' (lowercase letters, digits, . _ -)"
  [[ -n "$SESSION_ID" ]] || SESSION_ID="$(new_session_id)"
  [[ "$SESSION_ID" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "Invalid --session-id"
  CONTAINER_NAME="ai-${AGENT_ID}-${SESSION_ID##*-}"

  local n
  for n in "${ENV_NAMES[@]}"; do
    is_valid_env_name "$n" || die "Invalid environment variable name '$n'"
    [[ -n "${!n+x}" ]] || die "--env $n: variable is not set in your environment"
  done

  # ---- container arguments -------------------------------------------------
  local state_dir session_dir
  state_dir="$(agent_state_dir)"
  session_dir="$state_dir/sessions/$SESSION_ID"

  local args=(run --rm --init --name "$CONTAINER_NAME" --hostname "$AGENT_ID"
    --read-only
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --memory "$MEMORY" --memory-swap "$MEMORY"
    --cpus "$CPUS" --pids-limit "$PIDS"
    --tmpfs "/tmp:rw,nosuid,nodev,size=${AGENT_TMPFS_SIZE:-512m}"
    --workdir /workspace
    --mount "type=bind,src=$WORKSPACE,dst=/workspace"
    --mount "type=bind,src=$session_dir,dst=/var/log/agent"
    --mount "type=bind,src=$SETUP_ROOT/agents/tools,dst=/opt/agent-tools,readonly"
    --env "HOME=/tmp" --env "AGENT_ID=$AGENT_ID" --env "AGENT_SESSION_ID=$SESSION_ID"
    --env "AGENT_AUDIT_LOG=/var/log/agent/events.jsonl" --env "PYTHONPATH=/opt/agent-tools"
    --label ai-agent.managed=true --label "ai-agent.id=$AGENT_ID"
    --label "ai-agent.session=$SESSION_ID" --label "ai-agent.network=$NETWORK"
    --stop-timeout 10
  )

  if [[ "$RT" == podman ]]; then
    # Container processes run as your UID (not root) and files stay yours.
    args+=(--userns=keep-id)
  else
    args+=(--user "$(id -u):$(id -g)")
    local driver
    driver="$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || true)"
    if [[ "$driver" == systemd ]] && systemctl cat "$AGENT_SLICE" >/dev/null 2>&1; then
      args+=(--cgroup-parent "$AGENT_SLICE")
    fi
  fi
  [[ "$IMAGE" == localhost/* ]] && args+=(--pull=never)

  case "$NETWORK" in
    offline) args+=(--network none) ;;
    internet) args+=(--network "$AGENT_NET_INTERNET") ;;
    restricted)
      local purl; purl="$(proxy_url)"
      args+=(--network "$AGENT_NET_RESTRICTED"
        --env "HTTP_PROXY=$purl" --env "HTTPS_PROXY=$purl" --env "http_proxy=$purl" --env "https_proxy=$purl"
        --env "NO_PROXY=localhost,127.0.0.1" --env "no_proxy=localhost,127.0.0.1"
        --env "NODE_USE_ENV_PROXY=1") ;;
  esac

  if [[ "$shared" == "true" ]]; then
    local shared_dir="${AGENT_WORKSPACES_DIR:-$HOME/agent-workspaces}/shared"
    [[ -d "$shared_dir" ]] || die "Shared directory $shared_dir does not exist (run create_workspace.sh)"
    args+=(--mount "type=bind,src=$(realpath -e "$shared_dir"),dst=/shared,readonly")
  fi

  local spec host dest
  for spec in "${ro_mounts[@]}"; do
    host="${spec%%:*}"; dest="${spec#*:}"
    [[ "$spec" == *:* && "$dest" == /* ]] || die "--mount-ro expects HOST:/container/path"
    host="$(realpath -e -- "${host/#\~/$HOME}")" || die "--mount-ro: $spec does not exist"
    check_mount_allowed "$host"
    case "$dest" in /|/workspace*|/var/log/agent*|/opt/agent-tools*|/run/secrets*|/proc*|/sys*|/dev*)
      die "--mount-ro: destination $dest is reserved" ;; esac
    args+=(--mount "type=bind,src=$host,dst=$dest,readonly")
  done

  for n in "${ENV_NAMES[@]}"; do
    # "--env NAME" without a value: the runtime copies it from our
    # environment, so the secret never appears on a command line (ps).
    args+=(--env "$n")
  done
  local f mode
  for f in "${env_files[@]}"; do
    [[ -f "$f" ]] || die "--env-file $f not found"
    mode="$(stat -c '%a' "$f")"
    (( 8#$mode & 8#077 )) && log_warn "$f is readable by other users (mode $mode); chmod 600 it"
    args+=(--env-file "$f")
  done
  local sname sfile
  for spec in "${secret_specs[@]}"; do
    sname="${spec%%=*}"; sfile="${spec#*=}"
    [[ "$spec" == *=* && "$sname" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--secret expects NAME=FILE"
    sfile="$(realpath -e -- "${sfile/#\~/$HOME}")" || die "--secret $sname: file not found"
    [[ -f "$sfile" ]] || die "--secret $sname: not a regular file"
    SECRET_NAMES+=("$sname")
    args+=(--mount "type=bind,src=$sfile,dst=/run/secrets/$sname,readonly")
  done

  # Always forward stdin (so input can be piped to an agent); add a TTY only
  # when we are on a terminal.
  args+=(-i)
  if [[ -t 0 && -t 1 ]]; then args+=(-t); fi
  args+=("$IMAGE")
  if ((${#cmd[@]} > 0)); then
    args+=("${cmd[@]}")
  elif [[ -n "${AGENT_DEFAULT_COMMAND:-}" ]]; then
    args+=(sh -c "$AGENT_DEFAULT_COMMAND")
  fi

  if is_dry_run; then
    log_dry "runtime: $RT | network: $NETWORK | workspace: $WORKSPACE"
    log_dry "would run: $RT $(printf '%q ' "${args[@]}")"
    [[ "$NETWORK" == "restricted" || "$NETWORK" == "internet" ]] && log_dry "would first ensure network mode '$NETWORK'"
    return 0
  fi

  # ---- run ------------------------------------------------------------------
  runtime_usable "$RT" || exit 1
  if ! "$RT" image inspect "$IMAGE" >/dev/null 2>&1 && [[ "$IMAGE" == localhost/* ]]; then
    die "Image $IMAGE not found. Build it first: $0 --build-image"
  fi
  ensure_agent_network "$RT" "$NETWORK"

  install -d -m 0700 "$state_dir" "$state_dir/sessions"
  # The container runs as our UID (docker --user / podman keep-id), so it can
  # write its own event log here but nowhere else outside /workspace.
  install -d -m 0700 "$session_dir"
  AUDIT_LOG="$state_dir/audit.jsonl"
  [[ -f "$AUDIT_LOG" ]] || install -m 0600 /dev/null "$AUDIT_LOG"

  trap cleanup EXIT
  trap on_interrupt INT TERM
  START_TS="$(date +%s)"
  audit_event container_start started
  log_info "Session $SESSION_ID: $RT, network=$NETWORK, memory=$MEMORY, cpus=$CPUS, pids=$PIDS, timeout=${TIMEOUT}s"
  log_info "Audit log: $AUDIT_LOG | agent events: $session_dir/events.jsonl"

  local rc=0
  if [[ "$save_output" == "true" ]]; then
    timeout --foreground --kill-after=15 "$TIMEOUT" "$RT" "${args[@]}" 2>&1 | tee "$session_dir/output.log" || rc=$?
    chmod 0600 "$session_dir/output.log" 2>/dev/null || true
  else
    timeout --foreground --kill-after=15 "$TIMEOUT" "$RT" "${args[@]}" || rc=$?
  fi

  local duration=$(( $(date +%s) - START_TS )) result
  case "$rc" in
    0) result=success ;;
    124|137) if ((duration >= TIMEOUT)); then result=timeout; else result=failed; fi ;;
    125) result=runtime_error ;;
    *) result=failed ;;
  esac
  if [[ "$result" == timeout ]]; then
    log_warn "Timed out after ${TIMEOUT}s; container killed"
    "$RT" kill "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  audit_event container_exit "$result" "$rc" "$duration"
  log_info "Agent finished: $result (exit $rc, ${duration}s)"
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
