# Threat model

The design assumes an agent can be wrong, prompt-injected by content it reads,
or tricked into installing a malicious dependency, so it treats every agent as
untrusted.

| Threat | Main controls |
| --- | --- |
| Accidental destructive agent actions | Workspace-only mounts, read-only root filesystem, non-root user, timeouts |
| Agent filesystem overreach | Only the named workspace is mounted; home, `~/.ssh`, `~/.aws`, `~/.config`, `/`, the Docker socket and this repository are refused |
| Leaked API keys | Explicit `--env NAME` or `--secret` only, no environment passthrough, redaction in logs, Gitleaks, a global gitignore for secret files |
| Malicious package dependencies | Containerised execution, venv-only Python, per-user npm prefix (no `sudo npm`), optional `ignore-scripts`, Trivy |
| Data exfiltration by an agent | Offline by default; restricted mode forces traffic through an allowlisting proxy |
| Accidental network exposure | UFW deny-incoming on IPv4 and IPv6, Docker ports bound to 127.0.0.1, listener review |
| Vulnerable development services | Listener and service review, unattended security updates |
| Misconfigured containers | The report flags privileged containers, socket mounts, host network or PID, and missing agent limits |
| Persistence via compromised tooling | auditd watches on systemd units, cron, `ld.so.preload`, sudoers and SSH; AIDE integrity baseline |
| Basic malware and supply-chain mistakes | Signed apt repositories with pinned fingerprints where known, checksum-verified downloads, optional ClamAV and rkhunter |

## Not protected against

Kernel zero-days and container runtime escapes (a container is not a VM),
malicious firmware, compromised hardware, physical access, sophisticated or
nation-state attackers, unknown vulnerabilities, and agent code run directly on
the host instead of through the runner.

For hostile-code isolation, use a VM or microVM (Kata Containers, Firecracker)
or separate hardware.

## Assumptions

- A single-user developer workstation with a desktop session, not a server.
- You run the bootstrap with `sudo` from your normal account; that account is the target for per-user steps.
- Outbound internet is allowed and inbound access is not needed.
- Agents are run through containers, and you review a dry run before applying changes to an important machine.
