# Verification

`sudo ./setup/verification/security_report.sh` runs every check, prints PASS,
WARN, FAIL or INFO per finding, saves a copy under
`/var/log/ai-workstation-bootstrap/`, and exits 1 if anything FAILs, so it can
run from cron or CI. A report full of PASS means "configured as intended", not
"secure".

| Script | Checks |
| --- | --- |
| `check_firewall.sh` | UFW active, default inbound deny, routed deny, IPv6 filtering, each inbound allow rule, SSH rules that contradict the config |
| `check_services.sh` | Unattended upgrades, pending reboot, AppArmor, auditd and its loaded rules, effective sshd settings, optional tools, non-loopback listeners, failed units |
| `check_sysctl.sh` | Every managed sysctl value against the running kernel, and whether the installed file matches the repository |
| `check_permissions.sh` | Sensitive file modes, world-writable paths in `/etc` and `/usr/local`, setuid files in `/usr/local`, user credential files, home directory mode |
| `check_logging.sh` | logrotate scheduled and policy installed, persistent journal, journal sealing, auditd rotation, world-readable or world-writable sensitive logs, remote forwarding, fail2ban |
| `check_containers.sh` | Docker API over TCP, insecure registries, localhost port binding, socket mode, docker-group members, privileged or socket-mounting containers, agent containers missing any required control, the agent slice and subuids |

Each script also runs on its own, e.g. `sudo ./setup/verification/check_firewall.sh`.

## Test suite

`./setup/tests/run_tests.sh` needs no root and changes nothing: it runs
`bash -n` and ShellCheck on every script, plus unit tests of the pure helpers
(validators, mount-denial policy, redaction, managed-block editing, JSON
escaping, allowlist parsing, the logrotate policy, the rsyslog forwarding config, the Python audit helper).

## Status on 2026-09-27

- ShellCheck is clean on all 43 scripts and 127 of 127 tests pass.
- A full dry run completes with no errors on Ubuntu 24.04.
- A real offline-mode agent run confirmed from inside the container: UID 1000, no effective or bounding capabilities, `NoNewPrivs 1`, seccomp active, read-only root filesystem, no network, only the named variable present, cgroup limits applied (256 MB, 64 PIDs, 0.5 CPU), no Docker socket, and a redacted `Authorization` header in the agent log.
- The timeout path killed a 60-second job after 3 seconds, logged `timeout`, and left no container behind.
- Restricted mode has not been verified end to end: the test host dropped container-to-container traffic (see [troubleshooting](troubleshooting.md)).
- Agent runner events were confirmed to reach the system journal (`journalctl -t ai-agent-runner`).
- The bootstrap itself, including log management, has not yet been applied with root.
