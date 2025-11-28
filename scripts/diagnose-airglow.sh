#!/usr/bin/env bash
# Airglow Diagnostic Tool
# Checks the entire audio flow: AirPlay → Shairport-Sync → PulseAudio → LedFx
# Usage:
#   ./diagnose-airglow.sh                    # Run on localhost
#   ./diagnose-airglow.sh 192.168.2.122      # Run on remote host via SSH
#   ./diagnose-airglow.sh airglow.office.lab # Run on remote host via SSH
# Requirements: jq (for JSON parsing)
set -euo pipefail

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed."
    echo "Install with: apt-get install jq (Debian/Ubuntu) or brew install jq (macOS)"
    exit 1
fi

# Parse arguments
TARGET_HOST="${1:-}"
LEDFX_PORT="${LEDFX_PORT:-8888}"

# If target host specified and it's not "localhost", use SSH; otherwise run locally
if [ -n "$TARGET_HOST" ] && [ "$TARGET_HOST" != "localhost" ]; then
    SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=5 root@${TARGET_HOST}"
    # When checking remote host, API calls are made from local machine
    LEDFX_HOST="${TARGET_HOST}"
    REMOTE=true
else
    SSH_CMD=""
    # When running locally, API is at localhost
    LEDFX_HOST="${LEDFX_HOST:-localhost}"
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

# Plain text output functions
check_ok() {
    echo "[OK] $1"
}

check_fail() {
    echo "[ERROR] $1"
}

check_warn() {
    echo "[WARN] $1"
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
        # Format: "shairport.c:2133"    name = "Airglow";
        # Extract the value between quotes after "name ="
        DEVICE_NAME=$(docker_cmd exec shairport-sync shairport-sync --displayConfig 2>&1 | grep 'name =' | sed -n 's/.*name = "\([^"]*\)".*/\1/p' | head -1 || echo "")
        if [ -z "$DEVICE_NAME" ]; then
            # Try alternative format: player name = "..."
            DEVICE_NAME=$(docker_cmd exec shairport-sync shairport-sync --displayConfig 2>&1 | grep -i 'player name' | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1 || echo "")
        fi
        if [ -n "$DEVICE_NAME" ]; then
            check_ok "Device name: $DEVICE_NAME"
        else
            check_warn "Could not determine device name"
        fi
        
        # Check session hooks
        HOOK_LINE=$(docker_cmd exec shairport-sync shairport-sync --displayConfig 2>&1 | grep 'run_this_before_entering_active_state' | head -1 || echo "")
        if [ -n "$HOOK_LINE" ]; then
            # Extract just the script path (before any arguments)
            HOOK_PATH=$(echo "$HOOK_LINE" | sed -n 's/.*= "\([^"]*\)".*/\1/p' | awk '{print $1}' || echo "")
            if [ -n "$HOOK_PATH" ] && [ "$HOOK_PATH" != "shairport.c" ] && [ "${HOOK_PATH#/}" != "$HOOK_PATH" ]; then
                if docker_cmd exec shairport-sync test -f "$HOOK_PATH"; then
                    check_ok "Session hook configured: $HOOK_PATH"
                else
                    check_warn "Session hook file not found: $HOOK_PATH"
                fi
            else
                check_warn "Session hooks configured but path parsing failed"
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
    check_fail "LedFx pulse audio bridge is not accessible"
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
    PAUSED=$(curl -s "${LEDFX_URL}/api/virtuals" | jq -r '.paused' 2>/dev/null || echo "unknown")
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
    if echo "$VIRTUAL_DATA" | jq -e '.virtuals' >/dev/null 2>&1; then
        # Extract virtual IDs using jq
        VIRTUAL_IDS=$(echo "$VIRTUAL_DATA" | jq -r '.virtuals | keys[]' 2>/dev/null || echo "")
        VIRTUAL_COUNT=$(echo "$VIRTUAL_IDS" | grep -v '^$' | wc -l | tr -d ' ')
        check_ok "Found $VIRTUAL_COUNT virtual(s)"
        
        # Check each virtual
        echo "$VIRTUAL_IDS" | grep -v '^$' | while read vid; do
            if [ -n "$vid" ]; then
                VIRTUAL_STATE=$(curl -s "${LEDFX_URL}/api/virtuals/${vid}" 2>/dev/null || echo "{}")
                if echo "$VIRTUAL_STATE" | jq -e ".\"$vid\"" >/dev/null 2>&1; then
                    # Extract values using jq
                    ACTIVE=$(echo "$VIRTUAL_STATE" | jq -r ".\"$vid\".active // \"unknown\"")
                    STREAMING=$(echo "$VIRTUAL_STATE" | jq -r ".\"$vid\".streaming // \"unknown\"")
                    # Effect is nested: "effect": { "type": "rain", ... }
                    EFFECT=$(echo "$VIRTUAL_STATE" | jq -r ".\"$vid\".effect.type // .\"$vid\".last_effect // \"none\"")
                    
                    echo
                    echo "    Virtual: $vid"
                    if [ "$ACTIVE" = "true" ]; then
                        check_ok "      Active: true"
                    else
                        check_warn "      Active: false"
                    fi
                    
                    # Streaming is false when no audio is playing, which is normal
                    # If active=true and effect is loaded, the system is working correctly
                    if [ "$STREAMING" = "true" ]; then
                        check_ok "      Streaming: true (receiving audio)"
                    elif [ "$ACTIVE" = "true" ] && [ "$EFFECT" != "none" ]; then
                        check_ok "      Streaming: false (no audio playing, but configured correctly)"
                    else
                        check_warn "      Streaming: false (no audio input)"
                    fi
                    
                    if [ "$EFFECT" != "none" ] && [ -n "$EFFECT" ]; then
                        check_ok "      Effect: $EFFECT"
                    else
                        check_warn "      Effect: none (no effect loaded)"
                    fi
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
    if echo "$DEVICE_DATA" | jq -e '.devices' >/dev/null 2>&1; then
        # Extract device IDs using jq
        DEVICE_IDS=$(echo "$DEVICE_DATA" | jq -r '.devices | keys[]' 2>/dev/null || echo "")
        DEVICE_COUNT=$(echo "$DEVICE_IDS" | grep -v '^$' | wc -l | tr -d ' ')
        check_ok "Found $DEVICE_COUNT device(s)"
        
        echo "$DEVICE_IDS" | grep -v '^$' | while read did; do
            if [ -n "$did" ]; then
                # Extract online status using jq
                ONLINE=$(echo "$DEVICE_DATA" | jq -r ".devices.\"$did\".online // \"unknown\"")
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

