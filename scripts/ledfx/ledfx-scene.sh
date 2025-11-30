#!/bin/sh
# LedFX Scene Script - Activate scene(s)
# Usage: ledfx-scene.sh [scene_ids] [host] [port]
#   scene_ids: Comma-separated list of scene IDs (default: from config)
set -eu

# Load configuration from YAML
# Default to 'ledfx' container name for bridge networking
LEDFX_HOST="ledfx"
LEDFX_PORT="8888"
SCENE_IDS=""

# Try YAML config first
if [ -f /configs/ledfx-hooks.yaml ]; then
  LEDFX_HOST=$(yq eval '.ledfx.host // "ledfx"' /configs/ledfx-hooks.yaml 2>/dev/null || echo "ledfx")
  LEDFX_PORT=$(yq eval '.ledfx.port // 8888' /configs/ledfx-hooks.yaml 2>/dev/null || echo "8888")
  
  # Get list of scene IDs from YAML based on hook type
  HOOK_TYPE="${HOOK_TYPE:-start}"
  SCENE_IDS=$(yq eval ".hooks.${HOOK_TYPE}.scenes[]?" /configs/ledfx-hooks.yaml 2>/dev/null | tr '\n' ',' | sed 's/,$//')
fi

# Override with command-line arguments if provided
SCENE_IDS="${1:-${SCENE_IDS:-}}"
LEDFX_HOST="${2:-${LEDFX_HOST:-ledfx}}"
LEDFX_PORT="${3:-${LEDFX_PORT:-8888}}"
BASE_URL="http://${LEDFX_HOST}:${LEDFX_PORT}"

# Function to activate a single scene
activate_scene() {
  local sid="$1"
  
  # Try POST /api/scenes/{scene_id} first (most common pattern)
  response=$(curl -X POST -H "Content-Type: application/json" \
    -s -w "\n%{http_code}" \
    "${BASE_URL}/api/scenes/${sid}" 2>/dev/null || echo "000")
  
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  
  # If POST doesn't work, try PUT
  if [ "$http_code" != "200" ] && [ "$http_code" != "204" ]; then
    response=$(curl -X PUT -H "Content-Type: application/json" \
      -d '{"action": "activate"}' \
      -s -w "\n%{http_code}" \
      "${BASE_URL}/api/scenes/${sid}" 2>/dev/null || echo "000")
    
    http_code=$(echo "$response" | tail -n1)
  fi
  
  # If still doesn't work, try POST with action
  if [ "$http_code" != "200" ] && [ "$http_code" != "204" ]; then
    response=$(curl -X POST -H "Content-Type: application/json" \
      -d '{"action": "activate"}' \
      -s -w "\n%{http_code}" \
      "${BASE_URL}/api/scenes/${sid}" 2>/dev/null || echo "000")
    
    http_code=$(echo "$response" | tail -n1)
  fi
  
  # Log result (non-fatal if scene doesn't exist)
  if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
    echo "Activated scene: ${sid}" >&2
    return 0
  elif [ "$http_code" = "404" ]; then
    echo "Scene not found: ${sid}" >&2
    return 1
  else
    echo "Failed to activate scene ${sid} (HTTP ${http_code})" >&2
    return 1
  fi
}

# Activate each scene
if [ -z "$SCENE_IDS" ]; then
  echo "No scenes configured" >&2
  exit 0
fi

IFS=','
for sid in $SCENE_IDS; do
  # Trim whitespace
  sid=$(echo "$sid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$sid" ]; then
    activate_scene "$sid"
  fi
done
unset IFS

