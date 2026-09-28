# Security Setup Scripts

Hardened, repeatable Ubuntu workstation bootstrap for developing and running
autonomous AI agents.

```bash
sudo ./setup/bootstrap.sh --dry-run            # preview
sudo ./setup/bootstrap.sh                      # apply (idempotent)
sudo ./setup/verification/security_report.sh   # verify

./setup/agents/create_workspace.sh --new
./setup/agents/agent_runner.sh --build-image
./setup/agents/agent_runner.sh --workspace ~/agent-workspaces/agent-001 --network restricted -- python agent.py
```

New machine: follow **[docs/getting-started.md](docs/getting-started.md)**.

Documentation: **[docs/](docs/README.md)** (threat model, installation,
configuration, modules, agent sandbox, verification, rollback, troubleshooting).
The full single-page reference is [setup/README.md](setup/README.md).
