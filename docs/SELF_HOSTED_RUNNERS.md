# Self-Hosted GitHub Actions Runners

This document describes the self-hosted GitHub Actions runners setup for this repository.

## Overview

- **Purpose**: Run E2E tests without consuming GitHub-hosted runner credits
- **Location**: `/opt/actions-runner-1` and `/opt/actions-runner-2`
- **Runners**: 2 parallel runners for matrix jobs
- **Auto-start**: Yes (systemd services)
- **Auto-update**: Yes (enabled by default)

## Configuration

### Runners

| Name | Directory | Labels | Service Name |
|------|-----------|--------|--------------|
| seko-runner-1 | /opt/actions-runner-1 | self-hosted,linux,x64 | actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service |
| seko-runner-2 | /opt/actions-runner-2 | self-hosted,linux,x64 | actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-2.service |

### Docker Cleanup

- **Cron job**: `/etc/cron.daily/docker-cleanup`
- **Schedule**: Daily
- **Action**: Removes Docker resources older than 24 hours
- **Removes**: Unused containers, images, networks, volumes, build cache

## Installation

Run the setup script as root:

```bash
sudo ./scripts/setup-github-runners.sh
```

The script will:
1. Check prerequisites (Docker, kubectl, flux, cargo, etc.)
2. Download latest GitHub Actions runner
3. Prompt for registration tokens (from GitHub UI)
4. Configure both runners
5. Install as systemd services
6. Setup daily Docker cleanup cron job
7. Verify installation

### Getting Registration Tokens

For each runner, you'll need a registration token from GitHub:

1. Navigate to: https://github.com/enchantednatures/rust-knative-flux-template/settings/actions/runners/new
2. Copy the token from the `./config.sh` command shown
3. Paste when prompted by the setup script

**Note**: Tokens expire after 1 hour. The script will prompt for each runner sequentially.

## Management

### Check Status

```bash
# All runners
sudo systemctl status 'actions.runner.*'

# Specific runner
sudo systemctl status actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service
```

### View Logs

```bash
# Follow all runner logs
sudo journalctl -u 'actions.runner.*' -f

# Specific runner
sudo journalctl -u actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service -f

# Last 100 lines
sudo journalctl -u 'actions.runner.*' -n 100
```

### Start/Stop/Restart

```bash
# Stop all runners
sudo systemctl stop 'actions.runner.*'

# Start all runners
sudo systemctl start 'actions.runner.*'

# Restart all runners
sudo systemctl restart 'actions.runner.*'

# Specific runner
sudo systemctl restart actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service
```

### Disable/Enable Auto-start

```bash
# Disable auto-start on boot
sudo systemctl disable 'actions.runner.*'

# Enable auto-start on boot
sudo systemctl enable 'actions.runner.*'
```

## Monitoring

### GitHub UI

Check runner status in GitHub:
- https://github.com/enchantednatures/rust-knative-flux-template/settings/actions/runners

Status indicators:
- **Green (Idle)**: Runner is online and waiting for jobs
- **Yellow (Active)**: Runner is executing a job
- **Gray (Offline)**: Runner is not connected

### System Resources

```bash
# CPU and memory usage
htop

# Disk usage
df -h /opt/actions-runner-*

# Docker disk usage
docker system df
```

### Check Running Jobs

```bash
# List running containers (shows active jobs)
docker ps

# List Kind clusters (E2E tests create these)
kind get clusters
```

## Troubleshooting

### Runner Not Connecting

```bash
# Check service status
sudo systemctl status actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service

# Check logs for errors
sudo journalctl -u actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service -n 100

# Restart runner
sudo systemctl restart actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service
```

### Jobs Failing

```bash
# Check if Docker is running
sudo systemctl status docker

# Check if kubectl can connect (shouldn't in idle state, but tests will create clusters)
kubectl cluster-info 2>/dev/null || echo "No cluster (this is normal when idle)"

# Check disk space
df -h /opt/actions-runner-*
df -h /var/lib/docker
```

### Disk Space Issues

```bash
# Manual Docker cleanup
sudo docker system prune -af

# Remove old Kind clusters
kind get clusters | grep -v '^No' | xargs -r kind delete cluster --name

# Check what's using space
sudo du -sh /opt/actions-runner-*/*
sudo du -sh /var/lib/docker/*
```

### Runner Offline After Reboot

```bash
# Check if service is enabled
sudo systemctl is-enabled actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service

# If not enabled, enable it
sudo systemctl enable actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service

# Start the service
sudo systemctl start actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service
```

## Updates

### Runner Auto-Update

Runners automatically update themselves when GitHub releases new versions. No action required.

To verify auto-update is enabled:
```bash
# Check runner version
cat /opt/actions-runner-1/.runner

# Auto-update is enabled by default unless explicitly disabled during setup
```

### Manual Update (if needed)

If auto-update fails, manually update:

