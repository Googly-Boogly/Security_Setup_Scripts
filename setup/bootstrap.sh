#!/usr/bin/env bash
# AI engineering workstation bootstrap.
#
#   sudo ./setup/bootstrap.sh [--dry-run] [--yes] [--only a,b] [--skip a,b]
#                             [--config FILE] [--list] [--no-report]
#
# Runs each module in its own process so one failure is contained, reported,
# and does not leave later modules half-configured. Safe to re-run.
set -Eeuo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Order matters: SSH is configured before the firewall adds its rule, tools
# are installed before AIDE takes its baseline, containers before agents.
# Format: path:toggle ("-" = always runs; the module decides itself).
MODULES=(
  "hardening/updates.sh:ENABLE_AUTO_UPDATES"
  "hardening/ssh.sh:-"
  "hardening/firewall.sh:ENABLE_FIREWALL"
  "hardening/sysctl.sh:ENABLE_SYSCTL_HARDENING"
  "hardening/apparmor.sh:ENABLE_APPARMOR"
  "hardening/services.sh:ENABLE_SERVICE_REVIEW"
  "hardening/permissions.sh:ENABLE_PERMISSION_FIXES"
  "development/python.sh:ENABLE_PYTHON"
  "development/node.sh:ENABLE_NODE"
  "development/git.sh:ENABLE_GIT"
  "development/containers.sh:ENABLE_CONTAINERS"
  "development/kubernetes.sh:ENABLE_KUBERNETES"
  "development/terraform.sh:ENABLE_TERRAFORM"
  "security/auditd.sh:ENABLE_AUDITD"
  "security/container_scanning.sh:ENABLE_CONTAINER_SCANNING"
  "security/secrets_scanning.sh:ENABLE_SECRETS_SCANNING"
  "security/malware_scanning.sh:ENABLE_MALWARE_SCANNING"
  "security/suricata.sh:ENABLE_SURICATA"
  "security/wazuh_agent.sh:ENABLE_WAZUH_AGENT"
  "security/log_management.sh:ENABLE_LOG_MANAGEMENT"
  "agents/resource_limits.sh:ENABLE_AGENT_SANDBOX"
  "agents/create_workspace.sh:ENABLE_AGENT_SANDBOX"
  "agents/network_policy.sh:ENABLE_AGENT_SANDBOX"
  "security/aide.sh:ENABLE_AIDE"
)

usage() {
  cat <<'EOF'
Usage: sudo ./setup/bootstrap.sh [options]

  --dry-run            Show what would change without changing anything
  --yes, -y            Accept confirmation prompts (non-interactive runs)
  --only a,b           Run only these modules (names from --list)
  --skip a,b           Skip these modules
  --config FILE        Use another config file (default: setup/config/workstation.conf)
  --allow-unsupported  Continue on an OS release that is not in the supported list
  --stop-on-error      Abort at the first failing module (default: continue, report at end)
  --no-report          Do not run the security report at the end
  --list               List modules and whether they are enabled
  -h, --help           Show this help
EOF
}

module_name() { local base="${1%%:*}"; base="${base##*/}"; printf '%s' "${base%.sh}"; }

