# Troubleshooting and limitations

The largest remaining risk is that containers are not virtual machines: a
kernel or runtime bug can let an agent break out, and rootless Podman limits
the damage without preventing it.

## Known limitations

- Restricted mode filters by domain only and does not inspect content.
- Docker-published ports bypass UFW; the 127.0.0.1 default helps, but `-p 0.0.0.0:...` or host networking still exposes services.
- Agent code run directly in your shell bypasses the whole sandbox.
- AIDE and rkhunter are noisy after updates and only help if someone reads the reports.
- The NodeSource, Trivy and Kubernetes keys are trusted on first download. The pinned Docker, HashiCorp and Wazuh fingerprints were written from memory and should be checked against each vendor's published values.
- Suricata watches one interface, chosen at install time.
- Secret redaction is pattern-based; the real defence is not printing secrets.
- Without remote forwarding, anyone who gains root can erase local logs; sealing only makes edits to the journal detectable, not the other log files.
- WSL, non-systemd and non-Ubuntu systems are unsupported.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| A module failed | Read `/var/log/ai-workstation-bootstrap/bootstrap-<run-id>.log`, fix the cause, re-run; finished steps are skipped |
| apt cannot use a repository | The vendor has no packages for your release yet; the source file was removed so apt still works |
| Signing key fingerprint mismatch | Do not bypass it; verify the vendor's key and update the fingerprint in the config |
| Locked out of SSH | From the console: `sudo ufw allow from <your-ip> to any port 22 proto tcp`, or roll back the last run |
| Something broke after sysctl hardening | Run `check_sysctl.sh`, remove the offending key from the managed file, re-run |
| Your user cannot reach the Docker daemon | Use rootless Podman (`--runtime podman`), or accept the docker group's root-equivalence |
| Agent image not found | `./setup/agents/agent_runner.sh --build-image` (Podman images are per user) |
| `pip install` fails with read-only file system | Expected: install into a venv inside `/workspace` |
| Rootless Podman ignores `--cpus` | Log out and back in after `resource_limits.sh`; check `/etc/subuid` |
| Every restricted-mode request times out | If the proxy log (`network_policy.sh logs`) is empty, the host is dropping container-to-container traffic. Confirm with two containers on a fresh `docker network create` network, then check `sudo iptables -L FORWARD -n -v` and `sudo iptables -L DOCKER-USER -n -v` for DROP rules (often custom UFW `after.rules` or a ufw-docker setup) |
| Remote logging fails to start | Run `sudo rsyslogd -N1` for the config error; check `LOG_REMOTE_CA_FILE` exists and that the collector's certificate name matches `LOG_REMOTE_HOST`; queued messages are kept on disk until it connects |
| `journalctl --verify` reports failures | Corruption after a crash is common; tampering is possible. Compare with the remote copy if forwarding is on before trusting local logs |
| AIDE reports many changes after updates | Review them, then `aide.sh update` and `aide.sh accept` |

## Future improvements

1. A microVM backend for agents (Kata Containers, Firecracker or gVisor) for hostile-code isolation.
2. Per-agent allowlists and size limits in the egress proxy.
3. Firewall rules blocking the LAN in internet mode.
4. A local credential broker issuing scoped, expiring keys per session.
5. Custom seccomp and AppArmor profiles for agent containers.
6. Forwarding the agent-written event logs (not just the runner's) to the remote collector.
7. CI that runs the tests and a full bootstrap in a disposable VM.
