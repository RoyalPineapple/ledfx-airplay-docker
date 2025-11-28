#!/usr/bin/env bash
# Airglow Installer
# Installs Docker (if needed) and starts the AirPlay ➜ LedFX stack

set -Eeuo pipefail

# Script version
VERSION="1.0.0"

# Configuration
INSTALL_DIR="/opt/airglow"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_URL="https://github.com/RoyalPineapple/airglow.git"
REPO_RAW_URL="https://raw.githubusercontent.com/RoyalPineapple/airglow/master"
DRY_RUN=false
WITH_ALAC=false

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
    --with-alac         Build shairport-sync from source with Apple ALAC decoder
                        (adds 5-10 minutes to installation, allows use of Apple Lossless)

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
    mkdir -p "${INSTALL_DIR}/ledfx-data"

    # Set ownership for Pulse and LedFX data directories (LedFX runs as UID 1000)
    chown -R 1000:1000 "${INSTALL_DIR}/pulse" || {
        msg_warn "Failed to set ownership on pulse directory"
        msg_warn "You may need to manually run: sudo chown -R 1000:1000 ${INSTALL_DIR}/pulse"
    }
    chown -R 1000:1000 "${INSTALL_DIR}/pulse" || {
        msg_warn "Failed to set ownership on pulse directory"
        msg_warn "You may need to manually run: sudo chown -R 1000:1000 ${INSTALL_DIR}/pulse"
    }
    chown -R 1000:1000 "${INSTALL_DIR}/ledfx-data" || {
        msg_warn "Failed to set ownership on ledfx-data directory"
        msg_warn "You may need to manually run: sudo chown -R 1000:1000 ${INSTALL_DIR}/ledfx-data"
    }

    # Copy default LedFX config file only if it doesn't exist (idempotent)
    local ledfx_config="${INSTALL_DIR}/ledfx-data/config.json"
    local default_config="${SCRIPT_DIR}/configs/ledfx-config.json"
    if [[ ! -f "${ledfx_config}" ]] && [[ -f "${default_config}" ]]; then
        msg_info "Copying default LedFX config file with pulse audio device..."
        cp "${default_config}" "${ledfx_config}" || {
            msg_warn "Failed to copy LedFX config file"
        }
        chown 1000:1000 "${ledfx_config}" || {
            msg_warn "Failed to set ownership on LedFX config file"
        }
        msg_ok "LedFX config file created with pulse audio device"
    fi

    msg_ok "Directory structure created"
}

