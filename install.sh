#!/usr/bin/env bash
# LedFX AirPlay Docker Stack Installer
# Installs Docker (if needed) and starts the LedFX + Shairport-Sync stack

set -Eeuo pipefail

# Script version
VERSION="1.0.0"

# Configuration
INSTALL_DIR="/opt/ledfx-airplay"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false

# Color output functions
function msg_info() {
    echo -e "\033[0;34mℹ\033[0m $1"
}

function msg_ok() {
    echo -e "\033[0;32m✓\033[0m $1"
}

function msg_error() {
    echo -e "\033[0;31m✗\033[0m $1" >&2
}

function msg_warn() {
    echo -e "\033[0;33m⚠\033[0m $1"
}

# Display help message
function show_help() {
    cat << EOF
LedFX AirPlay Docker Stack Installer v${VERSION}

Usage: $(basename "$0") [OPTIONS]

Options:
    -h, --help          Show this help message
    -v, --version       Show version information
    -n, --dry-run       Show what would be done without making changes
    -d, --dir DIR       Set installation directory (default: /opt/ledfx-airplay)

Description:
    Installs Docker (if needed) and deploys the LedFX + Shairport-Sync
    stack for AirPlay audio visualization.

Requirements:
    - Debian/Ubuntu Linux system
    - Root privileges (run with sudo)
    - Internet connection

EOF
}

# Display version information
function show_version() {
    echo "LedFX AirPlay Docker Stack Installer v${VERSION}"
}

# Check if running as root
function check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        msg_error "This script must be run as root (use sudo)"
        echo "Example: sudo $0"
        exit 1
    fi
}

# Detect Linux distribution
function detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        msg_error "Unable to detect Linux distribution"
        msg_error "This script requires /etc/os-release to be present"
        exit 1
    fi

    source /etc/os-release

    case "${ID}" in
        debian|ubuntu)
            msg_ok "Detected ${NAME} ${VERSION_ID}"
            return 0
            ;;
        *)
            msg_error "Unsupported distribution: ${NAME}"
            msg_error "This script is designed for Debian/Ubuntu systems"
            msg_error "You'll need to manually install Docker and run: docker compose up -d"
            exit 1
            ;;
    esac
}

# Install Docker on Debian/Ubuntu systems
function install_docker() {
    if command -v docker &>/dev/null; then
        local docker_version
        docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        msg_ok "Docker already installed (version ${docker_version})"
        return 0
    fi

    msg_info "Installing Docker..."

    if [[ "${DRY_RUN}" == true ]]; then
        msg_info "[DRY RUN] Would install Docker from official repository"
        return 0
    fi

    # Update package index
    apt-get update -qq || {
        msg_error "Failed to update package index"
        msg_error "Check your internet connection and try again"
        exit 1
    }

    # Install prerequisites
    apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release || {
        msg_error "Failed to install prerequisites"
        exit 1
    }

    # Detect distro for Docker repo
    source /etc/os-release
    local docker_distro="${ID}"

    # Ubuntu derivatives should use ubuntu repo
    if [[ -n "${ID_LIKE:-}" ]] && [[ "${ID_LIKE}" == *"ubuntu"* ]] && [[ "${ID}" != "ubuntu" ]]; then
        docker_distro="ubuntu"
    fi

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${docker_distro}/gpg" | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg || {
        msg_error "Failed to download Docker GPG key"
        msg_error "Check your internet connection"
        exit 1
    }
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_distro} \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    apt-get update -qq || {
        msg_error "Failed to update package index after adding Docker repository"
        exit 1
    }

    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin || {
        msg_error "Failed to install Docker packages"
        msg_error "Check the error messages above for details"
        exit 1
    }

    # Start and enable Docker
    systemctl start docker || {
        msg_error "Failed to start Docker service"
        exit 1
    }

    systemctl enable docker || {
        msg_warn "Failed to enable Docker service at boot"
    }

    msg_ok "Docker installed successfully"
}