in_csv() {
  local needle="$1" csv="$2" item
  local -a items
  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

list_modules() {
  local entry name toggle state
  printf '%-22s %-28s %s\n' MODULE TOGGLE STATE
  for entry in "${MODULES[@]}"; do
    name="$(module_name "$entry")"; toggle="${entry##*:}"
    if [[ "$toggle" == "-" ]]; then state="always"
    elif is_enabled "$toggle"; then state="enabled"
    else state="disabled"; fi
    printf '%-22s %-28s %s\n' "$name" "$toggle" "$state"
  done
}

preflight() {
  log_section "Preflight"
  detect_os || die "Cannot read /etc/os-release"
  log_info "Detected: $OS_PRETTY_NAME ($(os_arch)), kernel $(uname -r)"
  if ! is_ubuntu; then
    [[ "$ALLOW_UNSUPPORTED" == "true" ]] || die "Only Ubuntu is supported (found '$OS_ID'). Use --allow-unsupported at your own risk."
    log_warn "Continuing on unsupported OS '$OS_ID' because --allow-unsupported was given"
  elif ! is_supported_ubuntu; then
    [[ "$ALLOW_UNSUPPORTED" == "true" ]] || die "Ubuntu $OS_VERSION_ID is not in the tested list (${SUPPORTED_UBUNTU_VERSIONS[*]}). Use --allow-unsupported to try anyway."
    log_warn "Ubuntu $OS_VERSION_ID is untested; third-party repositories may not support it yet"
  fi
  has_systemd || die "systemd is not running (containers/WSL without systemd are not supported)"
  is_wsl && log_warn "WSL detected: firewall, AppArmor, auditd and Suricata behave differently or not at all under WSL"
  if [[ -n "$TARGET_USER" ]]; then
    log_info "Target user: $TARGET_USER ($TARGET_HOME)"
  else
    log_warn "No invoking user found (run with sudo from your account); per-user steps will be skipped"
  fi
  in_ssh_session && log_warn "You are connected over SSH. Firewall and SSH modules include lockout guards; read their prompts carefully."
  is_dry_run && log_dry "DRY RUN: no changes will be made"

  check_network
  # One index refresh for the whole run; modules inherit AIWS_APT_UPDATED.
  apt_update_once
  # Tools the modules themselves rely on.
  ensure_package ca-certificates curl gnupg jq iproute2 lsb-release
}

# Fail early and clearly when packages cannot be downloaded, instead of
# deep inside apt. Only the Ubuntu mirrors are checked: a dead third-party
# PPA should not block the whole bootstrap.
check_network() {
  local hosts=() host failed=()
  mapfile -t hosts < <(apt_repo_hosts | grep -E '(^|\.)ubuntu\.com$' || true)
  ((${#hosts[@]} > 0)) || hosts=(archive.ubuntu.com security.ubuntu.com)
  for host in "${hosts[@]}"; do
    timeout 10 getent hosts "$host" >/dev/null 2>&1 || failed+=("$host")
  done
  if ((${#failed[@]} == 0)); then
    log_ok "Network OK: apt mirrors resolve (${hosts[*]})"
    return 0
  fi
  log_error "Cannot resolve ${failed[*]}: this machine has no working DNS or network connection."
  log_error "Diagnose: ping -c1 1.1.1.1   |   getent hosts ${failed[0]}   |   resolvectl status"
  if is_dry_run; then
    log_warn "Continuing because this is a dry run; a real run would stop here."
    return 0
  fi
  die "Fix networking (confirm with: sudo apt update), then re-run. Nothing has been changed yet."
}

main() {
  local only="" skip="" do_list=false no_report=false stop_on_error=false
  ALLOW_UNSUPPORTED=false
  local passthrough=()
  while (($#)); do
    case "$1" in
      --only) only="${2:?--only needs a value}"; shift ;;
      --skip) skip="${2:?--skip needs a value}"; shift ;;
      --list) do_list=true ;;
      --no-report) no_report=true ;;
      --stop-on-error) stop_on_error=true ;;
      --allow-unsupported) ALLOW_UNSUPPORTED=true ;;
      -h|--help) usage; exit 0 ;;
      *) passthrough+=("$1") ;;
    esac
    shift
  done
  parse_common_args "${passthrough[@]}"
  ((${#MODULE_ARGS[@]} == 0)) || { usage; die "Unknown argument(s): ${MODULE_ARGS[*]}"; }

  if [[ "$do_list" == "true" ]]; then load_config; list_modules; exit 0; fi

  init_module bootstrap
  require_root
  log_info "Run ID $RUN_ID${LOG_FILE:+ | log: $LOG_FILE}"
  preflight

  local child_flags=()
  is_dry_run && child_flags+=(--dry-run)
  [[ "$ASSUME_YES" == "true" ]] && child_flags+=(--yes)
  child_flags+=(--config "$AIWS_CONFIG_FILE")
  export LOG_FILE AIWS_TARGET_USER="$TARGET_USER"

  local entry name toggle script rc
  local -a results=()
  local failures=0
  for entry in "${MODULES[@]}"; do
    name="$(module_name "$entry")"; toggle="${entry##*:}"; script="$SETUP_ROOT/${entry%%:*}"
    if [[ -n "$only" ]] && ! in_csv "$name" "$only"; then continue; fi
    if [[ -n "$skip" ]] && in_csv "$name" "$skip"; then results+=("$name|skipped (--skip)"); continue; fi
    if [[ "$toggle" != "-" ]] && ! is_enabled "$toggle"; then
      results+=("$name|disabled ($toggle=false)"); continue
    fi
    log_section "Module: $name"
    rc=0
    bash "$script" "${child_flags[@]}" || rc=$?
    if ((rc == 0)); then
      results+=("$name|ok")
    else
      results+=("$name|FAILED (exit $rc)")
      failures=$((failures + 1))
      [[ "$stop_on_error" == "true" ]] && break
    fi
  done

  log_section "Bootstrap summary"
  local r
  for r in "${results[@]}"; do printf '  %-22s %s\n' "${r%%|*}" "${r#*|}" >&2; done
  [[ -n "${LOG_FILE:-}" ]] && log_info "Full log: $LOG_FILE"
  is_root && ! is_dry_run && log_info "Change manifest: $CHANGE_MANIFEST (used by uninstall/rollback.sh)"

  if [[ "$no_report" != "true" ]]; then
    log_section "Security report"
    bash "$SETUP_ROOT/verification/security_report.sh" --config "$AIWS_CONFIG_FILE" || true
  fi

  if ((failures > 0)); then
    log_error "$failures module(s) failed. Fix the cause and re-run; completed steps will be skipped."
    exit 1
  fi
  log_ok "Bootstrap finished."
}

main "$@"
