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
        DEVICE_NAME=$(docker_cmd exec shairport-sync shairport-sync --displayConfig 2>&1 | grep 'name =' | sed -n 's/.*name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || echo "")
        if [ -z "$DEVICE_NAME" ]; then
            # Try alternative format: player name = "..."
            DEVICE_NAME=$(docker_cmd exec shairport-sync shairport-sync --displayConfig 2>&1 | grep -i 'player name' | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1 || echo "")
        fi
        if [ -n "$DEVICE_NAME" ]; then
            check_ok "Device name: $DEVICE_NAME"
        else
            check_warn "Could not determine device name"
        fi
        
        # Check AirPlay version (1 vs 2)
        echo
        echo "  AirPlay Version:"
        VERSION_STRING=$(docker_cmd exec shairport-sync shairport-sync -V 2>&1 | head -1 || echo "")
        if echo "$VERSION_STRING" | grep -qi "airplay2"; then
            check_ok "Built with AirPlay 2 support"
        else
            check_warn "Not built with AirPlay 2 support (version: $VERSION_STRING)"
        fi
        
        # Check if running in AirPlay 2 mode
        STARTUP_MODE=$(docker_cmd logs shairport-sync 2>&1 | grep -i "Startup in" | tail -1 || echo "")
        if echo "$STARTUP_MODE" | grep -qi "AirPlay 2 mode"; then
            check_ok "Running in AirPlay 2 mode"
        elif echo "$STARTUP_MODE" | grep -qi "classic Airplay.*AirPlay 1"; then
            check_warn "Running in AirPlay 1 (classic) mode - AirPlay 2 not available"
        else
            check_warn "Could not determine AirPlay mode from logs"
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
    
    # Check connection to NQPTP (shared memory) - required for AirPlay 2
    echo
    echo "  NQPTP (AirPlay 2 Timing):"
    if docker_cmd exec shairport-sync test -d /dev/shm 2>/dev/null; then
        check_ok "Shared memory accessible (NQPTP connection available)"
        # Check if NQPTP container is running (required for AirPlay 2)
        if docker_cmd ps --format '{{.Names}}' | grep -q '^nqptp$'; then
            if docker_cmd exec nqptp pgrep -f nqptp > /dev/null 2>&1; then
                check_ok "NQPTP container is running (AirPlay 2 timing available)"
            else
                check_warn "NQPTP container exists but process not running"
            fi
        else
            check_warn "NQPTP container not found (required for AirPlay 2)"
        fi
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
    
    # Check port listening status
    echo
    echo "  Network Ports:"
    if docker_cmd exec shairport-sync netstat -tulnp 2>&1 | grep -q ':7000.*LISTEN'; then
        check_ok "Port 7000 (AirPlay control) is listening"
    else
        check_fail "Port 7000 (AirPlay control) is not listening"
    fi
    
    if docker_cmd exec shairport-sync netstat -tulnp 2>&1 | grep -q ':5000.*LISTEN'; then
        check_ok "Port 5000 (AirPlay audio TCP) is listening"
    else
        check_warn "Port 5000 (AirPlay audio TCP) is not listening"
    fi
    
    if docker_cmd exec shairport-sync netstat -ulnp 2>&1 | grep -q ':5000.*udp'; then
        check_ok "Port 5000 (AirPlay audio UDP) is listening"
    else
        check_warn "Port 5000 (AirPlay audio UDP) is not listening"
    fi
    
    # Check mDNS advertisement (what IP is being advertised)
    echo
    echo "  mDNS Advertisement:"
    if [ -n "$DEVICE_NAME" ] && docker_cmd exec avahi avahi-browse -r _raop._tcp 2>&1 | grep -q "$DEVICE_NAME"; then
        # Extract the IP address being advertised
        ADVERTISED_IP=$(docker_cmd exec avahi avahi-browse -r _raop._tcp 2>&1 | grep "$DEVICE_NAME" | grep -oE 'address = \[([0-9.]+)\]' | head -1 | sed 's/address = \[\(.*\)\]/\1/' || echo "")
        if [ -n "$ADVERTISED_IP" ]; then
            # Check if it's a Docker bridge IP (172.x.x.x or 10.x.x.x)
            if echo "$ADVERTISED_IP" | grep -qE '^172\.(1[6-9]|2[0-9]|3[0-1])\.|^10\.'; then
                check_warn "Service advertised with Docker bridge IP ($ADVERTISED_IP) - clients may not be able to connect"
            else
                check_ok "Service advertised with IP: $ADVERTISED_IP"
            fi
        else
            check_warn "Could not determine advertised IP address"
        fi
    else
        check_warn "Service '$DEVICE_NAME' not found in mDNS browse"
    fi
    
    # Check connection logs for errors
    echo
    echo "  Connection Status:"
    RECENT_ERRORS=$(docker_cmd logs shairport-sync --since 5m 2>&1 | grep -iE 'error|fail|fatal|cannot|unable' | grep -v 'mutex_lock' | wc -l | tr -d ' \n' || echo "0")
    if [ "${RECENT_ERRORS:-0}" -gt 0 ]; then
        check_warn "Found $RECENT_ERRORS recent error(s) in logs"
        docker_cmd logs shairport-sync --since 5m 2>&1 | grep -iE 'error|fail|fatal|cannot|unable' | grep -v 'mutex_lock' | tail -3 | while read line; do
            echo "    $line"
        done
    else
        check_ok "No recent errors in connection logs"
    fi
    
    # Check for connection attempts
    RECENT_CONNECTIONS=$(docker_cmd logs shairport-sync --since 5m 2>&1 | grep -iE 'connection.*closed|teardown|rtsp' | grep -v 'mutex_lock' | wc -l | tr -d ' \n' || echo "0")
    if [ "${RECENT_CONNECTIONS:-0}" -gt 0 ]; then
        check_ok "Recent connection activity detected ($RECENT_CONNECTIONS events)"
        # Check if connections are being closed immediately (connection issue)
        IMMEDIATE_CLOSES=$(docker_cmd logs shairport-sync --since 5m 2>&1 | grep -i 'connection.*closed by client' | wc -l | tr -d ' \n' || echo "0")
        if [ "${IMMEDIATE_CLOSES:-0}" -gt 2 ]; then
            check_warn "Multiple connections closed immediately - may indicate network/IP address issue"
        fi
    else
        check_warn "No recent connection activity"
    fi
    
    # Check recent connections
    echo
    echo "  Recent AirPlay activity:"
    ACTIVITY=$(docker_cmd logs shairport-sync --since 5m 2>&1 | grep -iE '(connection|playback|active|rtsp)' | grep -v 'mutex_lock' | tail -5)
    if [ -n "$ACTIVITY" ]; then
        echo "$ACTIVITY" | while read line; do
        echo "    $line"
        done
    else
        echo "    No recent activity"
    fi
    
else
    check_fail "Container is not running"
fi

