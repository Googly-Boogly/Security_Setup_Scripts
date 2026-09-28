#!/usr/bin/env bash
# Conservative rollback of configuration changes made by this project.
#
#   sudo ./setup/uninstall/rollback.sh --list             show recorded runs and changes
#   sudo ./setup/uninstall/rollback.sh --latest           undo the most recent run
#   sudo ./setup/uninstall/rollback.sh --run RUN_ID       undo one specific run
#   sudo ./setup/uninstall/rollback.sh --all              restore the state before the FIRST run
#   add --dry-run to preview, --yes to skip the confirmation
#
# What it does: restores backed-up config files, moves aside files this
# project created, restores file modes, sysctl values, disabled services,
# docker group membership and git settings it changed.
# What it never does: remove packages or undo OS updates. Packages may be
# needed by other software; the list of packages installed is shown so you
# can remove them yourself if you want to.
# Current files are backed up again before being replaced, so a rollback can
# itself be reverted by hand.
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROLLBACK_DIR=""
RESTORED_PATHS=()

list_runs() {
  [[ -s "$CHANGE_MANIFEST" ]] || { log_info "No changes recorded ($CHANGE_MANIFEST)"; return 0; }
  echo "Recorded runs (oldest first):"
  awk -F'|' '$1 != "ROLLBACK" { n[$2]++; if (!($2 in first)) { first[$2] = $3; order[++k] = $2 } }
    END { for (i = 1; i <= k; i++) printf "  %-28s %-26s %d change(s)\n", order[i], first[order[i]], n[order[i]] }' "$CHANGE_MANIFEST"
  echo
  echo "Changes by type:"
  awk -F'|' '{ c[$1]++ } END { for (t in c) printf "  %-18s %d\n", t, c[t] }' "$CHANGE_MANIFEST" | sort
  local pkgs
  pkgs="$(awk -F'|' '$1 == "PACKAGE_INSTALLED" { print $5 }' "$CHANGE_MANIFEST" | sort -u | paste -sd' ' || true)"
  if [[ -n "$pkgs" ]]; then
    echo
    echo "Packages installed by this project (never removed automatically):"
    echo "  $pkgs"
  fi
}

# Selected manifest lines, newest first.
select_entries() {
  local mode="$1" run="${2:-}"
  case "$mode" in
    run) awk -F'|' -v r="$run" '$2 == r' "$CHANGE_MANIFEST" | tac ;;
    all)
      # For files: the FIRST record per path describes the original state.
      # For other types: undo every record, newest first.
      awk -F'|' '
        $1 == "BACKUP" || $1 == "CREATED" { if (!($5 in seen)) { seen[$5] = 1; print } ; next }
        $1 == "SYSCTL_PREV" || $1 == "PERM" { key = $1 SUBSEP $5; if (!(key in seen2)) { seen2[key] = 1; print }; next }
        $1 != "ROLLBACK" && $1 != "PACKAGE_INSTALLED" { print }' "$CHANGE_MANIFEST" | tac ;;
  esac
}

# Keep a copy of whatever is there now before we replace or remove it.
stash_current() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  install -d -m 0700 "$ROLLBACK_DIR$(dirname "$path")"
  cp -a -- "$path" "$ROLLBACK_DIR$path"
}

undo_entry() {
  local type="$1" subject="$2" detail="$3"
  case "$type" in
    BACKUP)
      [[ -e "$detail" ]] || { log_warn "Backup missing for $subject: $detail"; return 0; }
      if is_dry_run; then log_dry "restore $subject from $detail"; return 0; fi
      stash_current "$subject"
      install -d "$(dirname "$subject")"
      cp -a -- "$detail" "$subject"
      RESTORED_PATHS+=("$subject")
      log_ok "Restored $subject" ;;
    CREATED)
      [[ -e "$subject" ]] || return 0
      if is_dry_run; then log_dry "move aside created file $subject"; return 0; fi
      stash_current "$subject"
      rm -f -- "$subject"
      RESTORED_PATHS+=("$subject")
      log_ok "Removed $subject (copy kept in $ROLLBACK_DIR)" ;;
    PERM)
      [[ -e "$subject" ]] || return 0
      run_cmd chmod "$detail" "$subject" && log_ok "Mode of $subject restored to $detail" ;;
    SYSCTL_PREV)
      run_cmd sysctl -q -w "$subject=$detail" || log_warn "Could not restore $subject=$detail" ;;
    SERVICE_DISABLED)
      if [[ "$detail" == enabled* ]]; then
        run_cmd systemctl enable --now "$subject" || log_warn "Could not re-enable $subject"
      fi ;;
    GROUP_ADD)
      run_cmd gpasswd -d "$subject" "$detail" || true ;;
    GIT_CONFIG)
      run_cmd sudo -H -u "$detail" git config --global --unset "$subject" || true ;;
    UFW_STATE)
      if [[ "$detail" == inactive ]] && command_exists ufw; then
        confirm_or_skip "UFW was inactive before this project enabled it. Disable the firewall again?" &&
          run_cmd ufw disable
      fi ;;
    PACKAGE_INSTALLED|ROLLBACK) ;;
    *) log_warn "Unknown change type '$type' for $subject; skipped" ;;
  esac
}

