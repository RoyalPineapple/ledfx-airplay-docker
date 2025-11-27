#!/bin/sh
# LedFx Start Script - Activate virtual(s) and ensure not paused
# Equivalent to: activate virtual + press play button
# Usage: ledfx-start.sh [virtual_ids] [host] [port]
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
  all_virtuals_flag=$(yq eval '.hooks.start.all_virtuals // true' /configs/ledfx-hooks.yaml 2>/dev/null || echo "true")
  if [ "$all_virtuals_flag" = "true" ]; then
    ALL_VIRTUALS=true
  else
    ALL_VIRTUALS=false
    # Get list of virtual IDs from YAML
    VIRTUAL_IDS=$(yq eval '.hooks.start.virtuals[].id' /configs/ledfx-hooks.yaml 2>/dev/null | tr '\n' ',' | sed 's/,$//')
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

# Function to activate a single virtual with optional repeats
activate_virtual() {
  local vid="$1"
  local repeats="${2:-1}"
  local i=0
  
  while [ $i -lt $repeats ]; do
    curl -X PUT -H "Content-Type: application/json" \
      -d '{"active": true}' \
      -s "${BASE_URL}/api/virtuals/${vid}" > /dev/null
    
    i=$((i + 1))
    # Add delay between repeats (except after the last one)
    if [ $i -lt $repeats ]; then
      sleep 0.1
    fi
  done
}

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

# Activate each virtual with its configured repeat count
IFS=','
for vid in $VIRTUAL_IDS; do
  # Trim whitespace
  vid=$(echo "$vid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$vid" ]; then
                # Get repeat count for this virtual from YAML
                start_repeats=1
                if [ -f /configs/ledfx-hooks.yaml ] && [ "$ALL_VIRTUALS" = "false" ]; then
                    start_repeats=$(yq eval ".hooks.start.virtuals[] | select(.id == \"$vid\") | .repeats // 1" /configs/ledfx-hooks.yaml 2>/dev/null || echo "1")
                fi
                activate_virtual "$vid" "$start_repeats"
  fi
done
unset IFS

# Note: We only set active=true for the specific virtual(s)
# We do NOT touch global paused state - that would affect all virtuals
# The per-virtual play button in the UI controls active state, not paused
# Streaming is read-only and automatically becomes true when audio input starts

