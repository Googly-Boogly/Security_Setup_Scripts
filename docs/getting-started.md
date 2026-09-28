# Getting started on a fresh Ubuntu machine

This walks through a first install from a clean Ubuntu 22.04, 24.04 or 26.04
system to running your first sandboxed agent. For every bootstrap option, see
[Installation and dry-run](installation.md).

## 1. Get the files onto the machine

Either clone the repository:

```bash
sudo apt update && sudo apt install -y git
git clone <your-repo-url> ~/Security_Setup_Scrips
cd ~/Security_Setup_Scrips
```

or copy it from another machine:

```bash
# on the source machine
tar --exclude=.venv --exclude=.idea -czf aiws.tgz -C <parent-folder> Security_Setup_Scrips
scp aiws.tgz user@new-machine:~

# on the new machine
tar -xzf aiws.tgz && cd Security_Setup_Scrips
```

If the scripts lose their executable permission along the way (for example,
copied from a Windows share or a zip file), prefix commands with `bash`:
`sudo bash setup/bootstrap.sh`.

## 2. Log in as your normal user

Run everything as your own account with `sudo`, not from a root shell. The
bootstrap sets up per-user pieces (npm folder, git settings, agent workspaces)
for whoever ran `sudo`. Ubuntu's `adduser` already gives new users the
subordinate user IDs that rootless Podman needs.

## 3. If you are connected over SSH, enable SSH first

This matters for cloud VMs and headless machines. By default the bootstrap
turns the SSH server off and the firewall blocks incoming connections. Before
running it over SSH, create `setup/config/workstation.local.conf`:

```bash
cat > setup/config/workstation.local.conf <<'EOF'
ENABLE_SSH_SERVER=true
SSH_ALLOW_FROM="203.0.113.0/24"   # your IP or network; leave "" to allow any (rate-limited)
EOF
```

Also put your public key in `~/.ssh/authorized_keys` first; otherwise password
login stays enabled. The scripts ask before doing anything that could lock out
an active SSH session, but this setting avoids the question.

Any other change to the defaults (Suricata, remote logging, Kubernetes, agent
limits) goes in the same file. All options are listed in
[`setup/config/workstation.conf`](../setup/config/workstation.conf) and
explained in [Configuration](configuration.md).

## 4. Preview, then apply

```bash
sudo ./setup/bootstrap.sh --dry-run    # shows every file change and command; changes nothing
sudo ./setup/bootstrap.sh              # takes a few minutes (package downloads)
```

At the end it prints a status per module and the security report. It is safe
to re-run: completed steps are skipped. Add `--yes` for an unattended run with
no prompts.

Expected warnings on a first run:

- The NodeSource and Trivy signing keys are not pinned in the config, so their fingerprints are logged and the keys are trusted because they were downloaded over HTTPS.
- AIDE reports that no baseline exists yet (step 7).

## 5. Reboot

```bash
sudo reboot
```

This finishes any kernel updates, and logging back in applies the cgroup
delegation that lets rootless Podman enforce CPU limits.

## 6. Verify

```bash
sudo ./setup/verification/security_report.sh
```

Look at any FAIL lines first. WARN lines are items to review, such as services
listening on the network. See [Verification](verification.md).

## 7. One-time follow-ups

```bash
sudo ./setup/security/aide.sh init                # file-integrity baseline, 5-20 minutes
./setup/agents/agent_runner.sh --build-image      # build the agent image (as your user, no sudo)
./setup/agents/create_workspace.sh --new          # creates ~/agent-workspaces/agent-001
```

Optional: `sudo ./setup/security/log_management.sh setup-sealing` makes journal
tampering detectable. It shows a verification key once; store it off the
machine.

## 8. Run an agent

Offline by default:

```bash
./setup/agents/agent_runner.sh --workspace ~/agent-workspaces/agent-001 -- python3 -c 'print("hello")'
```

With access to LLM APIs and package registries through the allowlisting proxy:

```bash
ANTHROPIC_API_KEY=... ./setup/agents/agent_runner.sh --workspace ~/agent-workspaces/agent-001 \
  --network restricted --env ANTHROPIC_API_KEY -- python agent.py
```

See [AI agent sandbox](agent-sandbox.md) for network modes, secrets and limits.

## If something goes wrong

- Log: `/var/log/ai-workstation-bootstrap/bootstrap-<run-id>.log`
- Undo the last run's configuration changes: `sudo ./setup/uninstall/rollback.sh --latest` (add `--dry-run` to preview). Installed packages are kept.
- More fixes: [Troubleshooting](troubleshooting.md).
