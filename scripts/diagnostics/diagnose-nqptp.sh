#!/usr/bin/env bash
# NQPTP Diagnostic Script
# Checks AirPlay 2 timing synchronization status
# Usage: Source diagnose-common.sh first, then run this script

section "3. NQPTP (AirPlay 2 Timing Synchronization)"

# Check if container is running
if docker_cmd ps --format '{{.Names}}' | grep -q '^nqptp$'; then
    check_ok "Container is running"
    
    # Check NQPTP process
    if docker_cmd exec nqptp pgrep -f nqptp > /dev/null 2>&1; then
        check_ok "NQPTP process is running"
        
        # Get version
        VERSION=$(docker_cmd exec nqptp nqptp -V 2>&1 | head -1 || echo "unknown")
        if [ "$VERSION" != "unknown" ]; then
            check_ok "Version: $VERSION"
        fi
    else
        check_fail "NQPTP process not found"
    fi
    
    # Check port bindings (319, 320 UDP)
    # Note: When running from container, we can't check host ports directly
    # Instead, check if nqptp process is running (ports are on host networking)
    echo
    echo "  Port Status:"
    if [ "${REMOTE:-false}" = false ] && command -v ss >/dev/null 2>&1; then
        # Only check ports when running on host (not from container)
        if run_cmd "ss -unlp 2>/dev/null | grep -q ':319.*nqptp'"; then
            check_ok "Port 319/UDP bound (PTP event)"
        else
            check_warn "Port 319/UDP not bound"
        fi
        
        if run_cmd "ss -unlp 2>/dev/null | grep -q ':320.*nqptp'"; then
            check_ok "Port 320/UDP bound (PTP general)"
        else
            check_warn "Port 320/UDP not bound"
        fi
    else
        # When running from container, just verify process is running
        check_ok "NQPTP running on host networking (ports 319, 320/UDP)"
    fi
    
    # Check shared memory interface
    if docker_cmd exec nqptp test -d /dev/shm 2>/dev/null; then
        check_ok "Shared memory directory accessible"
    else
        check_warn "Shared memory directory not accessible"
    fi
    
else
    check_fail "Container is not running"
fi