# Copy or download configuration files to installation directory
function copy_configs() {
    msg_info "Deploying configuration files..."

    if [[ "${DRY_RUN}" == true ]]; then
        msg_info "[DRY RUN] Would copy docker-compose.yml and configs to ${INSTALL_DIR}"
        return 0
    fi

    local repo_git_url="https://github.com/RoyalPineapple/airglow.git"
    
    # Try local files first, fallback to cloning from GitHub
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
            # Copy config files, but exclude ledfx-hooks.yaml (created on first config save) and ledfx-config.json (used for ledfx-data)
            mkdir -p "${INSTALL_DIR}/configs"
            for config_file in "${SCRIPT_DIR}/configs"/*; do
                local basename_file="$(basename "${config_file}")"
                if [[ -f "${config_file}" ]] && [[ "${basename_file}" != "ledfx-hooks.yaml" ]] && [[ "${basename_file}" != "ledfx-config.json" ]]; then
                    cp "${config_file}" "${INSTALL_DIR}/configs/" || {
                        msg_error "Failed to copy ${basename_file}"
                        exit 1
                    }
                fi
            done
        fi
    else
        msg_info "Cloning repository from GitHub..."
        
        # Check if git is available
        if ! command -v git &>/dev/null; then
            msg_info "Git not found, installing git..."
            if command -v apt-get &>/dev/null; then
                apt-get update -qq >/dev/null 2>&1
                apt-get install -y -qq git >/dev/null 2>&1 || {
                    msg_error "Failed to install git"
                    exit 1
                }
            else
                msg_error "Git is required for installation from GitHub. Please install git first."
                exit 1
            fi
        fi
        
        # Clone the repository to a temporary directory
        local temp_repo_dir="${INSTALL_DIR}.tmp"
        rm -rf "${temp_repo_dir}"
        
        msg_info "Cloning AirGlow repository..."
        # Use BRANCH environment variable if set, otherwise default to master
        local branch="${BRANCH:-master}"
        
        git clone --depth 1 --branch "${branch}" "${repo_git_url}" "${temp_repo_dir}" || {
            # Fallback to master if branch doesn't exist
            if [[ "${branch}" != "master" ]]; then
                msg_warn "Branch ${branch} not found, falling back to master"
                git clone --depth 1 --branch master "${repo_git_url}" "${temp_repo_dir}" || {
                    msg_error "Failed to clone repository"
                    exit 1
                }
            else
                msg_error "Failed to clone repository"
                exit 1
            fi
        }
        
        # Copy necessary files from cloned repo
        msg_info "Copying files from repository..."
        
        # Copy docker-compose.yml
        if [[ -f "${temp_repo_dir}/docker-compose.yml" ]]; then
            cp "${temp_repo_dir}/docker-compose.yml" "${INSTALL_DIR}/" || {
                msg_error "Failed to copy docker-compose.yml"
                exit 1
            }
        fi
        
        # Copy Dockerfiles
        if [[ -f "${temp_repo_dir}/Dockerfile.web" ]]; then
            cp "${temp_repo_dir}/Dockerfile.web" "${INSTALL_DIR}/" || {
                msg_error "Failed to copy Dockerfile.web"
                exit 1
            }
        fi
        
        if [[ -f "${temp_repo_dir}/Dockerfile.shairport-sync" ]]; then
            cp "${temp_repo_dir}/Dockerfile.shairport-sync" "${INSTALL_DIR}/" || {
                msg_error "Failed to copy Dockerfile.shairport-sync"
                exit 1
            }
        fi
        
        # Copy web directory
        if [[ -d "${temp_repo_dir}/web" ]]; then
            cp -r "${temp_repo_dir}/web" "${INSTALL_DIR}/" || {
                msg_error "Failed to copy web directory"
                exit 1
            }
        fi
        
        # Copy scripts directory
        if [[ -d "${temp_repo_dir}/scripts" ]]; then
            cp -r "${temp_repo_dir}/scripts" "${INSTALL_DIR}/" || {
                msg_error "Failed to copy scripts directory"
                exit 1
            }
        fi
        
        # Copy .dockerignore if it exists
        if [[ -f "${temp_repo_dir}/.dockerignore" ]]; then
            cp "${temp_repo_dir}/.dockerignore" "${INSTALL_DIR}/" || {
                msg_warn "Failed to copy .dockerignore (non-fatal)"
            }
        fi
        
        # Copy configs directory (excluding ledfx-hooks.yaml and ledfx-config.json)
        if [[ -d "${temp_repo_dir}/configs" ]]; then
            mkdir -p "${INSTALL_DIR}/configs"
            for config_file in "${temp_repo_dir}/configs"/*; do
                local basename_file="$(basename "${config_file}")"
                if [[ -f "${config_file}" ]] && [[ "${basename_file}" != "ledfx-hooks.yaml" ]] && [[ "${basename_file}" != "ledfx-config.json" ]]; then
                    cp "${config_file}" "${INSTALL_DIR}/configs/" || {
                        msg_error "Failed to copy ${basename_file}"
                        exit 1
                    }
                fi
            done
        fi
        
        # Copy ledfx-config.json to INSTALL_DIR for later use (not to configs/)
        if [[ -f "${temp_repo_dir}/configs/ledfx-config.json" ]]; then
            cp "${temp_repo_dir}/configs/ledfx-config.json" "${INSTALL_DIR}/" || {
                msg_warn "Failed to copy ledfx-config.json (non-fatal)"
            }
        fi
        
        # Clean up temporary directory
        rm -rf "${temp_repo_dir}"
        
        msg_ok "Repository cloned and files copied"
    fi

    msg_ok "Configuration files deployed"
    
    # Configure ALAC support if requested
    configure_alac_support
    
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

# Configure ALAC support based on user preference
function configure_alac_support() {
    if [[ "${DRY_RUN}" == true ]]; then
        if [[ "${WITH_ALAC}" == true ]]; then
            msg_info "[DRY RUN] Would configure for Apple ALAC decoder support (build from source)"
        else
            msg_info "[DRY RUN] Would configure to use pre-built shairport-sync image (quick install)"
        fi
        return 0
    fi

    local dockerfile="${INSTALL_DIR}/Dockerfile.shairport-sync"

    if [[ "${WITH_ALAC}" == true ]]; then
        msg_info "Configuring for Apple ALAC decoder support (building from source)..."
        
        # Verify Dockerfile exists
        if [[ ! -f "${dockerfile}" ]]; then
            msg_error "Dockerfile.shairport-sync not found!"
            msg_error "Expected full build Dockerfile for ALAC support"
            exit 1
        fi
        
        # Verify it's the ALAC build version (not the minimal one)
        if grep -q "FROM mikebrady/shairport-sync:latest" "${dockerfile}"; then
            msg_warn "Dockerfile appears to be minimal version, not ALAC build version"
            msg_warn "Replacing with ALAC build Dockerfile..."
            
            # Create the ALAC build Dockerfile (embedded in script for one-shot install)
            cat > "${dockerfile}" << 'DOCKERFILE_EOF'
# Shairport-Sync with Apple ALAC decoder support
# Built from source with --with-apple-alac flag
FROM alpine:latest

# Version pins for reproducibility
ARG SHAIRPORT_SYNC_VERSION=4.3.7
ARG ALAC_VERSION=master

# Install build dependencies
RUN apk add --no-cache \
    # Build tools (build-base includes gcc, g++, make, libc-dev, etc.)
    build-base \
    autoconf \
    automake \
    libtool \
    git \
    pkgconfig \
    musl-dev \
    linux-headers \
    # Development headers
    pulseaudio-dev \
    avahi-dev \
    openssl-dev \
    libconfig-dev \
    soxr-dev \
    dbus-dev \
    popt-dev \
    # Runtime dependencies (will be needed later)
    pulseaudio \
    avahi \
    avahi-libs \
    openssl \
    libconfig \
    soxr \
    dbus \
    popt \
    # Utilities for hook scripts
    jq \
    yq

# Build ALAC library
WORKDIR /tmp
RUN git clone --depth 1 https://github.com/mikebrady/alac.git && \
    cd alac && \
    autoreconf -fi && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    (ldconfig 2>/dev/null || true) && \
    cd .. && \
    rm -rf alac

# Build shairport-sync with Apple ALAC support
RUN (git clone --depth 1 --branch ${SHAIRPORT_SYNC_VERSION} https://github.com/mikebrady/shairport-sync.git || \
     git clone --depth 1 https://github.com/mikebrady/shairport-sync.git) && \
    cd shairport-sync && \
    autoreconf -fi && \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH ./configure \
        --with-apple-alac \
        --with-pa \
        --with-avahi \
        --with-ssl=openssl \
        --with-soxr \
        --with-metadata \
        --sysconfdir=/etc \
        --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    (ldconfig 2>/dev/null || true) && \
    cd .. && \
    rm -rf shairport-sync

# Clean up build dependencies to reduce image size
RUN apk del \
    build-base \
    autoconf \
    automake \
    libtool \
    git \
    pkgconfig \
    musl-dev \
    linux-headers \
    pulseaudio-dev \
    avahi-dev \
    openssl-dev \
    libconfig-dev \
    soxr-dev \
    dbus-dev \
    popt-dev

# Create directory for configuration and logs
RUN mkdir -p /etc /var/log/shairport-sync /var/run/dbus

# Verify installation
RUN test -f /usr/local/bin/shairport-sync && shairport-sync -V || (echo "ERROR: shairport-sync binary not found or not executable" && exit 1)

# Create startup script to run avahi-daemon and shairport-sync
RUN echo '#!/bin/sh' > /usr/local/bin/start.sh && \
    echo 'dbus-daemon --system --nofork --nopidfile &' >> /usr/local/bin/start.sh && \
    echo 'sleep 1' >> /usr/local/bin/start.sh && \
    echo 'avahi-daemon -D' >> /usr/local/bin/start.sh && \
    echo 'sleep 1' >> /usr/local/bin/start.sh && \
    echo 'exec shairport-sync "$@"' >> /usr/local/bin/start.sh && \
    chmod +x /usr/local/bin/start.sh

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/start.sh"]
DOCKERFILE_EOF
            msg_ok "Created ALAC build Dockerfile"
        else
            # Verify it has ALAC build indicators
            if ! grep -qE "(--with-apple-alac|alac\.git|ALACDecoder)" "${dockerfile}"; then
                msg_warn "Dockerfile may not be configured for ALAC build"
                msg_warn "Checking for ALAC build indicators..."
            else
                msg_ok "Dockerfile verified as ALAC build version"
            fi
        fi
        
        # No config change needed - Apple ALAC decoder is the default when built with --with-apple-alac
        msg_ok "Apple ALAC decoder will be used (default when built with --with-apple-alac)"
    else
        msg_info "Using pre-built shairport-sync image (quick install, no ALAC decoder)..."
        
        # Replace Dockerfile with simple version that just extends base image
        if [[ -f "${dockerfile}" ]]; then
            cat > "${dockerfile}" << 'EOF'
# Custom Shairport-Sync image with jq for JSON parsing and yq for YAML parsing
FROM mikebrady/shairport-sync:latest

# Install jq for JSON parsing and yq for YAML parsing in hook scripts
RUN apk add --no-cache jq yq
EOF
            msg_ok "Created minimal Dockerfile (extends pre-built image)"
        else
            msg_warn "Dockerfile.shairport-sync not found, will be created during build"
        fi

        # No config change needed - pre-built image uses default Hammerton decoder
        msg_ok "Using default decoder (Hammerton) from pre-built image"
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

    # Pull pre-built images (non-fatal for build-based services)
    msg_info "Pulling pre-built Docker images..."
    docker compose pull 2>/dev/null || {
        msg_info "Some services need to be built from source (this is expected)"
    }

    # Build and start services
    if [[ "${WITH_ALAC}" == true ]]; then
        msg_info "Building and starting services..."
        msg_info "Note: Building shairport-sync from source with ALAC support may take 5-10 minutes..."
        msg_info "This is a one-time build - subsequent starts will be much faster."
        
        # Verify Dockerfile exists before building
        if [[ ! -f "${INSTALL_DIR}/Dockerfile.shairport-sync" ]]; then
            msg_error "Dockerfile.shairport-sync not found! Cannot build with ALAC support."
            exit 1
        fi
        
        # Verify Dockerfile is the ALAC version
        if grep -q "FROM mikebrady/shairport-sync:latest" "${INSTALL_DIR}/Dockerfile.shairport-sync"; then
            msg_error "Dockerfile is minimal version, not ALAC build version!"
            msg_error "ALAC support requires building from source. Please re-run with --with-alac flag."
            exit 1
        fi
        
        docker compose up -d --build || {
            msg_error "Failed to start Docker stack"
            msg_error "Check logs with: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs"
            exit 1
        }
        
        # Verify build succeeded by checking shairport-sync version
        msg_info "Verifying ALAC support in built image..."
        sleep 5
        if docker compose exec -T shairport-sync shairport-sync -V 2>&1 | grep -q "alac"; then
            msg_ok "ALAC support verified in shairport-sync build"
        else
            msg_warn "Could not verify ALAC support - container may still be starting"
            msg_warn "Check version manually: docker exec shairport-sync shairport-sync -V"
        fi
    else
        msg_info "Starting services..."
        docker compose up -d || {
            msg_error "Failed to start Docker stack"
            msg_error "Check logs with: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs"
            exit 1
        }
    fi

    msg_ok "Stack started successfully"
    
    # Wait for LedFX to be ready and set audio device via API
    configure_ledfx_audio_device
}

# Configure LedFX audio device via API
function configure_ledfx_audio_device() {
    msg_info "Waiting for LedFX API to be ready..."
    
    local max_attempts=30
    local attempt=0
    local ledfx_ready=false
    
    # Wait for LedFX API to respond
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -f "http://localhost:8888/api/info" >/dev/null 2>&1; then
            ledfx_ready=true
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    if [[ "${ledfx_ready}" == false ]]; then
        msg_warn "LedFX API did not become ready in time"
        msg_warn "You may need to manually set the audio device to 'pulse' (index 0) in the LedFX UI"
        return 1
    fi
    
    msg_info "Setting LedFX audio device to pulse (index 0) via API..."
    
    # Set audio device via API
    local response=$(curl -s -X PUT "http://localhost:8888/api/config" \
        -H "Content-Type: application/json" \
        -d '{"audio": {"audio_device": 0}}' 2>&1)
    
    if echo "${response}" | grep -q '"status": "success"'; then
        msg_ok "LedFX audio device set to pulse (index 0)"
        
        # Verify the change
        sleep 2
        local active_device=$(curl -s "http://localhost:8888/api/audio/devices" | \
            python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('active_device_index', 'unknown'))" 2>/dev/null || echo "unknown")
        
        if [[ "${active_device}" == "0" ]]; then
            msg_ok "Verified: LedFX is using pulse audio device"
        else
            msg_warn "LedFX config updated, but active device is still index ${active_device}"
            msg_warn "LedFX may need a restart to apply the change"
        fi
    else
        msg_warn "Failed to set audio device via API: ${response}"
        msg_warn "You may need to manually set the audio device to 'pulse' (index 0) in the LedFX UI"
        return 1
    fi
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
            --with-alac)
                WITH_ALAC=true
                shift
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
