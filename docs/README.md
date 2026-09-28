# AI Workstation Bootstrap — Documentation

One command hardens an Ubuntu workstation, installs an AI-engineering toolchain,
adds security tooling, and sets up a container sandbox that treats every AI
agent as untrusted code. It reduces common risks; it does not make a machine
"secure".

The sandbox enforces its boundaries in the kernel and container runtime, not by
trusting the model to behave. Agents start offline, see only the one workspace
you name, get only the secrets you name, and run as a non-root user with a
read-only filesystem, no capabilities and hard resource limits.

```bash
sudo ./setup/bootstrap.sh --dry-run            # preview every change
sudo ./setup/bootstrap.sh                      # apply (safe to re-run)
sudo ./setup/verification/security_report.sh   # verify
```

## Contents

| Page | Covers |
| --- | --- |
| [Threat model](threat-model.md) | What the system protects against, what it does not, and its assumptions |
| [Installation and dry-run](installation.md) | Install steps, bootstrap options, dry-run, logs |
| [Configuration](configuration.md) | `workstation.conf`, local overrides, every toggle and default |
| [Modules](modules.md) | Architecture, OS hardening, sysctl settings, development tools, security tooling |
| [AI agent sandbox](agent-sandbox.md) | Workspaces, container controls, network modes, secrets, auditing, limits |
| [Verification](verification.md) | Security report, individual checks, test suite |
| [Rollback](rollback.md) | Backups, change manifest, rollback commands |
| [Troubleshooting and limitations](troubleshooting.md) | Known limitations, common problems, future improvements |

## Supported systems

| Ubuntu | Status |
| --- | --- |
| 24.04 LTS (noble) | Primary target, tested |
| 22.04 LTS (jammy) | Supported |
| 26.04 LTS | Supported; third-party repositories may lag a new release |

Requirements: systemd, an AppArmor-capable kernel, x86_64 or arm64, Bash 5.
The release is read from `/etc/os-release`; other Ubuntu releases need
`--allow-unsupported`, and non-Ubuntu or non-systemd systems are refused.

## Repository layout

| Folder | Contents |
| --- | --- |
| `setup/bootstrap.sh` | Entry point; runs each module in its own process and summarises |
| `setup/config/` | `workstation.conf` (all toggles) and an optional git-ignored `workstation.local.conf` |
| `setup/lib/` | Shared helpers: logging, OS detection, pure validators, reporting, permission policy, agent logic |
| `setup/hardening/` | updates, ssh, firewall, sysctl, apparmor, services, permissions |
| `setup/development/` | python, node, git, containers, kubernetes, terraform |
| `setup/security/` | auditd, aide, container_scanning, secrets_scanning, malware_scanning, suricata, wazuh_agent |
| `setup/agents/` | agent_runner, create_workspace, network_policy, resource_limits, base image, proxy policy, audit helper |
| `setup/verification/` | check_* scripts and security_report |
| `setup/uninstall/` | rollback.sh |
| `setup/tests/` | run_tests.sh (syntax, ShellCheck, unit tests; no root) |
