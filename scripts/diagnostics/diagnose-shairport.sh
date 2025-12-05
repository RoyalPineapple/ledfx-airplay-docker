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
    
    # Check built-in Avahi daemon (via D-Bus)
    echo
    echo "  Built-in Avahi (mDNS/Bonjour):"
    if docker_cmd exec shairport-sync test -S /var/run/dbus/system_bus_socket 2>/dev/null; then
        check_ok "D-Bus socket accessible"
        # Check if shairport-sync's built-in Avahi is accessible via D-Bus
        # Use timeout to prevent hanging - call docker_cmd directly (it's a function from diagnose-common.sh)
        if [ "${REMOTE:-false}" = true ]; then
            DBUS_OUTPUT=$(timeout 5 $SSH_CMD "docker exec shairport-sync dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1" || echo "")
        else
            DBUS_OUTPUT=$(timeout 5 docker exec shairport-sync dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1 || echo "")
        fi
        if echo "$DBUS_OUTPUT" | grep -q 'org.freedesktop.Avahi' 2>/dev/null; then
            check_ok "Built-in Avahi daemon is running (D-Bus connection active)"
        else
            check_fail "D-Bus socket exists but built-in Avahi service not found"
            # Show D-Bus error details
            DBUS_ERROR=$(echo "$DBUS_OUTPUT" | grep -iE 'error|fail' | head -1 || echo "")
            if [ -n "$DBUS_ERROR" ]; then
                echo "    D-Bus error: $DBUS_ERROR"
            fi
        fi
    else
        check_fail "D-Bus socket not accessible (built-in Avahi cannot start)"
    fi
    
    # Check NQPTP (shared memory) - shairport-sync uses internal nqptp for AirPlay 2
    echo
    echo "  NQPTP (AirPlay 2 Timing):"
    if docker_cmd exec shairport-sync test -d /dev/shm 2>/dev/null; then
        check_ok "Shared memory accessible (/dev/shm mounted)"
        # Check if shairport-sync's internal nqptp is creating shared memory files
        # Shairport-sync's internal nqptp creates files in /dev/shm for timing synchronization
        SHM_FILES=$(docker_cmd exec shairport-sync ls -la /dev/shm 2>&1 | grep -E 'nqptp|shairport' | wc -l | tr -d ' \n' || echo "0")
        if [ "${SHM_FILES:-0}" -gt 0 ]; then
            check_ok "NQPTP shared memory files found (internal nqptp active)"
        else
            check_warn "No NQPTP shared memory files found (may indicate AirPlay 2 timing issue)"
        fi
    else
        check_warn "Shared memory not accessible (/dev/shm not mounted)"
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
    # Use shairport-sync's built-in Avahi daemon
    echo
    echo "  mDNS Advertisement (AirPlay Discovery):"
    if [ -n "$DEVICE_NAME" ]; then
        # Check both AirPlay 2 (_raop._tcp) and AirPlay 1 (_airplay._tcp)
        # Use timeout to prevent hanging - browse from shairport-sync container which has built-in Avahi
        FOUND_IN_RAOP=$(timeout 10 docker_cmd exec shairport-sync avahi-browse -rpt _raop._tcp 2>&1 | grep -qiE "$(echo "$DEVICE_NAME" | sed 's/~/.*/g' | sed 's/[()]/.*/g' | sed 's/\\032/ /g' | sed 's/\\040/(/g' | sed 's/\\041/)/g')" && echo "true" || echo "false")
        FOUND_IN_AIRPLAY1=$(timeout 10 docker_cmd exec shairport-sync avahi-browse -rpt _airplay._tcp 2>&1 | grep -qiE "$(echo "$DEVICE_NAME" | sed 's/~/.*/g' | sed 's/[()]/.*/g' | sed 's/\\032/ /g' | sed 's/\\040/(/g' | sed 's/\\041/)/g')" && echo "true" || echo "false")
        
        if [ "$FOUND_IN_RAOP" = "true" ] || [ "$FOUND_IN_AIRPLAY1" = "true" ]; then
            # Extract the IP address being advertised (prefer RAOP if found)
            SERVICE_TYPE="_raop._tcp"
            if [ "$FOUND_IN_RAOP" = "false" ]; then
                SERVICE_TYPE="_airplay._tcp"
            fi
            
            ADVERTISED_IP=$(timeout 10 docker_cmd exec shairport-sync avahi-browse -rpt "$SERVICE_TYPE" 2>&1 | grep -iE "$(echo "$DEVICE_NAME" | sed 's/~/.*/g' | sed 's/[()]/.*/g' | sed 's/\\032/ /g' | sed 's/\\040/(/g' | sed 's/\\041/)/g')" | grep -oE 'address = \[([0-9.]+)\]' | head -1 | sed 's/address = \[\(.*\)\]/\1/' || echo "")
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
            
            # Check which service type is being advertised
            if [ "$FOUND_IN_RAOP" = "true" ]; then
                check_ok "AirPlay 2 service (_raop._tcp) is being advertised"
            fi
            if [ "$FOUND_IN_AIRPLAY1" = "true" ]; then
                check_ok "AirPlay 1 service (_airplay._tcp) is being advertised"
            fi
        else
            check_fail "Service '$DEVICE_NAME' not found in mDNS browse"
            # Show what devices were actually found
            FOUND_DEVICES=$(timeout 10 docker_cmd exec shairport-sync avahi-browse -rpt _raop._tcp 2>&1 | grep -oE 'hostname = \[.*\]' | sed 's/hostname = \[\(.*\)\]/\1/' | sort -u | head -5 | tr '\n' ',' | sed 's/,$//' || echo "None")
            if [ -n "$FOUND_DEVICES" ] && [ "$FOUND_DEVICES" != "None" ]; then
                echo "    Found devices: $FOUND_DEVICES"
            fi
        fi
    else
        check_warn "Device name not configured (cannot check advertisement)"
    fi
    
    # Additional AirPlay connectivity tests
    echo
    echo "  AirPlay Connectivity Tests:"
    # Test if port 7000 (RTSP control) is reachable
    if docker_cmd exec shairport-sync timeout 3 nc -z localhost 7000 2>/dev/null; then
        check_ok "Port 7000 (RTSP control) is reachable"
    else
        check_warn "Port 7000 (RTSP control) may not be reachable"
    fi
    
    # Test if port 5000 (RAOP audio) is reachable
    if docker_cmd exec shairport-sync timeout 3 nc -z localhost 5000 2>/dev/null; then
        check_ok "Port 5000 (RAOP audio) is reachable"
    else
        check_warn "Port 5000 (RAOP audio) may not be reachable"
    fi
    
    # Check if shairport-sync is listening on all required ports
    LISTENING_PORTS=$(docker_cmd exec shairport-sync netstat -tuln 2>&1 | grep -E ':(7000|5000|319|320)' | wc -l | tr -d ' \n' || echo "0")
    if [ "${LISTENING_PORTS:-0}" -ge 2 ]; then
        check_ok "Required AirPlay ports are listening"
    else
        check_warn "Some required AirPlay ports may not be listening"
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

