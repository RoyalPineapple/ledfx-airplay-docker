#!/usr/bin/env bash
# Avahi Diagnostic Script
# Checks mDNS/Bonjour service discovery status
# Usage: Source diagnose-common.sh first, then run this script

section "2. Avahi (mDNS/Bonjour Service Discovery)"

# Check if container is running
if docker_cmd ps --format '{{.Names}}' | grep -q '^avahi$'; then
    check_ok "Container is running"
    
    # Check Avahi daemon process
    if docker_cmd exec avahi pgrep -f avahi-daemon > /dev/null 2>&1; then
        check_ok "Avahi daemon process is running"
    else
        check_fail "Avahi daemon process not found"
    fi
    
    # Check D-Bus
    if docker_cmd exec avahi test -S /var/run/dbus/system_bus_socket 2>/dev/null; then
        check_ok "D-Bus socket exists"
    else
        check_warn "D-Bus socket not found"
    fi
    
    # Check if AirPlay service is advertised
    echo
    echo "  mDNS Services:"
    # Use timeout to prevent hanging - avahi-browse can be slow
    # Case-insensitive search for AirPlay services
    AIRPLAY_SERVICES=$(timeout 5 docker_cmd exec avahi avahi-browse -a -r 2>&1 | grep -iE 'airplay|raop|airtunes' | wc -l 2>/dev/null | tr -d ' \n' || echo "0")
    # Ensure we have a valid integer (default to 0 if empty or invalid)
    AIRPLAY_SERVICES=${AIRPLAY_SERVICES:-0}
    if [ "${AIRPLAY_SERVICES}" -gt 0 ] 2>/dev/null; then
        check_ok "Found $AIRPLAY_SERVICES AirPlay service(s) on network"
        
        # Get the AirPlay device name from shairport-sync config
        AIRPLAY_NAME=""
        if docker_cmd exec shairport-sync test -f /etc/shairport-sync.conf 2>/dev/null; then
            # Extract name from config file (format: name = "AirGlow-Staging";)
            AIRPLAY_NAME=$(docker_cmd exec shairport-sync grep -i '^[[:space:]]*name[[:space:]]*=' /etc/shairport-sync.conf 2>/dev/null | sed -n 's/.*name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | tr -d ' \n' || echo "")
        fi
        
        # If we couldn't get it from config, try from shairport-sync displayConfig
        if [ -z "$AIRPLAY_NAME" ]; then
            AIRPLAY_NAME=$(docker_cmd exec shairport-sync shairport-sync --displayConfig 2>&1 | grep -i 'name =' | sed -n 's/.*name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | tr -d ' \n' || echo "")
        fi
        
        # Check if our service is advertised (with timeout)
        if [ -n "$AIRPLAY_NAME" ]; then
            if timeout 5 docker_cmd exec avahi avahi-browse -a -r 2>&1 | grep -qi "$AIRPLAY_NAME"; then
                check_ok "Airglow service '$AIRPLAY_NAME' is being advertised"
            else
                check_warn "Airglow service '$AIRPLAY_NAME' not found in mDNS browse (may need to wait for advertisement)"
            fi
        else
            # Fallback to generic search if we can't determine the name
            if timeout 5 docker_cmd exec avahi avahi-browse -a -r 2>&1 | grep -qi 'airglow'; then
                check_ok "Airglow service is being advertised (name not determined)"
            else
                check_warn "Airglow service not found in mDNS browse (may need to wait for advertisement)"
            fi
        fi
    else
        check_warn "No AirPlay services found on network (or mDNS browse timed out)"
    fi
    
    # Check reflector mode
    if docker_cmd exec avahi grep -q 'enable-reflector=yes' /etc/avahi/avahi-daemon.conf 2>/dev/null; then
        check_ok "Reflector mode enabled"
    else
        check_warn "Reflector mode not enabled (may affect bridge networking)"
    fi
    
    # Check connection to next component (Shairport-Sync via D-Bus)
    echo
    echo "  Component Connections:"
    if docker_cmd exec shairport-sync test -S /var/run/dbus/system_bus_socket 2>/dev/null; then
        # Check if shairport-sync can actually connect to D-Bus
        if docker_cmd exec shairport-sync dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1 | grep -q 'org.freedesktop.Avahi' 2>/dev/null; then
            check_ok "Connected to Shairport-Sync (D-Bus connection active)"
        else
            check_warn "D-Bus socket accessible but Avahi service not found (Shairport-Sync may not be connected)"
        fi
    else
        check_warn "D-Bus socket not accessible to Shairport-Sync"
    fi
    
else
    check_fail "Container is not running"
fi

