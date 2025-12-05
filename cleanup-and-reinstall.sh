#!/usr/bin/env bash
# Cleanup and reinstall script for Airglow
# This completely removes all containers, networks, and volumes, then reinstalls

set -e

INSTALL_DIR="/opt/airglow"
BRANCH="${BRANCH:-bridge-networking}"

echo "=== Airglow Cleanup and Reinstall ==="
echo ""

# Step 1: Stop and remove all containers
if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
    echo "Stopping containers..."
    cd "${INSTALL_DIR}"
    docker compose down -v 2>/dev/null || true
    echo "✓ Containers stopped and removed"
else
    echo "No docker-compose.yml found, skipping container cleanup"
fi

# Step 2: Remove any orphaned containers
echo "Removing orphaned containers..."
docker ps -a --filter "name=airglow\|avahi\|shairport-sync\|ledfx\|nqptp" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
echo "✓ Orphaned containers removed"

# Step 3: Remove network
echo "Removing network..."
docker network rm airglow-network 2>/dev/null || true
echo "✓ Network removed"

# Step 4: Remove images (optional - uncomment if you want to force rebuild)
# echo "Removing images..."
# docker images --filter "reference=*airglow*" --format "{{.ID}}" | xargs -r docker rmi -f 2>/dev/null || true
# docker images --filter "reference=*shairport-sync*" --format "{{.ID}}" | xargs -r docker rmi -f 2>/dev/null || true
# echo "✓ Images removed"

# Step 5: Clean up installation directory (preserve backups)
echo "Cleaning up installation directory..."
if [[ -d "${INSTALL_DIR}" ]]; then
    # Remove everything except backups
    find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 ! -name "*.backup.*" -exec rm -rf {} \; 2>/dev/null || true
    echo "✓ Installation directory cleaned (backups preserved)"
else
    echo "Installation directory doesn't exist, creating it..."
    mkdir -p "${INSTALL_DIR}"
fi

# Step 6: Reinstall
echo ""
echo "=== Reinstalling Airglow ==="
echo ""
curl -fsSL "https://raw.githubusercontent.com/RoyalPineapple/airglow/${BRANCH}/install.sh" | bash -s -- --branch "${BRANCH}"

echo ""
echo "=== Cleanup and Reinstall Complete ==="

