#!/usr/bin/env bash
# Airglow Diagnostic Tool
# Checks the entire audio flow: AirPlay → Avahi → Shairport-Sync → NQPTP → PulseAudio → LedFx
# Usage:
#   ./diagnose-airglow.sh                    # Run on localhost
#   ./diagnose-airglow.sh 192.168.2.122      # Run on remote host via SSH
#   ./diagnose-airglow.sh airglow.office.lab # Run on remote host via SSH
# Requirements: jq (for JSON parsing)
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed."
    echo "Install with: apt-get install jq (Debian/Ubuntu) or brew install jq (macOS)"
    exit 1
fi

# Source common functions
source "${SCRIPT_DIR}/diagnostics/diagnose-common.sh"

# Initialize diagnostic environment
diagnose_init "$@"

echo "═══════════════════════════════════════════════════════════════"
echo "  Airglow Diagnostic Tool"
echo "  Checking audio flow: AirPlay → Avahi → Shairport-Sync → NQPTP → PulseAudio → LedFx"
echo "═══════════════════════════════════════════════════════════════"
echo

# Run component diagnostic scripts in dependency order
source "${SCRIPT_DIR}/diagnose-shairport.sh"
source "${SCRIPT_DIR}/diagnose-avahi.sh"
source "${SCRIPT_DIR}/diagnose-nqptp.sh"
source "${SCRIPT_DIR}/diagnose-pulseaudio.sh"
source "${SCRIPT_DIR}/diagnose-ledfx.sh"

# ============================================================================
# SUMMARY
# ============================================================================
section "Summary"

echo "Audio Flow Status:"
echo "  [AirPlay] → [Avahi/mDNS] → [Shairport-Sync] → [NQPTP] → [PulseAudio] → [LedFx] → [LEDs]"
echo
echo "Next steps if issues found:"
if [ "$REMOTE" = true ]; then
    echo "  1. Check Avahi logs: ssh root@${TARGET_HOST} 'docker logs avahi'"
    echo "  2. Check NQPTP logs: ssh root@${TARGET_HOST} 'docker logs nqptp'"
    echo "  3. Check Shairport-Sync logs: ssh root@${TARGET_HOST} 'docker logs shairport-sync'"
    echo "  4. Check LedFx logs: ssh root@${TARGET_HOST} 'docker logs ledfx'"
    echo "  5. Check hook logs: ssh root@${TARGET_HOST} 'docker exec shairport-sync cat /var/log/shairport-sync/ledfx-session-hook.log'"
else
    echo "  1. Check Avahi logs: docker logs avahi"
    echo "  2. Check NQPTP logs: docker logs nqptp"
    echo "  3. Check Shairport-Sync logs: docker logs shairport-sync"
    echo "  4. Check LedFx logs: docker logs ledfx"
    echo "  5. Check hook logs: docker exec shairport-sync cat /var/log/shairport-sync/ledfx-session-hook.log"
fi
echo "  6. Verify AirPlay connection from your device"
echo

