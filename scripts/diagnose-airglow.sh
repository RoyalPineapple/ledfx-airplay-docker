#!/usr/bin/env bash
# Airglow Diagnostic Tool
# Checks the entire audio flow: AirPlay → Shairport-Sync → PulseAudio → LedFx
# Usage:
#   ./diagnose-airglow.sh                    # Run on localhost
#   ./diagnose-airglow.sh 192.168.2.122      # Run on remote host via SSH
#   ./diagnose-airglow.sh airglow.office.lab # Run on remote host via SSH
set -euo pipefail

# Parse arguments
TARGET_HOST="${1:-}"
LEDFX_HOST="${LEDFX_HOST:-localhost}"
LEDFX_PORT="${LEDFX_PORT:-8888}"

# If target host specified, use SSH; otherwise run locally
if [ -n "$TARGET_HOST" ]; then
    SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=5 root@${TARGET_HOST}"
    LEDFX_HOST="${TARGET_HOST}"
    REMOTE=true
else
    SSH_CMD=""
    REMOTE=false
fi

LEDFX_URL="http://${LEDFX_HOST}:${LEDFX_PORT}"

# Function to run commands (local or remote)
run_cmd() {
    if [ "$REMOTE" = true ]; then
        $SSH_CMD "$1"
    else
        eval "$1"
    fi
}

# Function to run docker commands
docker_cmd() {
    if [ "$REMOTE" = true ]; then
        $SSH_CMD "docker $*"
    else
        docker "$@"
    fi
}

echo "═══════════════════════════════════════════════════════════════"
echo "  Airglow Diagnostic Tool"
echo "  Checking audio flow: AirPlay → Shairport-Sync → PulseAudio → LedFx"
echo "═══════════════════════════════════════════════════════════════"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

section() {
    echo
    echo "─────────────────────────────────────────────────────────────"
    echo "  $1"
    echo "─────────────────────────────────────────────────────────────"
}

# ============================================================================
# 1. SHAIRPORT-SYNC (AirPlay Receiver)
# ============================================================================
section "1. Shairport-Sync (AirPlay Receiver)"

# Check if container is running
if docker_cmd ps --format '{{.Names}}' | grep -q '^shairport-sync$'; then
    check_ok "Container is running"
    
    # Check shairport-sync process
    if docker_cmd exec shairport-sync pgrep -f shairport-sync > /dev/null 2>&1; then
        check_ok "Shairport-Sync process is running"
    else
        check_fail "Shairport-Sync process not found"
    fi
    
    # Check configuration
    if docker_cmd exec shairport-sync test -f /etc/shairport-sync.conf; then
        check_ok "Configuration file exists"
        
        # Check device name
        DEVICE_NAME=$(docker_cmd exec shairport-sync shairport-sync --displayConfig 2>&1 | grep 'player name' | awk -F'"' '{print $2}' || echo "")
        if [ -n "$DEVICE_NAME" ]; then
            check_ok "Device name: $DEVICE_NAME"
        else
            check_warn "Could not determine device name"
        fi
        
        # Check session hooks
        if docker_cmd exec shairport-sync shairport-sync --displayConfig 2>&1 | grep -q 'run_this_before_entering_active_state'; then
            HOOK_PATH=$(docker_cmd exec shairport-sync shairport-sync --displayConfig 2>&1 | grep 'run_this_before_entering_active_state' | awk -F'"' '{print $2}' || echo "")
            if [ -n "$HOOK_PATH" ]; then
                if docker_cmd exec shairport-sync test -f "$HOOK_PATH"; then
                    check_ok "Session hook configured: $HOOK_PATH"
                else
                    check_fail "Session hook file not found: $HOOK_PATH"
                fi
            fi
        else
            check_warn "Session hooks not configured"
        fi
    else
        check_fail "Configuration file not found"
    fi
    
    # Check recent connections
    echo
    echo "  Recent AirPlay activity:"
    docker_cmd logs shairport-sync --since 5m 2>&1 | grep -E '(Connection|Playback|Active)' | tail -5 | while read line; do
        echo "    $line"
    done || echo "    No recent activity"
    