```bash
# Download new version
cd /tmp
wget https://github.com/actions/runner/releases/download/v2.XXX.X/actions-runner-linux-x64-2.XXX.X.tar.gz

# Stop runner
cd /opt/actions-runner-1
sudo ./svc.sh stop

# Backup current version
sudo cp -r /opt/actions-runner-1 /opt/actions-runner-1.backup

# Extract new version
sudo tar xzf /tmp/actions-runner-linux-x64-2.XXX.X.tar.gz -C /opt/actions-runner-1

# Restart runner
sudo ./svc.sh start

# Verify
sudo systemctl status actions.runner.enchantednatures-rust-knative-flux-template.seko-runner-1.service
```

## Removal

To completely remove a runner:

```bash
# Stop and uninstall service
cd /opt/actions-runner-1
sudo ./svc.sh stop
sudo ./svc.sh uninstall

# Get removal token from GitHub
# Navigate to: https://github.com/enchantednatures/rust-knative-flux-template/settings/actions/runners
# Click the runner, then "Remove"
# Copy the removal token from the command shown

# Remove runner registration
sudo -u <RUNNER_USER> ./config.sh remove --token <REMOVAL_TOKEN>

# Remove directory
sudo rm -rf /opt/actions-runner-1

# Repeat for runner-2 if needed
```

To remove Docker cleanup cron job:
```bash
sudo rm /etc/cron.daily/docker-cleanup
```

## Security Considerations

### Private Repository
This setup is designed for **private repositories only**. Self-hosted runners on public repositories can be a security risk as anyone can create a PR and execute arbitrary code on your runner.

### Runner Isolation
- Runners execute in `/opt/actions-runner-{1,2}/_work/` workspace
- Docker containers run with runner user permissions
- Runners do not have elevated privileges (except Docker access)

### Token Security
- Registration tokens expire after 1 hour
- Removal tokens are required to deregister runners
- Runner credentials stored in `/opt/actions-runner-{1,2}/.credentials`

### Best Practices
- ✅ Keep runner software updated (auto-update enabled)
- ✅ Monitor runner logs for suspicious activity
- ✅ Limit runner access to necessary resources only
- ✅ Use repository-level runners (not organization-level for sensitive repos)
- ✅ Regularly review runner activity in GitHub UI
- ❌ Don't use self-hosted runners for public repositories
- ❌ Don't disable auto-update without good reason
- ❌ Don't run multiple workflows simultaneously if disk space is limited

## Performance

### Expected Behavior

With 2 parallel runners:
- Matrix jobs run simultaneously (no-s3 and with-s3)
- Total workflow time: ~15-20 minutes (vs 30-40 sequential)
- Zero GitHub Actions credits consumed

### Resource Usage Per Job

Typical E2E test job uses:
- **CPU**: 2-4 cores during build/test, 1 core idle
- **Memory**: 4-6 GB during Kind cluster operations
- **Disk**: ~10-15 GB temporary (Docker images, Kind clusters, build cache)

### System Requirements

Recommended:
- **CPU**: 4+ cores (8+ for parallel jobs)
- **Memory**: 8+ GB (16+ GB recommended)
- **Disk**: 50+ GB free space in `/opt` and `/var/lib/docker`

Current system (seko):
- ✅ CPU: 16 cores (excellent)
- ✅ Memory: 24 GB available (excellent)
- ⚠️  Disk: 32 GB free (adequate, monitor usage)

## Maintenance Tasks

### Daily (Automated)
- Docker cleanup (via cron job)

### Weekly (Manual)
```bash
# Check runner status
sudo systemctl status 'actions.runner.*'

# Check disk usage
df -h /opt/actions-runner-*
docker system df

# Review logs for errors
sudo journalctl -u 'actions.runner.*' --since "7 days ago" | grep -i error
```

### Monthly (Manual)
```bash
# Verify runners are registered in GitHub UI
# Check for runner updates (auto-update should handle this)
# Review Docker cleanup cron job logs
sudo grep docker-cleanup /var/log/syslog

# Check for orphaned Kind clusters
kind get clusters

# Check for orphaned Docker networks
docker network ls | grep kind
```

## Workflow Configuration

The E2E workflow (`.github/workflows/template-e2e-test.yaml`) should use:

```yaml
jobs:
  verify-and-test:
    runs-on: [self-hosted, linux, x64]  # Instead of ubuntu-latest
```

This allows both matrix jobs to run in parallel on your two runners.

## Support

For issues or questions:
1. Check troubleshooting section above
2. Review GitHub Actions runner documentation: https://docs.github.com/en/actions/hosting-your-own-runners
3. Check runner logs for specific errors
4. Verify system resources are adequate

## Additional Resources

- [GitHub Actions Runner Documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
- [GitHub Actions Runner Releases](https://github.com/actions/runner/releases)
- [Docker System Prune Documentation](https://docs.docker.com/engine/reference/commandline/system_prune/)
- [systemd Service Management](https://www.freedesktop.org/software/systemd/man/systemctl.html)