# Set up installation directory structure
function setup_directory() {
    msg_info "Setting up installation directory..."

    if [[ "${DRY_RUN}" == true ]]; then
        if [[ -d "${INSTALL_DIR}" ]]; then
            msg_info "[DRY RUN] Would backup existing directory to ${INSTALL_DIR}.backup.<timestamp>"
        fi
        msg_info "[DRY RUN] Would create directory structure at ${INSTALL_DIR}"
        return 0
    fi

    # Handle existing installation
    if [[ -d "${INSTALL_DIR}" ]]; then
        msg_warn "Installation directory already exists: ${INSTALL_DIR}"

        # Check if there's a running stack
        if docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps --quiet 2>/dev/null | grep -q .; then
            msg_info "Existing stack is running. Stopping services..."
            docker compose -f "${INSTALL_DIR}/docker-compose.yml" down
        fi

        local backup_dir="${INSTALL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        msg_info "Backing up existing installation to: ${backup_dir}"
        mv "${INSTALL_DIR}" "${backup_dir}"
        msg_ok "Backup created"
    fi

    # Create directory structure
    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}/configs"
    mkdir -p "${INSTALL_DIR}/pulse"

    # Set ownership for Pulse directory (LedFX runs as UID 1000)
    chown -R 1000:1000 "${INSTALL_DIR}/pulse" || {
        msg_warn "Failed to set ownership on pulse directory"
        msg_warn "You may need to manually run: sudo chown -R 1000:1000 ${INSTALL_DIR}/pulse"
    }

    msg_ok "Directory structure created"
}

# Copy configuration files to installation directory
function copy_configs() {
    msg_info "Copying configuration files..."

    if [[ "${DRY_RUN}" == true ]]; then
        msg_info "[DRY RUN] Would copy docker-compose.yml and configs to ${INSTALL_DIR}"
        return 0
    fi

    if [[ ! -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        msg_error "docker-compose.yml not found in ${SCRIPT_DIR}"
        exit 1
    fi

    cp "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/" || {
        msg_error "Failed to copy docker-compose.yml"
        exit 1
    }

    if [[ -d "${SCRIPT_DIR}/configs" ]]; then
        cp -r "${SCRIPT_DIR}/configs"/* "${INSTALL_DIR}/configs/" || {
            msg_error "Failed to copy configuration files"
            exit 1
        }
    else
        msg_warn "configs directory not found in ${SCRIPT_DIR}"
    fi

    msg_ok "Configuration files copied"
}

# Start the Docker Compose stack
function start_stack() {
    msg_info "Starting LedFX AirPlay stack..."

    if [[ "${DRY_RUN}" == true ]]; then
        msg_info "[DRY RUN] Would run: docker compose -f ${INSTALL_DIR}/docker-compose.yml up -d"
        return 0
    fi

    cd "${INSTALL_DIR}" || {
        msg_error "Failed to change to installation directory"
        exit 1
    }

    # Pull images first
    msg_info "Pulling Docker images (this may take a few minutes)..."
    docker compose pull || {
        msg_error "Failed to pull Docker images"
        msg_error "Check your internet connection and Docker installation"
        exit 1
    }

    # Start services
    docker compose up -d || {
        msg_error "Failed to start Docker stack"
        msg_error "Check logs with: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs"
        exit 1
    }

    msg_ok "Stack started successfully"
}

# Display installation status and next steps
function show_status() {
    echo ""
    echo "=========================================="
    echo "LedFX AirPlay Installation Complete!"
    echo "=========================================="
    echo ""

    if [[ "${DRY_RUN}" == true ]]; then
        msg_info "DRY RUN MODE - No changes were made"
        return 0
    fi

    echo "Services:"
    docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps
    echo ""
    echo "Access LedFX web UI: http://localhost:8888"
    echo ""
    echo "AirPlay device name: LEDFx AirPlay"
    echo "(Should appear in your device's AirPlay menu)"
    echo ""
    echo "Useful commands:"
    echo "  View logs:    docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
    echo "  Restart:      docker compose -f ${INSTALL_DIR}/docker-compose.yml restart"
    echo "  Stop:         docker compose -f ${INSTALL_DIR}/docker-compose.yml down"
    echo "  Update:       docker compose -f ${INSTALL_DIR}/docker-compose.yml pull && docker compose -f ${INSTALL_DIR}/docker-compose.yml up -d"
    echo ""
    echo "Troubleshooting:"
    echo "  If AirPlay device doesn't appear, check that port 5353/UDP is not blocked"
    echo "  If no audio, verify PulseAudio: docker exec ledfx pactl list sources short"
    echo ""
}

# Parse command line arguments
function parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            *)
                msg_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Main installation flow
function main() {
    parse_args "$@"

    if [[ "${DRY_RUN}" == true ]]; then
        msg_info "Running in DRY RUN mode - no changes will be made"
        echo ""
    fi

    check_root
    detect_distro
    install_docker
    setup_directory
    copy_configs
    start_stack
    show_status
}

# Run main function with all arguments
main "$@"
