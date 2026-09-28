# Configuration

All toggles live in [`setup/config/workstation.conf`](../setup/config/workstation.conf).
Machine-specific overrides go in `workstation.local.conf`, which is git-ignored
and loaded second. Both are sourced as root, so the loader refuses a file that
is world-writable or owned by another user.

| Setting | Default | Notes |
| --- | --- | --- |
| `ENABLE_AUTO_UPDATES` | true | Unattended security upgrades; `UNATTENDED_AUTO_REBOOT=false` |
| `ENABLE_FIREWALL` | true | `FIREWALL_ALLOW_INBOUND=()` for extra inbound rules |
| `ENABLE_SSH_SERVER` | false | `SSH_PORT`, `SSH_ALLOW_FROM`, `SSH_ALLOW_USERS`, `SSH_ALLOW_TCP_FORWARDING=true` |
| `ENABLE_SYSCTL_HARDENING` | true | Kernel and network settings |
| `ENABLE_APPARMOR` | true | Status and enablement only |
| `ENABLE_SERVICE_REVIEW` | true | `SERVICES_TO_DISABLE` lists the only services disabled automatically |
| `ENABLE_PERMISSION_FIXES` | true | Only removes permission bits |
| `ENABLE_PYTHON` | true | |
| `ENABLE_NODE` | true | `NODE_MAJOR=24`, `ENABLE_PNPM=true`, `NPM_IGNORE_SCRIPTS=false` |
| `ENABLE_GIT` | true | `GIT_APPLY_SAFE_DEFAULTS=true` |
| `ENABLE_CONTAINERS` | true | `CONTAINER_RUNTIME=both`, `DOCKER_PUBLISH_LOCALHOST_ONLY=true`, `DOCKER_ADD_USER_TO_GROUP=false` |
| `ENABLE_KUBERNETES` | false | `KUBERNETES_MINOR=v1.34`, `KIND_VERSION=v0.30.0` |
| `ENABLE_TERRAFORM` | false | |
| `ENABLE_AUDITD` | true | `AUDITD_LOG_ROOT_COMMANDS=true` |
| `ENABLE_AIDE` | true | `AIDE_INIT_DB=false` (the first baseline takes 5–20 minutes) |
| `ENABLE_CONTAINER_SCANNING` | true | Trivy |
| `ENABLE_SECRETS_SCANNING` | true | Gitleaks |
| `ENABLE_SURICATA` | false | `SURICATA_INTERFACE=""` means the default-route interface |
| `ENABLE_MALWARE_SCANNING` | false | ClamAV and rkhunter |
| `ENABLE_LOG_MANAGEMENT` | true | `JOURNAL_MAX_USE=2G`, `JOURNAL_MAX_RETENTION=6month` |
| `ENABLE_REMOTE_LOGGING` | false | `LOG_REMOTE_HOST`, `LOG_REMOTE_PORT=6514`, `LOG_REMOTE_TLS=true`, `LOG_REMOTE_CA_FILE` (required with TLS) |
| `ENABLE_FAIL2BAN` | false | Only takes effect with `ENABLE_SSH_SERVER=true` |
| `ENABLE_WAZUH_AGENT` | false | Needs `WAZUH_MANAGER` |
| `ENABLE_AGENT_SANDBOX` | true | `AGENT_CONTAINER_RUNTIME=auto`, `AGENT_DEFAULT_NETWORK=offline`, `AGENT_LOG_TO_JOURNAL=true` |
| Agent limits | 2g · 2 CPUs · 256 PIDs · 1800 s | `AGENT_MAX_MEMORY`, `AGENT_MAX_CPUS`, `AGENT_MAX_PIDS`, `AGENT_TIMEOUT` |
| Aggregate agent ceiling | 50% memory · 400% CPU · 4096 tasks | `AGENTS_SLICE_*`, Docker agents only |

## Repository signing keys

Fingerprints are pinned in the same file where known:
`DOCKER_KEY_FINGERPRINT`, `HASHICORP_KEY_FINGERPRINT` and
`WAZUH_KEY_FINGERPRINT`. The NodeSource, Trivy and Kubernetes fingerprints are
empty, so those keys are trusted on first download and their fingerprints are
logged. Pin them after verifying them out of band.