else
    check_fail "Container is not running"
fi

# ============================================================================
# 2. PULSEAUDIO (Audio Bridge)
# ============================================================================
section "2. PulseAudio (Audio Bridge)"

# Check if LedFx container is running (hosts PulseAudio)
if docker_cmd ps --format '{{.Names}}' | grep -q '^ledfx$'; then
    check_ok "LedFx container is running (hosts PulseAudio)"
    
    # Check PulseAudio server
    if docker_cmd exec ledfx pactl info 2>/dev/null | grep -q 'Server String'; then
        SERVER=$(docker_cmd exec ledfx pactl info 2>/dev/null | grep 'Server String' | awk '{print $3}')
        check_ok "PulseAudio server: $SERVER"
    else
        check_fail "PulseAudio server not responding"
    fi
    
    # Check sink-inputs (active audio streams)
    SINK_INPUTS=$(docker_cmd exec ledfx pactl list sink-inputs 2>/dev/null | grep -c 'Sink Input #' || echo "0")
    if [ "$SINK_INPUTS" -gt 0 ]; then
        check_ok "Active audio streams: $SINK_INPUTS"
        echo
        echo "  Sink Inputs:"
        docker_cmd exec ledfx pactl list sink-inputs 2>/dev/null | grep -E '(Sink Input|application.name|Corked)' | head -15 | while read line; do
            echo "    $line"
        done
    else
        check_warn "No active audio streams (no audio playing)"
    fi
    
    # Check if shairport-sync is connected
    if docker_cmd exec ledfx pactl list sink-inputs 2>/dev/null | grep -q 'Shairport Sync'; then
        check_ok "Shairport-Sync connected to PulseAudio"
    else
        check_warn "Shairport-Sync not connected to PulseAudio (no active stream)"
    fi
    
    # Check PulseAudio sinks
    echo
    echo "  Audio Sinks:"
    docker_cmd exec ledfx pactl list sinks 2>/dev/null | grep -E '(Sink #|Name:|State:)' | head -9 | while read line; do
        echo "    $line"
    done || check_warn "Could not list sinks"
    
else
    check_fail "LedFx container is not running"
fi

# ============================================================================
# 3. LEDFX (Visualization Engine)
# ============================================================================
section "3. LedFx (Visualization Engine)"

