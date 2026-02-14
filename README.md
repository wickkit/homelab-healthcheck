# homelab-healthcheck

Lightweight health monitoring for homelab servers. Outputs structured JSON that an AI assistant (or any automation) can consume over SSH.

Built for Ubuntu servers running Docker, but gracefully handles missing components.

## Quick Start

```bash
# Clone and install
git clone https://github.com/wickkit/homelab-healthcheck.git
cd homelab-healthcheck
sudo bash install.sh

# Or one-liner
curl -fsSL https://raw.githubusercontent.com/wickkit/homelab-healthcheck/main/install.sh | sudo bash
```

## What It Checks

| Check | Details | Warning | Critical |
|-------|---------|---------|----------|
| **Disk Space** | All mounted filesystems | ≥80% used | ≥90% used |
| **SMART Health** | Drive self-assessment via `smartctl` | — | Any failing drive |
| **Docker Containers** | Status, restart counts, health | Restarting/unhealthy containers | — |
| **CPU / Memory / Swap** | Load averages, usage percentages | Load > cores, mem > 85%, swap > 50% | Mem > 95% |
| **Security Updates** | Pending apt packages | Any pending | Security updates pending |
| **Uptime & Load** | System uptime, 1/5/15 min load | — | — |
| **ZFS / RAID** | Pool health (skipped if absent) | Degraded | Faulted |
| **Network** | DNS resolution + gateway ping | Any failure | — |
| **System Logs** | Critical/emergency entries since last run | Any critical entries | Any emergency entries |

## How It Works

### Dedicated User

The installer creates a `healthcheck` system user with minimal, read-only access:

- **`docker` group** — inspect container status (read-only via Docker socket)
- **`disk` group** — read SMART data from drives
- **Sudoers (restricted)** — only these commands, no password:
  - `smartctl` — read drive health
  - `apt-get update` — refresh package lists
  - `journalctl` — read system logs

No write access. No shell login beyond SSH key auth. No root.

### Running a Check

```bash
# As the healthcheck user
sudo -u healthcheck /opt/homelab-healthcheck/healthcheck.sh

# Via SSH (how Kit uses it)
ssh healthcheck@nas /opt/homelab-healthcheck/healthcheck.sh
```

Output is clean JSON to stdout. See [examples/sample-output.json](examples/sample-output.json).

### Status Levels

The top-level `status` field is the worst status across all checks:

- **`ok`** — everything healthy
- **`warning`** — something needs attention soon
- **`critical`** — something needs attention now

## Customizing Thresholds

Edit the configuration section at the top of `healthcheck.sh`:

```bash
DISK_WARN_PCT=80        # Disk usage warning threshold
DISK_CRIT_PCT=90        # Disk usage critical threshold
MEM_WARN_PCT=85         # Memory warning threshold
MEM_CRIT_PCT=95         # Memory critical threshold
SWAP_WARN_PCT=50        # Swap warning threshold
LOAD_WARN_MULTIPLIER=1  # Warn if load > (cores × multiplier)
```

## Uninstalling

```bash
sudo bash /opt/homelab-healthcheck/uninstall.sh
# or from the cloned repo:
sudo bash uninstall.sh
```

This removes the `healthcheck` user, sudoers entry, installed script, and SSH keys. It does **not** remove `smartmontools` or `jq` (they may be used by other things).

## License

MIT
