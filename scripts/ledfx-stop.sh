#!/bin/sh
# LedFx Stop Script - Deactivate virtual(s) (preserves effects, never pauses)
# Usage: ledfx-stop.sh [virtual_ids] [host] [port]
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

# Function to check if a virtual uses Govee devices
# Returns 0 (true) if virtual uses Govee, 1 (false) otherwise
virtual_uses_govee() {
  local vid="$1"
  local devices_data=$(curl -s "${BASE_URL}/api/devices" 2>/dev/null || echo "{}")
  local virtual_data=$(curl -s "${BASE_URL}/api/virtuals/${vid}" 2>/dev/null || echo "{}")
  
  # Get all Govee device IDs
  local govee_device_ids=$(echo "$devices_data" | jq -r '.devices | to_entries[] | select(.value.type == "govee") | .key' 2>/dev/null | grep -v '^$')
  
  if [ -z "$govee_device_ids" ]; then
    return 1  # No Govee devices found
  fi
  
  # Check if this virtual has any Govee devices in its segments
  local segments=$(echo "$virtual_data" | jq -r ".[\"${vid}\"].segments[]?.device_id // empty" 2>/dev/null | grep -v '^$')
  
  for seg_device in $segments; do
    if echo "$govee_device_ids" | grep -q "^${seg_device}$"; then
      return 0  # Found Govee device
    fi
  done
  
  return 1  # No Govee devices in this virtual
}

# Function to deactivate a single virtual (simple version for non-Govee)
deactivate_virtual_simple() {
  local vid="$1"
  curl -X PUT -H "Content-Type: application/json" \
    -d '{"active": false}' \
    -s "${BASE_URL}/api/virtuals/${vid}" > /dev/null
}

# Function to deactivate a single virtual (toggle pattern for Govee reliability)
# Parameters: $1 = virtual_id, $2 = repeats (default: 1)
deactivate_virtual_govee() {
  local vid="$1"
  local repeats="${2:-1}"
  local i=0
  
  # Repeat the toggle pattern: false → delay → true → delay → false
  while [ $i -lt $repeats ]; do
    # Send deactivate command
    curl -X PUT -H "Content-Type: application/json" \
      -d '{"active": false}' \
      -s "${BASE_URL}/api/virtuals/${vid}" > /dev/null
    # Wait 0.1 seconds
    sleep 0.1
    # Send activate command (toggle to ensure state is processed)
    curl -X PUT -H "Content-Type: application/json" \
      -d '{"active": true}' \
      -s "${BASE_URL}/api/virtuals/${vid}" > /dev/null
    # Wait 0.1 seconds
    sleep 0.1
    # Send deactivate command again (final state for this cycle)
    curl -X PUT -H "Content-Type: application/json" \
      -d '{"active": false}' \
      -s "${BASE_URL}/api/virtuals/${vid}" > /dev/null
    
    i=$((i + 1))
    # Add delay between cycles (except after the last one)
    if [ $i -lt $repeats ]; then
      sleep 0.1
    fi
  done
}

# If no virtuals specified, get all virtuals from API
if [ -z "$VIRTUAL_IDS" ]; then
  # Get all virtual IDs from API using jq
  VIRTUAL_IDS=$(curl -s "${BASE_URL}/api/virtuals" | \
    jq -r '.virtuals | keys[]' 2>/dev/null | \
    tr '\n' ',' | \
    sed 's/,$//')
fi

# Deactivate each virtual (use toggle pattern only for Govee devices)
IFS=','
for vid in $VIRTUAL_IDS; do
  # Trim whitespace
  vid=$(echo "$vid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$vid" ]; then
    if virtual_uses_govee "$vid"; then
      # Use toggle pattern with configurable repeats (default: 1)
      deactivate_virtual_govee "$vid" "${GOVEE_STOP_REPEATS:-1}"
    else
      deactivate_virtual_simple "$vid"
    fi
  fi
done
unset IFS

# Note: This deactivates virtuals but preserves all effects
# Effects remain configured and will be active when virtual is reactivated
# We never set paused=true - only set paused=false when starting

