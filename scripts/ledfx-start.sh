#!/bin/sh
# LedFx Start Script - Activate virtual(s) and ensure not paused
# Equivalent to: activate virtual + press play button
# Usage: ledfx-start.sh [virtual_ids] [host] [port]
#   virtual_ids: Comma-separated list of virtual IDs (default: from config or all)
set -eu

# Load configuration if available
if [ -f /configs/ledfx-hooks.conf ]; then
  . /configs/ledfx-hooks.conf
fi

VIRTUAL_IDS="${1:-${VIRTUAL_IDS:-}}"
LEDFX_HOST="${2:-${LEDFX_HOST:-localhost}}"
LEDFX_PORT="${3:-${LEDFX_PORT:-8888}}"
BASE_URL="http://${LEDFX_HOST}:${LEDFX_PORT}"

# Function to activate a single virtual
activate_virtual() {
  local vid="$1"
  curl -X PUT -H "Content-Type: application/json" \
    -d '{"active": true}' \
    -s "${BASE_URL}/api/virtuals/${vid}" > /dev/null
}

# If no virtuals specified, get all virtuals from API
if [ -z "$VIRTUAL_IDS" ]; then
  # Get all virtual IDs from API (requires curl and basic parsing)
  VIRTUAL_IDS=$(curl -s "${BASE_URL}/api/virtuals" | \
    grep -o '"[^"]*":\s*{' | \
    grep -v 'status\|virtuals' | \
    sed 's/":.*//' | \
    sed 's/"//g' | \
    tr '\n' ',' | \
    sed 's/,$//')
fi

# Activate each virtual
IFS=','
for vid in $VIRTUAL_IDS; do
  # Trim whitespace
  vid=$(echo "$vid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$vid" ]; then
    activate_virtual "$vid"
  fi
done
unset IFS

# Ensure not paused (press play) - this is global, affects all virtuals
# Retry a few times in case of transient failures
for i in 1 2 3; do
  if curl -X PUT -H "Content-Type: application/json" \
    -d '{"paused": false}' \
    -s "${BASE_URL}/api/virtuals" | grep -q '"status": "success"'; then
    break
  fi
  sleep 0.5
done

# Note: streaming is read-only and automatically becomes true when audio input starts
# We ensure active=true and paused=false, then streaming will follow when audio arrives

