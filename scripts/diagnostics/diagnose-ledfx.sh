#!/usr/bin/env bash
# LedFX Diagnostic Script
# Checks LED visualization engine status
# Usage: Source diagnose-common.sh first, then run this script
# Requirements: jq (for JSON parsing)

section "5. LedFx (Visualization Engine)"

# Check if container is running
if docker_cmd ps --format '{{.Names}}' | grep -q '^ledfx$'; then
    check_ok "Container is running"
    
    # Check API accessibility
    if curl --max-time 5 --connect-timeout 3 -s -f "${LEDFX_URL}/api/info" > /dev/null 2>&1; then
        INFO=$(curl --max-time 5 --connect-timeout 3 -s "${LEDFX_URL}/api/info")
        VERSION=$(echo "$INFO" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        check_ok "API accessible (version: $VERSION)"
    else
        check_fail "API not accessible at ${LEDFX_URL}"
        exit 1
    fi
    
    # Check connection to previous component (PulseAudio)
    echo
    echo "  Component Connections:"
    # Check if LedFX is configured to use PulseAudio
    if curl --max-time 5 --connect-timeout 3 -s -f "${LEDFX_URL}/api/audio/devices" > /dev/null 2>&1; then
        AUDIO_DEVICE=$(curl --max-time 5 --connect-timeout 3 -s "${LEDFX_URL}/api/audio/devices" 2>/dev/null | grep -o '"active_device":\s*[0-9]*' | grep -o '[0-9]*' || echo "")
        if [ -n "$AUDIO_DEVICE" ] && [ "$AUDIO_DEVICE" = "0" ]; then
            check_ok "Connected to PulseAudio (using device index 0)"
        else
            check_warn "May not be using PulseAudio (device index: ${AUDIO_DEVICE:-unknown})"
        fi
        
        # Verify PulseAudio is actually available
        if docker_cmd exec ledfx pactl info 2>/dev/null | grep -q 'Server String'; then
            check_ok "PulseAudio server accessible"
        else
            check_warn "PulseAudio server not accessible"
        fi
    else
        check_warn "Could not verify PulseAudio connection (audio devices API not accessible)"
    fi
    
    # Check global paused state
    PAUSED=$(curl --max-time 5 --connect-timeout 3 -s "${LEDFX_URL}/api/virtuals" | jq -r '.paused' 2>/dev/null || echo "unknown")
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
    VIRTUAL_DATA=$(curl --max-time 5 --connect-timeout 3 -s "${LEDFX_URL}/api/virtuals")
    if echo "$VIRTUAL_DATA" | jq -e '.virtuals' >/dev/null 2>&1; then
        # Extract virtual IDs using jq
        VIRTUAL_IDS=$(echo "$VIRTUAL_DATA" | jq -r '.virtuals | keys[]' 2>/dev/null || echo "")
        VIRTUAL_COUNT=$(echo "$VIRTUAL_IDS" | grep -v '^$' | wc -l | tr -d ' ')
        check_ok "Found $VIRTUAL_COUNT virtual(s)"
        
        # Check each virtual
        echo "$VIRTUAL_IDS" | grep -v '^$' | while read vid; do
            if [ -n "$vid" ]; then
                VIRTUAL_STATE=$(curl --max-time 5 --connect-timeout 3 -s "${LEDFX_URL}/api/virtuals/${vid}" 2>/dev/null || echo "{}")
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
    DEVICE_DATA=$(curl --max-time 5 --connect-timeout 3 -s "${LEDFX_URL}/api/devices")
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
        
        # Check connection to next component (LED Devices)
        ONLINE_COUNT=$(echo "$DEVICE_DATA" | jq -r '.devices | to_entries[] | select(.value.online == true) | .key' 2>/dev/null | wc -l | tr -d ' ')
        ONLINE_COUNT=${ONLINE_COUNT:-0}
        if [ "${ONLINE_COUNT}" -gt 0 ] 2>/dev/null; then
            check_ok "Connected to ${ONLINE_COUNT} LED device(s)"
        else
            check_warn "No LED devices connected (output will not be visible)"
        fi
    else
        check_warn "Could not retrieve devices"
    fi
    
else
    check_fail "Container is not running"
fi

