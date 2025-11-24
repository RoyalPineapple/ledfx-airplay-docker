#!/usr/bin/env bash
# LedFx Play Script - Resume effects by restoring brightness to 1.0
# Usage: ledfx-play.sh [virtual_id] [host] [port]
set -euo pipefail

VIRTUAL_ID="${1:-dig-quad}"
LEDFX_HOST="${2:-192.168.2.122}"
LEDFX_PORT="${3:-8888}"
BASE_URL="http://${LEDFX_HOST}:${LEDFX_PORT}"

# Get current effect config
CURRENT_EFFECT=$(curl -s "${BASE_URL}/api/virtuals/${VIRTUAL_ID}/effects" | jq '.effect')

# Restore brightness to 1.0 to resume the effect
UPDATED_EFFECT=$(echo "$CURRENT_EFFECT" | jq '.config.brightness = 1.0')

# Apply the updated effect config
curl -X PUT -H "Content-Type: application/json" \
  -d "$UPDATED_EFFECT" \
  -s "${BASE_URL}/api/virtuals/${VIRTUAL_ID}/effects" > /dev/null

# Note: This restores brightness to 1.0, resuming the effect
# LedFx remains in control

