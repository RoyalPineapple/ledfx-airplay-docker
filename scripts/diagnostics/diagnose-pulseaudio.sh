#!/usr/bin/env bash
# PulseAudio Diagnostic Script
# Checks audio bridge status
# Usage: Source diagnose-common.sh first, then run this script

section "4. PulseAudio (Audio Bridge)"

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
    SINK_INPUTS=$(docker_cmd exec ledfx pactl list sink-inputs 2>/dev/null | grep -c 'Sink Input #' 2>/dev/null | tr -d ' \n' || echo "0")
    # Ensure we have a valid integer (default to 0 if empty or invalid)
    SINK_INPUTS=${SINK_INPUTS:-0}
    if [ "${SINK_INPUTS}" -gt 0 ] 2>/dev/null; then
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