# Check if container is running
if docker_cmd ps --format '{{.Names}}' | grep -q '^ledfx$'; then
    check_ok "Container is running"
    
    # Check API accessibility
    if curl -s -f "${LEDFX_URL}/api/info" > /dev/null 2>&1; then
        INFO=$(curl -s "${LEDFX_URL}/api/info")
        VERSION=$(echo "$INFO" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        check_ok "API accessible (version: $VERSION)"
    else
        check_fail "API not accessible at ${LEDFX_URL}"
        exit 1
    fi
    
    # Check global paused state
    PAUSED=$(curl -s "${LEDFX_URL}/api/virtuals" | grep -o '"paused":[^,]*' | cut -d':' -f2 | tr -d ' }' || echo "unknown")
    if [ "$PAUSED" = "false" ]; then
        check_ok "Global paused state: false (effects are playing)"
    elif [ "$PAUSED" = "true" ]; then
        check_warn "Global paused state: true (effects are paused)"
    else
        check_warn "Could not determine paused state"
    fi
    
    # Check virtuals
    echo
    echo "  Virtuals:"
    VIRTUAL_DATA=$(curl -s "${LEDFX_URL}/api/virtuals")
    if echo "$VIRTUAL_DATA" | grep -q '"virtuals"'; then
        VIRTUAL_COUNT=$(echo "$VIRTUAL_DATA" | grep -o '"[^"]*":\s*{' | grep -v 'status\|virtuals' | wc -l | tr -d ' ')
        check_ok "Found $VIRTUAL_COUNT virtual(s)"
        
        # Check each virtual
        echo "$VIRTUAL_DATA" | grep -o '"[^"]*":\s*{' | grep -v 'status\|virtuals' | sed 's/":.*//' | sed 's/"//g' | while read vid; do
            if [ -n "$vid" ]; then
                VIRTUAL_STATE=$(curl -s "${LEDFX_URL}/api/virtuals/${vid}")
                ACTIVE=$(echo "$VIRTUAL_STATE" | grep -o '"active":[^,]*' | cut -d':' -f2 | tr -d ' ' || echo "unknown")
                STREAMING=$(echo "$VIRTUAL_STATE" | grep -o '"streaming":[^,]*' | cut -d':' -f2 | tr -d ' }' || echo "unknown")
                EFFECT=$(echo "$VIRTUAL_STATE" | grep -o '"type":"[^"]*"' | cut -d'"' -f4 || echo "none")
                
                echo
                echo "    Virtual: $vid"
                if [ "$ACTIVE" = "true" ]; then
                    check_ok "      Active: true"
                else
                    check_warn "      Active: false"
                fi
                
                if [ "$STREAMING" = "true" ]; then
                    check_ok "      Streaming: true (receiving audio)"
                else
                    check_warn "      Streaming: false (no audio input)"
                fi
                
                if [ "$EFFECT" != "none" ] && [ -n "$EFFECT" ]; then
                    check_ok "      Effect: $EFFECT"
                else
                    check_warn "      Effect: none (no effect loaded)"
                fi
            fi
        done
    else
        check_fail "Could not retrieve virtuals"
    fi
    
    # Check devices
    echo
    echo "  Devices:"
    DEVICE_DATA=$(curl -s "${LEDFX_URL}/api/devices")
    if echo "$DEVICE_DATA" | grep -q '"devices"'; then
        DEVICE_COUNT=$(echo "$DEVICE_DATA" | grep -o '"[^"]*":\s*{' | grep -v 'status\|devices' | wc -l | tr -d ' ')
        check_ok "Found $DEVICE_COUNT device(s)"
        
        echo "$DEVICE_DATA" | grep -o '"[^"]*":\s*{' | grep -v 'status\|devices' | sed 's/":.*//' | sed 's/"//g' | while read did; do
            if [ -n "$did" ]; then
                ONLINE=$(echo "$DEVICE_DATA" | grep -A5 "\"$did\"" | grep '"online"' | grep -o 'true\|false' || echo "unknown")
                if [ "$ONLINE" = "true" ]; then
                    check_ok "      $did: online"
                else
                    check_warn "      $did: offline"
                fi
            fi
        done
    else
        check_warn "Could not retrieve devices"
    fi
    
else
    check_fail "Container is not running"
fi

# ============================================================================
# SUMMARY
# ============================================================================
section "Summary"

echo "Audio Flow Status:"
echo "  [AirPlay] → [Shairport-Sync] → [PulseAudio] → [LedFx] → [LEDs]"
echo
echo "Next steps if issues found:"
if [ "$REMOTE" = true ]; then
    echo "  1. Check Shairport-Sync logs: ssh root@${TARGET_HOST} 'docker logs shairport-sync'"
    echo "  2. Check LedFx logs: ssh root@${TARGET_HOST} 'docker logs ledfx'"
    echo "  3. Check hook logs: ssh root@${TARGET_HOST} 'docker exec shairport-sync cat /var/log/shairport-sync/ledfx-session-hook.log'"
else
    echo "  1. Check Shairport-Sync logs: docker logs shairport-sync"
    echo "  2. Check LedFx logs: docker logs ledfx"
    echo "  3. Check hook logs: docker exec shairport-sync cat /var/log/shairport-sync/ledfx-session-hook.log"
fi
echo "  4. Verify AirPlay connection from your device"
echo

