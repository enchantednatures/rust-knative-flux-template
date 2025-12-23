#!/bin/bash
#
# GitHub Actions Self-Hosted Runner Setup Script
# 
# Sets up two GitHub Actions runners for parallel E2E testing
# - Installs to /opt/actions-runner-{1,2}
# - Configures as systemd services
# - Sets up daily Docker cleanup
# - Enables auto-update
#
# Usage: sudo ./setup-github-runners.sh
#

set -euo pipefail

# Configuration
REPO_URL="https://github.com/enchantednatures/rust-knative-flux-template"
RUNNER_BASE_DIR="/opt/actions-runner"
RUNNER_USER="${SUDO_USER:-$USER}"
RUNNER_1_NAME="seko-runner-1"
RUNNER_2_NAME="seko-runner-2"
RUNNER_LABELS="self-hosted,linux,x64"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    if [[ -z "${SUDO_USER:-}" ]]; then
        log_error "Please run with sudo, not as root user directly"
        log_info "Usage: sudo ./setup-github-runners.sh"
        exit 1
    fi
    
    log_success "Running as root with SUDO_USER=${SUDO_USER}"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing_deps=()
    
    # Check required commands
    for cmd in docker kubectl flux cargo rustc kind jq curl gh; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
    
    # Check systemd
    if ! systemctl --version &> /dev/null; then
        log_error "systemd is required but not found"
        exit 1
    fi
    
    # Check gh CLI authentication
    if ! sudo -u "$RUNNER_USER" gh auth status &> /dev/null; then
        log_error "GitHub CLI (gh) is not authenticated"
        log_info "Please run: gh auth login"
        exit 1
    fi
    
    log_success "All prerequisites satisfied"
}

# Get latest GitHub Actions runner version
get_latest_runner_version() {
    local api_url="https://api.github.com/repos/actions/runner/releases/latest"
    local version
    
    version=$(curl -s "$api_url" | jq -r '.tag_name' | sed 's/^v//')
    
    if [[ -z "$version" || "$version" == "null" ]]; then
        return 1
    fi
    
    echo "$version"
}

# Download and extract runner
download_runner() {
    local version=$1
    local runner_dir=$2
    
    log_info "Downloading GitHub Actions runner v${version}..."
    
    local download_url="https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"
    local temp_dir
    temp_dir=$(mktemp -d)
    local tarball="${temp_dir}/actions-runner.tar.gz"
    
    # Download
    if ! curl -L -o "$tarball" "$download_url"; then
        log_error "Failed to download runner from $download_url"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Create runner directory
    mkdir -p "$runner_dir"
    
    # Extract
    log_info "Extracting to ${runner_dir}..."
    if ! tar xzf "$tarball" -C "$runner_dir"; then
        log_error "Failed to extract runner archive"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Set ownership
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "$runner_dir"
    
    # Cleanup
    rm -rf "$temp_dir"
    
    log_success "Runner extracted to ${runner_dir}"
}

# Generate registration token using gh CLI
get_registration_token() {
    local token
    token=$(sudo -u "$RUNNER_USER" gh api \
        repos/enchantednatures/rust-knative-flux-template/actions/runners/registration-token \
        -X POST | jq -r '.token')
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        return 1
    fi
    
    echo "$token"
}

# Configure runner
configure_runner() {
    local runner_dir=$1
    local runner_name=$2
    local token=$3
    
    log_info "Configuring ${runner_name}..."
    
    cd "$runner_dir"
    
    # Run configuration as the runner user
    if ! sudo -u "$RUNNER_USER" ./config.sh \
        --url "$REPO_URL" \
        --token "$token" \
        --name "$runner_name" \
        --labels "$RUNNER_LABELS" \
        --work _work \
        --unattended \
        --replace; then
        log_error "Failed to configure ${runner_name}"
        exit 1
    fi
    
    log_success "${runner_name} configured successfully"
}

# Install as systemd service
install_service() {
    local runner_dir=$1
    local runner_name=$2
    
    log_info "Installing ${runner_name} as systemd service..."
    
    cd "$runner_dir"
    
    # Install service
    if ! ./svc.sh install "$RUNNER_USER"; then
        log_error "Failed to install service for ${runner_name}"
        exit 1
    fi
    
    # Start service
    if ! ./svc.sh start; then
        log_error "Failed to start service for ${runner_name}"
        exit 1
    fi
    
    # Enable service (auto-start on boot)
    local service_name
    service_name=$(./svc.sh status 2>&1 | grep -oP 'actions\.runner\.[^.]+\.[^.]+\.service' | head -n1)
    
    if [[ -n "$service_name" ]]; then
        systemctl enable "$service_name"
        log_success "${runner_name} service installed and started: ${service_name}"
    else
        log_warning "${runner_name} service started but couldn't determine service name"
    fi
}

# Setup Docker cleanup cron job
setup_docker_cleanup() {
    log_info "Setting up daily Docker cleanup cron job..."
    
    local cron_file="/etc/cron.daily/docker-cleanup"
    
    cat > "$cron_file" << 'EOF'
#!/bin/bash
#
# Daily Docker cleanup for GitHub Actions runners
# Removes unused images, containers, and build cache older than 24h
#

set -euo pipefail

echo "[$(date)] Starting Docker cleanup..."

# Remove unused containers, networks, images, and build cache
docker system prune -af --filter "until=24h" 2>&1

# Remove dangling volumes
docker volume prune -f --filter "until=24h" 2>&1

echo "[$(date)] Docker cleanup completed"
EOF
    
    chmod +x "$cron_file"
    
    log_success "Docker cleanup cron job installed: ${cron_file}"
    log_info "Cleanup runs daily and removes Docker resources older than 24 hours"
}

