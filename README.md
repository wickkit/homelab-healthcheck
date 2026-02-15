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
| **Disk Trends** | Projects days until full from 7-day history | <30 days to full | <14 days to full |
| **SMART Health** | Drive health, temp, reallocated/pending sectors, model, serial, power-on hours | Reallocated/pending sectors > 0, temp ≥ 55°C | SMART test failing |
| **Docker** | Container status, health, restart counts, images (via `docker inspect`) | Stopped/unhealthy/restarting containers | — |
| **CPU / Memory / Swap** | Load averages, usage percentages | Load > cores, mem > 85%, swap > 50% | Mem > 95% |
| **Security Updates** | Pending apt packages | Any pending | Security updates pending |
| **Uptime & Load** | System uptime, 1/5/15 min load | — | — |
| **ZFS / RAID** | Pool health (skipped if absent) | Degraded | Faulted |
| **Network** | DNS, gateway, internet connectivity + Docker service port checks | Any failure | — |
| **TLS Certificates** | Auto-discovers from Traefik or manual config | <14 days to expiry | <7 days to expiry |
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

## Configuration

All thresholds are configurable via `/opt/homelab-healthcheck/config.env`. A default config is created on install. See `config.env.example` for all options:

```bash
# Disk thresholds (percent)
DISK_WARN_PCT=80
DISK_CRIT_PCT=90

# Memory / swap thresholds (percent)
MEM_WARN_PCT=85
MEM_CRIT_PCT=95
SWAP_WARN_PCT=50

# CPU load warning multiplier (warn if 5m load > cores × multiplier)
LOAD_WARN_MULTIPLIER=1

# Docker restart count warning threshold
DOCKER_RESTART_WARN=3

# Certificate expiry thresholds (days)
CERT_WARN_DAYS=14
CERT_CRIT_DAYS=7

# Domains to check (auto-discovers from Traefik if empty)
CERT_DOMAINS=""
```

## Historical Data

Each run saves its JSON output to `/var/lib/homelab-healthcheck/history/YYYY-MM-DD.json`. History is automatically pruned after 90 days.

This enables:
- **Disk trend detection** — calculates daily growth rate from the last 7 days and projects when filesystems will fill
- **SMART tracking** — monitor temperature and sector health over time

## Uninstalling

```bash
sudo bash /opt/homelab-healthcheck/uninstall.sh
# or from the cloned repo:
sudo bash uninstall.sh
```

This removes the `healthcheck` user, sudoers entry, installed script, and SSH keys. It does **not** remove `smartmontools` or `jq` (they may be used by other things).

## License

MIT
