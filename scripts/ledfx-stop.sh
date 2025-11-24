#!/bin/sh
# LedFx Stop Script - Pause effects and deactivate virtual (preserves effects)
# Usage: ledfx-stop.sh [virtual_id] [host] [port]
set -eu

VIRTUAL_ID="${1:-dig-quad}"
LEDFX_HOST="${2:-192.168.2.122}"
LEDFX_PORT="${3:-8888}"
BASE_URL="http://${LEDFX_HOST}:${LEDFX_PORT}"

# Step 1: Pause all effects (press pause button)
curl -X PUT -H "Content-Type: application/json" \
  -d '{"paused": true}' \
  -s "${BASE_URL}/api/virtuals" > /dev/null

# Step 2: Deactivate virtual (idempotent - safe to call multiple times)
curl -X PUT -H "Content-Type: application/json" \
  -d '{"active": false}' \
  -s "${BASE_URL}/api/virtuals/${VIRTUAL_ID}" > /dev/null

# Note: This pauses and deactivates but preserves all effects
# Effects remain configured and will be active when virtual is reactivated

