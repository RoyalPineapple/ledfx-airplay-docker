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
    
    # Check connection to previous component (Shairport-Sync)
    echo
    echo "  Component Connections:"
    if docker_cmd exec ledfx pactl list sink-inputs 2>/dev/null | grep -q 'Shairport Sync'; then
        check_ok "Connected to Shairport-Sync (active audio stream)"
    else
        # Check if socket is accessible even if no active stream
        if docker_cmd exec shairport-sync test -S /pulse/pulseaudio.socket 2>/dev/null; then
            check_ok "Connected to Shairport-Sync (socket accessible, no active stream)"
        else
            check_warn "Not connected to Shairport-Sync (socket not accessible)"
        fi
    fi
    
    # Check connection to next component (LedFX)
    # LedFX should be using PulseAudio as its audio input
    if docker_cmd exec ledfx pactl list sources 2>/dev/null | grep -q 'pulse'; then
        check_ok "LedFX configured to use PulseAudio (source available)"
    else
        # Check via LedFX API if available
        if curl -s -f "${LEDFX_URL}/api/audio/devices" > /dev/null 2>&1; then
            AUDIO_DEVICE=$(curl -s "${LEDFX_URL}/api/audio/devices" 2>/dev/null | grep -o '"active_device":\s*[0-9]*' | grep -o '[0-9]*' || echo "")
            if [ -n "$AUDIO_DEVICE" ] && [ "$AUDIO_DEVICE" = "0" ]; then
                check_ok "LedFX configured to use PulseAudio (device index 0)"
            else
                check_warn "LedFX may not be using PulseAudio (device index: ${AUDIO_DEVICE:-unknown})"
            fi
        else
            check_warn "Could not verify LedFX audio configuration (API not accessible)"
        fi
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

