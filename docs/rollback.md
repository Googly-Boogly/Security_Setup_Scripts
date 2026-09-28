# Rollback

Rollback restores configuration this project changed. It never removes
packages or reverts OS updates, because other software may depend on them.

Before any file changes it is copied to
`/var/backups/ai-workstation/<run-id>/<original path>`, and every change is
recorded in `/var/lib/ai-workstation/changes.log` (root-only) as
`TYPE|RUN_ID|TIMESTAMP|MODULE|SUBJECT|DETAIL`.

| Record type | Rollback action |
| --- | --- |
| BACKUP | Restore the saved copy |
| CREATED | Move the new file aside (kept, not deleted) |
| PERM | Restore the previous file mode |
| SYSCTL_PREV | Restore the previous running value |
| SERVICE_DISABLED | Re-enable the service if it was enabled |
| GROUP_ADD | Remove the user from the group |
| GIT_CONFIG | Unset the git setting this project added |
| UFW_STATE | Offer to disable UFW if it was inactive before |
| PACKAGE_INSTALLED | Listed only, never removed |

```bash
sudo ./setup/uninstall/rollback.sh --list                # runs, change counts, installed packages
sudo ./setup/uninstall/rollback.sh --latest --dry-run    # preview undoing the last run
sudo ./setup/uninstall/rollback.sh --run <run-id>        # undo one run
sudo ./setup/uninstall/rollback.sh --all                 # back to the state before the first run
```

Files being replaced are copied to `/var/backups/ai-workstation/rollback-<id>/`
first, so a rollback can itself be undone by hand. Afterwards it reloads what it
touched: systemd, UFW, sshd (only after `sshd -t` passes) and audit rules; a
restored `daemon.json` needs a manual Docker restart.