# Re-apply restored configuration so the running system matches the files.
reload_affected() {
  local p joined
  joined=" ${RESTORED_PATHS[*]} "
  run_cmd systemctl daemon-reload
  [[ "$joined" == *" /etc/ufw/"* || "$joined" == *" /etc/default/ufw "* ]] && command_exists ufw && run_cmd ufw reload
  if [[ "$joined" == *" /etc/ssh/"* ]] && command_exists sshd; then
    if sshd -t; then unit_active ssh.service && run_cmd systemctl reload ssh.service
    else log_error "Restored sshd configuration is invalid; check /etc/ssh before reconnecting"; fi
  fi
  [[ "$joined" == *" /etc/audit/"* ]] && command_exists augenrules && run_cmd augenrules --load
  [[ "$joined" == *" /etc/audit/"* ]] && { run_cmd systemctl reload auditd.service || true; }
  [[ "$joined" == *" /etc/systemd/journald.conf.d/"* ]] && run_cmd systemctl restart systemd-journald.service
  if [[ "$joined" == *" /etc/rsyslog.d/"* ]] && command_exists rsyslogd; then
    if rsyslogd -N1 >/dev/null 2>&1; then run_cmd systemctl restart rsyslog.service
    else log_error "Restored rsyslog configuration is invalid; check /etc/rsyslog.d"; fi
  fi
  [[ "$joined" == *" /etc/fail2ban/"* ]] && unit_exists fail2ban.service && { run_cmd systemctl restart fail2ban.service || true; }
  [[ "$joined" == *" /etc/docker/daemon.json "* ]] && log_warn "Restart Docker to apply the restored daemon.json: sudo systemctl restart docker"
  for p in "${RESTORED_PATHS[@]}"; do
    [[ "$p" == /etc/sysctl.d/* ]] && log_info "Sysctl file changed; runtime values were restored from records where available"
  done
  return 0
}

main() {
  local mode="" run=""
  parse_common_args "$@"
  set -- "${MODULE_ARGS[@]}"
  while (($#)); do
    case "$1" in
      --list) mode=list ;;
      --latest) mode=latest ;;
      --run) mode=run; run="${2:?--run needs a RUN_ID}"; shift ;;
      --all) mode=all ;;
      -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
  [[ -n "$mode" ]] || { sed -n '2,20p' "$0"; exit 1; }

  init_module rollback
  require_root
  [[ -f "$CHANGE_MANIFEST" ]] || die "No change manifest at $CHANGE_MANIFEST: nothing to roll back"

  if [[ "$mode" == list ]]; then list_runs; return 0; fi
  if [[ "$mode" == latest ]]; then
    run="$(awk -F'|' '$1 != "ROLLBACK" { r = $2 } END { print r }' "$CHANGE_MANIFEST")"
    [[ -n "$run" ]] || die "No runs recorded"
    mode=run
  fi

  local entries
  entries="$(select_entries "$mode" "$run")"
  [[ -n "$entries" ]] || die "No recorded changes for ${run:-any run}"
  local count
  count="$(grep -c . <<<"$entries")"
  log_info "Will undo $count recorded change(s)${run:+ from run $run}:"
  awk -F'|' '{ printf "    %-17s %s %s\n", $1, $5, ($1 == "BACKUP" ? "" : $6) }' <<<"$entries" >&2

  if ! confirm_or_skip "Proceed with rollback?" && ! is_dry_run; then
    log_info "Rollback cancelled"
    return 0
  fi

  ROLLBACK_DIR="$AIWS_BACKUP_ROOT/rollback-$RUN_ID"
  is_dry_run || install -d -m 0700 "$ROLLBACK_DIR"

  local type _run _ts _mod subject detail
  while IFS='|' read -r type _run _ts _mod subject detail; do
    undo_entry "$type" "$subject" "$detail"
  done <<<"$entries"

  if ! is_dry_run; then
    reload_affected
    record_change ROLLBACK "${run:-all}" "$ROLLBACK_DIR"
    log_ok "Rollback complete. Files that were replaced are kept in $ROLLBACK_DIR"
  fi
  log_info "Packages were not removed. See: sudo $0 --list"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
