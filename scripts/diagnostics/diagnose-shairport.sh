#!/usr/bin/env bash
# Shairport-Sync Diagnostic Script
# Checks AirPlay receiver status and configuration
# Usage: Source diagnose-common.sh first, then run this script

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
                    # Verify hook path is correct (should be /scripts/ledfx-session-hook.sh)
                    if [ "$HOOK_PATH" = "/scripts/ledfx-session-hook.sh" ]; then
                        check_ok "Hook path is correct"
                    elif [ "$HOOK_PATH" = "/scripts/ledfx/ledfx-session-hook.sh" ]; then
                        check_warn "Hook path uses old location (should be /scripts/ledfx-session-hook.sh)"
                    fi
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
    
    # Check connection to previous component (Avahi via D-Bus)
    echo
    echo "  Component Connections:"
    if docker_cmd exec shairport-sync test -S /var/run/dbus/system_bus_socket 2>/dev/null; then
        # Check if shairport-sync can connect to Avahi via D-Bus
        if docker_cmd exec shairport-sync dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1 | grep -q 'org.freedesktop.Avahi' 2>/dev/null; then
            check_ok "Connected to Avahi (D-Bus connection active)"
        else
            check_warn "D-Bus socket exists but Avahi service not found"
        fi
    else
        check_fail "Not connected to Avahi (D-Bus socket not accessible)"
    fi
    
    # Check connection to NQPTP (shared memory)
    if docker_cmd exec shairport-sync test -d /dev/shm 2>/dev/null; then
        check_ok "Shared memory accessible (NQPTP connection available)"
    else
        check_warn "Shared memory not accessible (NQPTP connection may fail)"
    fi
    
    # Check connection to next component (PulseAudio)
    if docker_cmd exec shairport-sync test -S /pulse/pulseaudio.socket 2>/dev/null; then
        check_ok "PulseAudio socket accessible"
        # Verify PulseAudio is actually responding
        if docker_cmd exec ledfx pactl info 2>/dev/null | grep -q 'Server String'; then
            check_ok "Connected to PulseAudio (server responding)"
        else
            check_warn "PulseAudio socket exists but server not responding"
        fi
    else
        check_warn "Not connected to PulseAudio (socket not found)"
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

