#!/usr/bin/env bash
# Airglow Diagnostic Tool
# Checks the entire audio flow: AirPlay → Avahi → Shairport-Sync → NQPTP → PulseAudio → LedFx
# Usage:
#   ./diagnose-airglow.sh                    # Run on localhost
#   ./diagnose-airglow.sh 192.168.2.122      # Run on remote host via SSH
#   ./diagnose-airglow.sh airglow.office.lab # Run on remote host via SSH
#   ./diagnose-airglow.sh --json             # Output JSON format
# Requirements: jq (for JSON parsing)
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed."
    echo "Install with: apt-get install jq (Debian/Ubuntu) or brew install jq (macOS)"
    exit 1
fi

# Parse arguments for JSON flag
JSON_OUTPUT=false
TARGET_HOST=""
ARGS=()

for arg in "$@"; do
    if [ "$arg" = "--json" ]; then
        JSON_OUTPUT=true
    else
        ARGS+=("$arg")
        if [ -z "$TARGET_HOST" ]; then
            TARGET_HOST="$arg"
        fi
    fi
done

# Export JSON_OUTPUT for use by component scripts
export JSON_OUTPUT

# Source common functions
source "${SCRIPT_DIR}/diagnostics/diagnose-common.sh"

# Initialize diagnostic environment (pass target host if provided, but not if it's empty or just whitespace)
if [ -n "$TARGET_HOST" ] && [ "$TARGET_HOST" != "--json" ]; then
    diagnose_init "$TARGET_HOST"
else
    diagnose_init
fi

if [ "$JSON_OUTPUT" = "true" ]; then
    # JSON output mode - collect all results
    # Redirect all output to capture JSON lines
    {
        source "${SCRIPT_DIR}/diagnostics/diagnose-shairport.sh" >&2
        source "${SCRIPT_DIR}/diagnostics/diagnose-avahi.sh" >&2
        source "${SCRIPT_DIR}/diagnostics/diagnose-nqptp.sh" >&2
        source "${SCRIPT_DIR}/diagnostics/diagnose-pulseaudio.sh" >&2
        source "${SCRIPT_DIR}/diagnostics/diagnose-ledfx.sh" >&2
    } 2>&1 | grep -E '^\{"status"' > /tmp/diagnostic-json.$$ || true
    
    # Count warnings and errors from captured JSON
    WARNINGS=0
    ERRORS=0
    WARNING_MESSAGES=()
    
    if [ -f /tmp/diagnostic-json.$$ ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                STATUS=$(echo "$line" | jq -r '.status' 2>/dev/null || echo "")
                MESSAGE=$(echo "$line" | jq -r '.message' 2>/dev/null || echo "")
                
                if [ "$STATUS" = "warn" ]; then
                    WARNINGS=$((WARNINGS + 1))
                    if [ -n "$MESSAGE" ] && [[ ! " ${WARNING_MESSAGES[@]} " =~ " ${MESSAGE} " ]]; then
                        WARNING_MESSAGES+=("$MESSAGE")
                    fi
                elif [ "$STATUS" = "error" ]; then
                    ERRORS=$((ERRORS + 1))
                fi
            fi
        done < /tmp/diagnostic-json.$$
        rm -f /tmp/diagnostic-json.$$
    fi
    
    # Output JSON summary
    jq -n \
        --argjson warnings "$WARNINGS" \
        --argjson errors "$ERRORS" \
        --argjson warning_messages "$(printf '%s\n' "${WARNING_MESSAGES[@]}" | jq -R . | jq -s .)" \
        '{
            "warnings": $warnings,
            "errors": $errors,
            "warning_messages": $warning_messages
        }'
else
    # Plain text output mode
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Airglow Diagnostic Tool"
    echo "  Checking audio flow: AirPlay → Avahi → Shairport-Sync → NQPTP → PulseAudio → LedFx"
    echo "═══════════════════════════════════════════════════════════════"
    echo

    # Run component diagnostic scripts in dependency order
    source "${SCRIPT_DIR}/diagnostics/diagnose-shairport.sh"
    source "${SCRIPT_DIR}/diagnostics/diagnose-avahi.sh"
    source "${SCRIPT_DIR}/diagnostics/diagnose-nqptp.sh"
    source "${SCRIPT_DIR}/diagnostics/diagnose-pulseaudio.sh"
    source "${SCRIPT_DIR}/diagnostics/diagnose-ledfx.sh"

    # ============================================================================
    # SUMMARY
    # ============================================================================
    section "Summary"

    echo "Audio Flow Status:"
    echo "  [AirPlay] → [Avahi/mDNS] → [Shairport-Sync] → [NQPTP] → [PulseAudio] → [LedFx] → [LEDs]"
    echo
    echo "Next steps if issues found:"
    if [ "$REMOTE" = true ]; then
        echo "  1. Check Avahi logs: ssh root@${TARGET_HOST} 'docker logs avahi'"
        echo "  2. Check NQPTP logs: ssh root@${TARGET_HOST} 'docker logs nqptp'"
        echo "  3. Check Shairport-Sync logs: ssh root@${TARGET_HOST} 'docker logs shairport-sync'"
        echo "  4. Check LedFx logs: ssh root@${TARGET_HOST} 'docker logs ledfx'"
        echo "  5. Check hook logs: ssh root@${TARGET_HOST} 'docker exec shairport-sync cat /var/log/shairport-sync/ledfx-session-hook.log'"
    else
        echo "  1. Check Avahi logs: docker logs avahi"
        echo "  2. Check NQPTP logs: docker logs nqptp"
        echo "  3. Check Shairport-Sync logs: docker logs shairport-sync"
        echo "  4. Check LedFx logs: docker logs ledfx"
        echo "  5. Check hook logs: docker exec shairport-sync cat /var/log/shairport-sync/ledfx-session-hook.log"
    fi
    echo "  6. Verify AirPlay connection from your device"
    echo
fi

