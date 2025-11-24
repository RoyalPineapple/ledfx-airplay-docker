#!/usr/bin/env bash
# LedFx Pause Script - Pause effects by setting brightness to 0 (keeps LedFx in control)
# Usage: ledfx-pause.sh [virtual_id] [host] [port]
set -euo pipefail

VIRTUAL_ID="${1:-dig-quad}"
LEDFX_HOST="${2:-192.168.2.122}"
LEDFX_PORT="${3:-8888}"
BASE_URL="http://${LEDFX_HOST}:${LEDFX_PORT}"

# Get current effect config
CURRENT_EFFECT=$(curl -s "${BASE_URL}/api/virtuals/${VIRTUAL_ID}/effects" | jq '.effect')

# Update brightness to 0 to pause visually while keeping LedFx in control
UPDATED_EFFECT=$(echo "$CURRENT_EFFECT" | jq '.config.brightness = 0.0')

# Apply the updated effect config
curl -X PUT -H "Content-Type: application/json" \
  -d "$UPDATED_EFFECT" \
  -s "${BASE_URL}/api/virtuals/${VIRTUAL_ID}/effects" > /dev/null

# Note: This sets brightness to 0, pausing the effect visually
# LedFx remains in control (not released to WLED)

