# Self-Hosted GitHub Actions Runners

This document describes the self-hosted GitHub Actions runners setup for test-app.

## Overview

- **Purpose**: Run CI/CD without consuming GitHub-hosted runner credits
- **Location**: Configurable directory (default: `/opt/actions-runner-*`)
- **Runners**: 1-2 parallel runners for matrix jobs
- **Auto-start**: Yes (systemd services)
- **Auto-update**: Yes (enabled by default)

## Prerequisites

- Linux server (Ubuntu 20.04+ recommended)
- GitHub CLI installed: `gh`
- Authenticated: `gh auth status`
- Docker installed: For running containers
- kubectl installed: For E2E tests
- Rust toolchain installed

## Installation

### Step 1: Authenticate GitHub CLI

```bash
gh auth login
```

Follow prompts to authenticate.

### Step 2: Clone Repository

```bash
git clone https://github.com/your-org/test-app.git
cd test-app
```

### Step 3: Run Setup Script

```bash
chmod +x scripts/setup-github-runners.sh
sudo ./scripts/setup-github-runners.sh
```

The script will:
1. Check prerequisites (Docker, kubectl, gh CLI, Rust)
2. Verify gh CLI authentication
3. Download latest GitHub Actions runner
4. Generate registration tokens via gh CLI
5. Configure runners
6. Install as systemd services
7. Setup daily Docker cleanup
8. Verify installation

### Step 4: Verify Installation

```bash
# Check runner status
sudo systemctl status 'actions.runner.*'

# Check runner registration
# Navigate to: https://github.com/your-org/test-app/settings/actions/runners
```

## Configuration

### Runner Labels

Configure labels in GitHub Actions workflows:

```yaml
jobs:
  test:
    runs-on: [self-hosted, linux, x64]
```

### Runner Directory

Default locations:
- Runner 1: `/opt/actions-runner-1`
- Runner 2: `/opt/actions-runner-2`

## Management

### Check Status

```bash
# All runners
sudo systemctl status 'actions.runner.*'

# Specific runner
sudo systemctl status actions.runner.your-org-test-app.runner-1.service
```

### View Logs

```bash
# Follow all runner logs
sudo journalctl -u 'actions.runner.*' -f

# Specific runner
sudo journalctl -u actions.runner.your-org-test-app.runner-1.service -f

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
sudo systemctl restart actions.runner.your-org-test-app.runner-1.service
```

### Disable/Enable Auto-start

```bash
# Disable auto-start on boot
sudo systemctl disable 'actions.runner.*'

# Enable auto-start on boot
sudo systemctl enable 'actions.runner.*'
```

## Docker Cleanup

### Automated Cleanup

A systemd timer runs daily at midnight:

```bash
# View timer status
sudo systemctl status github-runner-docker-cleanup.timer

# View cleanup logs
sudo journalctl -u github-runner-docker-cleanup.service -n 100
```

Cleanup actions:
- Remove unused containers (> 24 hours old)
- Remove dangling images
- Remove unused networks
- Remove unused volumes
- Clean build cache

### Manual Cleanup

```bash
# Clean everything
sudo docker system prune -af

# Clean with filters
sudo docker system prune -af --filter "until=24h"
```

## Monitoring

### GitHub UI

Check runner status:
- https://github.com/your-org/test-app/settings/actions/runners

Status indicators:
- **Green (Idle)**: Runner online and waiting
- **Yellow (Active)**: Runner executing job
- **Gray (Offline)**: Runner disconnected

### System Resources

```bash
# CPU and memory
htop

# Disk usage
df -h /opt/actions-runner-*
docker system df

# Running containers
docker ps
```

## Troubleshooting

### Runner Not Connecting

```bash
# Check service status
sudo systemctl status actions.runner.your-org-test-app.runner-1.service

# Check logs
sudo journalctl -u actions.runner.your-org-test-app.runner-1.service -n 100

# Restart runner
sudo systemctl restart actions.runner.your-org-test-app.runner-1.service
```

### Jobs Failing

```bash
# Check Docker is running
sudo systemctl status docker

# Check kubectl
kubectl cluster-info 2>/dev/null || echo "No cluster"

# Check disk space
df -h /opt/actions-runner-*
```

### Disk Space Issues

```bash
# Manual cleanup
sudo docker system prune -af

# Remove old Kind clusters
kind get clusters | grep -v '^No' | xargs -r kind delete cluster --name

# Check what's using space
sudo du -sh /opt/actions-runner-*/*
```

## Security

### For Private Repositories Only

Self-hosted runners should only be used for **private repositories** to prevent:
- Arbitrary code execution from PRs
- Credential theft
- Resource abuse

### Best Practices

- ✅ Keep runner software updated
- ✅ Monitor runner logs for suspicious activity
- ✅ Limit runner access to necessary resources
- ✅ Use repository-level runners for sensitive repos
- ✅ Regularly review runner activity
- ❌ Don't use self-hosted runners for public repos
- ❌ Don't disable auto-update

## Performance

### Expected Behavior

With 1-2 parallel runners:
- CI workflows run in parallel
- E2E tests: ~15-20 minutes per job
- Zero GitHub Actions credits consumed

### Resource Requirements

Per job:
- **CPU**: 2-4 cores
- **Memory**: 4-6 GB
- **Disk**: 10-15 GB temporary

Minimum for 2 runners:
- **CPU**: 4 cores (8+ recommended)
- **Memory**: 8 GB (16+ recommended)
- **Disk**: 50 GB free space

## Updates

### Runner Auto-Update

Runners automatically update when GitHub releases new versions.

### Manual Update (if needed)

```bash
# Download new version
cd /tmp
wget https://github.com/actions/runner/releases/download/v2.XXX.X/actions-runner-linux-x64-2.XXX.X.tar.gz

# Stop runner
cd /opt/actions-runner-1
sudo ./svc.sh stop

# Backup current
sudo cp -r /opt/actions-runner-1 /opt/actions-runner-1.backup

# Extract new
sudo tar xzf /tmp/actions-runner-linux-x64-2.XXX.X.tar.gz -C /opt/actions-runner-1

# Restart
sudo ./svc.sh start
```

## Removal

```bash
# Stop and uninstall service
cd /opt/actions-runner-1
sudo ./svc.sh stop
sudo ./svc.sh uninstall

# Get removal token from GitHub UI
# Navigate to: Settings → Actions → Runners → Runner → Remove

# Remove runner
sudo -u <RUNNER_USER> ./config.sh remove --token <REMOVAL_TOKEN>

# Remove directory
sudo rm -rf /opt/actions-runner-1

# Remove Docker cleanup
sudo systemctl stop github-runner-docker-cleanup.timer
sudo systemctl disable github-runner-docker-cleanup.timer
sudo rm /etc/systemd/system/github-runner-docker-cleanup.timer
sudo rm /etc/systemd/system/github-runner-docker-cleanup.service
sudo systemctl daemon-reload
```

## Additional Resources

- [GitHub Actions Runner Documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
- [GitHub Actions Runner Releases](https://github.com/actions/runner/releases)
- [Docker System Prune](https://docs.docker.com/engine/reference/commandline/system_prune/)
