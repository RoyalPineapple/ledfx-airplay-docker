#!/usr/bin/env bash
# Airglow Installer
# Installs Docker (if needed) and starts the AirPlay ➜ LedFX stack

set -Eeuo pipefail

# Script version
VERSION="1.0.0"

# Configuration
INSTALL_DIR="/opt/airglow"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
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
Airglow Installer v${VERSION}

Usage: $(basename "$0") [OPTIONS]

Options:
    -h, --help          Show this help message
    -v, --version       Show version information
    -n, --dry-run       Show what would be done without making changes
    -d, --dir DIR       Set installation directory (default: /opt/airglow)

Description:
    Installs Docker (if needed) and deploys the Airglow
    AirPlay ➜ LedFX visualization stack.

Requirements:
    - Debian/Ubuntu Linux system
    - Root privileges (run with sudo)
    - Internet connection

EOF
}

# Display version information
function show_version() {
    echo "Airglow Installer v${VERSION}"
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
    msg_ok "Detected ${NAME} ${VERSION_ID:-unknown}"
}

# Install Docker using official installation script
function install_docker() {
    if command -v docker &>/dev/null; then
        local docker_version
        docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        msg_ok "Docker already installed (version ${docker_version})"
        return 0
    fi

    msg_info "Installing Docker using official installation script..."

    if [[ "${DRY_RUN}" == true ]]; then
        msg_info "[DRY RUN] Would run: curl -fsSL https://get.docker.com | sh"
        return 0
    fi

    # Use Docker's official convenience script
    curl -fsSL https://get.docker.com | sh || {
        msg_error "Failed to install Docker"
        msg_error "Check your internet connection and try again"
        msg_error "Manual installation: https://docs.docker.com/engine/install/"
        exit 1
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

# Copy or download configuration files to installation directory
function copy_configs() {
    msg_info "Deploying configuration files..."

    if [[ "${DRY_RUN}" == true ]]; then
        msg_info "[DRY RUN] Would copy docker-compose.yml and configs to ${INSTALL_DIR}"
        return 0
    fi

    local repo_url="https://raw.githubusercontent.com/RoyalPineapple/airglow/master"
    
    # Try local files first, fallback to downloading from GitHub
    if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        msg_info "Using local configuration files..."
        cp "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/" || {
            msg_error "Failed to copy docker-compose.yml"
            exit 1
        }
        
        # Copy Dockerfiles needed for building images
        if [[ -f "${SCRIPT_DIR}/Dockerfile.web" ]]; then
            cp "${SCRIPT_DIR}/Dockerfile.web" "${INSTALL_DIR}/" || {
                msg_error "Failed to copy Dockerfile.web"
                exit 1
            }
        fi
        
        if [[ -f "${SCRIPT_DIR}/Dockerfile.shairport-sync" ]]; then
            cp "${SCRIPT_DIR}/Dockerfile.shairport-sync" "${INSTALL_DIR}/" || {
                msg_error "Failed to copy Dockerfile.shairport-sync"
                exit 1
            }
        fi
        
        # Copy web application directory
        if [[ -d "${SCRIPT_DIR}/web" ]]; then
            cp -r "${SCRIPT_DIR}/web" "${INSTALL_DIR}/" || {
                msg_error "Failed to copy web directory"
                exit 1
            }
        fi
        
        # Copy scripts directory
        if [[ -d "${SCRIPT_DIR}/scripts" ]]; then
            cp -r "${SCRIPT_DIR}/scripts" "${INSTALL_DIR}/" || {
                msg_error "Failed to copy scripts directory"
                exit 1
            }
        fi
        
        # Copy .dockerignore if it exists
        if [[ -f "${SCRIPT_DIR}/.dockerignore" ]]; then
            cp "${SCRIPT_DIR}/.dockerignore" "${INSTALL_DIR}/" || {
                msg_warn "Failed to copy .dockerignore (non-fatal)"
            }
        fi
        
        if [[ -d "${SCRIPT_DIR}/configs" ]]; then
            # Copy config files, but exclude ledfx-hooks.yaml (created on first config save)
            mkdir -p "${INSTALL_DIR}/configs"
            for config_file in "${SCRIPT_DIR}/configs"/*; do
                if [[ -f "${config_file}" ]] && [[ "$(basename "${config_file}")" != "ledfx-hooks.yaml" ]]; then
                    cp "${config_file}" "${INSTALL_DIR}/configs/" || {
                        msg_error "Failed to copy $(basename "${config_file}")"
                        exit 1
                    }
                fi
            done
        fi
    else
        msg_info "Downloading configuration files from GitHub..."
        
        curl -fsSL "${repo_url}/docker-compose.yml" -o "${INSTALL_DIR}/docker-compose.yml" || {
            msg_error "Failed to download docker-compose.yml"
            exit 1
        }
        
        # Download Dockerfiles
        curl -fsSL "${repo_url}/Dockerfile.web" -o "${INSTALL_DIR}/Dockerfile.web" || {
            msg_error "Failed to download Dockerfile.web"
            exit 1
        }
        
        curl -fsSL "${repo_url}/Dockerfile.shairport-sync" -o "${INSTALL_DIR}/Dockerfile.shairport-sync" || {
            msg_error "Failed to download Dockerfile.shairport-sync"
            exit 1
        }
        
        # Download web directory (need to download files individually or use git)
        msg_info "Note: For full installation from GitHub, consider cloning the repository:"
        msg_info "  git clone https://github.com/RoyalPineapple/airglow.git ${INSTALL_DIR}"
        msg_info "  Then run this installer from that directory"
        
        curl -fsSL "${repo_url}/configs/shairport-sync.conf" -o "${INSTALL_DIR}/configs/shairport-sync.conf" || {
            msg_error "Failed to download shairport-sync.conf"
            exit 1
        }
        
        curl -fsSL "${repo_url}/env.example" -o "${INSTALL_DIR}/.env" || {
            msg_warn "Failed to download .env example"
        }
    fi

    msg_ok "Configuration files deployed"
    
    # Initialize git repository for future updates (only if installing from a git repo)
    # This allows seamless updates via update-airglow.sh script
    if [[ "${DRY_RUN}" == false ]] && [[ -d "${INSTALL_DIR}" ]]; then
        # Only initialize git if we're installing from a local git repository
        # (indicates this is a managed deployment, not a standalone download)
        if [[ -d "${SCRIPT_DIR}/.git" ]] && command -v git &>/dev/null; then
            msg_info "Initializing git repository for future updates..."
            cd "${INSTALL_DIR}" || exit 1
            if ! git rev-parse --git-dir >/dev/null 2>&1; then
                git init -q
                # Use the same remote as the source repository
                local source_remote=$(cd "${SCRIPT_DIR}" && git remote get-url origin 2>/dev/null || echo "https://github.com/RoyalPineapple/airglow.git")
                git remote add origin "${source_remote}" 2>/dev/null || true
                git fetch origin -q 2>/dev/null || true
                # Add all files and create initial commit
                git add -A
                git commit -m "Initial installation" -q 2>/dev/null || true
                # Try to checkout the branch we're installing from (if available)
                local current_branch=$(cd "${SCRIPT_DIR}" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "master")
                if git ls-remote --heads origin "${current_branch}" 2>/dev/null | grep -q "${current_branch}"; then
                    git checkout -b "${current_branch}" "origin/${current_branch}" 2>/dev/null || true
                fi
                msg_ok "Git repository initialized"
            fi
        fi
    fi
}

# Start the Docker Compose stack
function start_stack() {
    msg_info "Starting Airglow stack..."

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
    echo "Airglow Installation Complete!"
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
    echo "AirPlay device name: Airglow"
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