# Verify runner status
verify_runner() {
    local runner_dir=$1
    local runner_name=$2
    
    log_info "Verifying ${runner_name} status..."
    
    cd "$runner_dir"
    
    if ./svc.sh status &> /dev/null; then
        log_success "${runner_name} is running"
        return 0
    else
        log_error "${runner_name} is not running"
        return 1
    fi
}

# Check if runner already exists
check_existing_runner() {
    local runner_dir=$1
    local runner_name=$2
    
    if [[ -d "$runner_dir" ]]; then
        log_warning "${runner_name} directory already exists: ${runner_dir}"
        echo ""
        read -r -p "Remove and reinstall? [y/N] " response
        
        if [[ "$response" =~ ^[Yy]$ ]]; then
            log_info "Removing existing ${runner_name}..."
            
            # Stop and uninstall service if it exists
            if [[ -f "${runner_dir}/svc.sh" ]]; then
                cd "$runner_dir"
                ./svc.sh stop 2>/dev/null || true
                ./svc.sh uninstall 2>/dev/null || true
            fi
            
            # Remove directory
            rm -rf "$runner_dir"
            log_success "Removed existing ${runner_name}"
        else
            log_info "Skipping ${runner_name}"
            return 1
        fi
    fi
    
    return 0
}

# Setup single runner
setup_single_runner() {
    local runner_num=$1
    local runner_name=$2
    local runner_dir="${RUNNER_BASE_DIR}-${runner_num}"
    
    echo ""
    log_info "==================================================================="
    log_info "Setting up ${runner_name}"
    log_info "==================================================================="
    
    # Check if already exists
    if ! check_existing_runner "$runner_dir" "$runner_name"; then
        return 0
    fi
    
    # Get registration token
    log_info "Generating registration token for ${runner_name}..."
    local token
    token=$(get_registration_token)
    
    if [[ -z "$token" ]]; then
        log_error "Failed to generate registration token"
        log_info "Ensure gh CLI is authenticated: gh auth login"
        exit 1
    fi
    
    log_success "Registration token generated for ${runner_name}"
    
    # Download runner
    log_info "Fetching latest GitHub Actions runner version..."
    local version
    version=$(get_latest_runner_version)
    
    if [[ -z "$version" ]]; then
        log_error "Failed to fetch runner version from GitHub API"
        exit 1
    fi
    
    log_success "Latest runner version: $version"
    download_runner "$version" "$runner_dir"
    
    # Configure runner
    configure_runner "$runner_dir" "$runner_name" "$token"
    
    # Install as service
    install_service "$runner_dir" "$runner_name"
    
    # Verify
    verify_runner "$runner_dir" "$runner_name"
    
    log_success "${runner_name} setup complete!"
}

# Display summary
display_summary() {
    echo ""
    echo "==================================================================="
    log_success "GitHub Actions Runners Setup Complete!"
    echo "==================================================================="
    echo ""
    echo "Runners installed:"
    echo "  1. ${RUNNER_1_NAME} - ${RUNNER_BASE_DIR}-1"
    echo "  2. ${RUNNER_2_NAME} - ${RUNNER_BASE_DIR}-2"
    echo ""
    echo "Services:"
    echo "  • Auto-start on boot: Enabled"
    echo "  • Auto-update: Enabled (default)"
    echo ""
    echo "Docker cleanup:"
    echo "  • Cron job: /etc/cron.daily/docker-cleanup"
    echo "  • Schedule: Daily (removes resources >24h old)"
    echo ""
    echo "Verify runners are registered:"
    echo "  ${REPO_URL}/settings/actions/runners"
    echo ""
    echo "Check service status:"
    echo "  sudo systemctl status 'actions.runner.*'"
    echo ""
    echo "View logs:"
    echo "  sudo journalctl -u 'actions.runner.*' -f"
    echo ""
    echo "Next steps:"
    echo "  1. Verify runners show as 'Idle' in GitHub UI"
    echo "  2. Update .github/workflows/template-e2e-test.yaml:"
    echo "     Change 'runs-on: ubuntu-latest' to 'runs-on: [self-hosted, linux, x64]'"
    echo "  3. Push changes and watch workflows run on your runners!"
    echo ""
    log_info "Note: You'll update the workflow file separately as requested"
    echo "==================================================================="
}

# Main execution
main() {
    echo ""
    echo "==================================================================="
    echo "GitHub Actions Self-Hosted Runner Setup"
    echo "==================================================================="
    echo ""
    echo "This script will:"
    echo "  • Install 2 GitHub Actions runners to /opt/actions-runner-{1,2}"
    echo "  • Configure them as systemd services (auto-start on boot)"
    echo "  • Enable auto-update (runners update themselves)"
    echo "  • Setup daily Docker cleanup cron job"
    echo ""
    echo "Configuration:"
    echo "  Repository: ${REPO_URL}"
    echo "  Runner 1: ${RUNNER_1_NAME}"
    echo "  Runner 2: ${RUNNER_2_NAME}"
    echo "  Labels: ${RUNNER_LABELS}"
    echo "  User: ${RUNNER_USER}"
    echo ""
    
    read -r -p "Continue? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Setup cancelled"
        exit 0
    fi
    
    # Run checks
    check_root
    check_prerequisites
    
    # Setup runners
    setup_single_runner "1" "$RUNNER_1_NAME"
    setup_single_runner "2" "$RUNNER_2_NAME"
    
    # Setup Docker cleanup
    setup_docker_cleanup
    
    # Display summary
    display_summary
}

# Run main
main "$@"
