#!/bin/sh
# LedFx Stop Script - Deactivate virtual(s) (preserves effects, never pauses)
# Usage: ledfx-stop.sh [virtual_ids] [host] [port]
#   virtual_ids: Comma-separated list of virtual IDs (default: from config or all)
set -eu

# Load configuration from YAML (preferred) or legacy .conf file
LEDFX_HOST="localhost"
LEDFX_PORT="8888"
VIRTUAL_IDS=""
ALL_VIRTUALS=true

# Try YAML config first
if [ -f /configs/ledfx-hooks.yaml ]; then
  LEDFX_HOST=$(yq eval '.ledfx.host // "localhost"' /configs/ledfx-hooks.yaml 2>/dev/null || echo "localhost")
  LEDFX_PORT=$(yq eval '.ledfx.port // 8888' /configs/ledfx-hooks.yaml 2>/dev/null || echo "8888")
  
  # Check if all virtuals should be controlled (explicit flag)
  all_virtuals_flag=$(yq eval '.hooks.end.all_virtuals // true' /configs/ledfx-hooks.yaml 2>/dev/null || echo "true")
  if [ "$all_virtuals_flag" = "true" ]; then
    ALL_VIRTUALS=true
  else
    ALL_VIRTUALS=false
    # Get list of virtual IDs from YAML
    VIRTUAL_IDS=$(yq eval '.hooks.end.virtuals[].id' /configs/ledfx-hooks.yaml 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  fi
# Fallback to legacy .conf file
elif [ -f /configs/ledfx-hooks.conf ]; then
  . /configs/ledfx-hooks.conf
  if [ -n "${VIRTUAL_IDS:-}" ]; then
    ALL_VIRTUALS=false
  fi
fi

# Override with command-line arguments if provided
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

# If no virtuals specified and not "all virtuals", get all virtuals from API
if [ -z "$VIRTUAL_IDS" ] && [ "$ALL_VIRTUALS" != "true" ]; then
  # This shouldn't happen if config is valid, but handle gracefully
  ALL_VIRTUALS=true
fi

if [ "$ALL_VIRTUALS" = "true" ] || [ -z "$VIRTUAL_IDS" ]; then
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
    # Get repeat count for this virtual from YAML
    stop_repeats=1
    if [ -f /configs/ledfx-hooks.yaml ] && [ "$ALL_VIRTUALS" = "false" ]; then
      stop_repeats=$(yq eval ".hooks.end.virtuals[] | select(.id == \"$vid\") | .repeats // 1" /configs/ledfx-hooks.yaml 2>/dev/null || echo "1")
    fi
    
    if virtual_uses_govee "$vid"; then
      # Use toggle pattern with configurable repeats from YAML
      deactivate_virtual_govee "$vid" "$stop_repeats"
    else
      # For non-Govee, still support repeats (simple activate/deactivate pattern)
      deactivate_virtual_simple "$vid"
      # If repeats > 1, do additional cycles
      if [ "$stop_repeats" -gt 1 ]; then
        i=1
        while [ $i -lt "$stop_repeats" ]; do
          sleep 0.1
          deactivate_virtual_simple "$vid"
          i=$((i + 1))
        done
      fi
    fi
  fi
done
unset IFS

# Note: This deactivates virtuals but preserves all effects
# Effects remain configured and will be active when virtual is reactivated
# We never set paused=true - only set paused=false when starting

