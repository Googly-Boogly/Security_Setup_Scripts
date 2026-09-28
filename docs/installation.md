# Installation and dry-run

Preview first, then apply. A second run mostly reports `Already configured`,
because files are compared before writing and installed packages are skipped.

```bash
git clone <repository> && cd <repository>
cp setup/config/workstation.conf setup/config/workstation.local.conf   # optional overrides
sudo ./setup/bootstrap.sh --dry-run
sudo ./setup/bootstrap.sh
```

| Option | Effect |
| --- | --- |
| `--dry-run` | Show diffs of every config file and every command, changing nothing |
| `--yes` | Accept confirmation prompts, such as restarting Docker, in unattended runs |
| `--only firewall,sysctl` | Run only these modules |
| `--skip suricata` | Skip these modules |
| `--list` | Show modules and whether each is enabled |
| `--stop-on-error` | Abort at the first failing module (default: continue and report at the end) |
| `--allow-unsupported` | Run on an untested Ubuntu release |
| `--no-report` | Skip the security report at the end |

## Dry-run

Dry-run prints `[DRY]` lines: a unified diff for each file that would change,
the contents of new files, and each command that would run. It writes nothing,
not even a log or a backup. It also works without root; state only root can
read is reported as unknown. The security report still runs because it is
read-only.

## Single modules

Every module runs the same way on its own, for example
`sudo ./setup/hardening/firewall.sh --dry-run`. A module disabled in the config
exits unless you pass `--force`.

## Logs

Logs go to `/var/log/ai-workstation-bootstrap/bootstrap-<run-id>.log`
(root-readable, mode 0640). Command output is captured there and passed through
a secret-redaction filter.
