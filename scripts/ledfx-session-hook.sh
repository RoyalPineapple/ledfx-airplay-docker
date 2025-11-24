#!/bin/sh
# LedFx session hook - invoked by Shairport-Sync on AirPlay session changes
# Controls LedFx visualization state based on AirPlay active/inactive state

set -eu

# Configuration
LEDFX_HOST="${LEDFX_HOST:-localhost}"
LEDFX_PORT="${LEDFX_PORT:-8888}"
LOG_FILE="${LEDFX_HOOK_LOG:-/var/log/shairport-sync/ledfx-session-hook.log}"

usage() {
  cat <<'EOF'
Usage: ledfx-session-hook.sh <start|stop> [message]

Controls LedFx visualization based on AirPlay session state.
- start: Activate LedFx visualization (play audio effects)
- stop: Deactivate LedFx visualization (pause effects)

Additional arguments are logged for debugging.
EOF
}

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

log_entry() {
  local level="$1"
  shift
  local msg="$*"
  mkdir -p "$(dirname "$LOG_FILE")"
  printf "%s [%s] %s\n" "$(timestamp)" "$level" "$msg" >> "$LOG_FILE"
}

# Call LedFx API
call_ledfx_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local url="http://${LEDFX_HOST}:${LEDFX_PORT}${endpoint}"
  
  if [ -n "$data" ]; then
    wget -q -O- --method="$method" --header="Content-Type: application/json" \
      --body-data="$data" "$url" 2>/dev/null || true
  else
    wget -q -O- --method="$method" "$url" 2>/dev/null || true
  fi
}

# Get all virtual devices
get_virtuals() {
  call_ledfx_api "GET" "/api/virtuals"
}

# Play all virtuals (start visualization)
play_all() {
  log_entry "INFO" "Activating LedFx visualization..."
  # Get list of virtuals and activate each one
  # For now, just call the play endpoint
  call_ledfx_api "POST" "/api/audio/start" || true
  log_entry "INFO" "LedFx visualization activated"
}

# Pause all virtuals (stop visualization)
pause_all() {
  log_entry "INFO" "Deactivating LedFx visualization..."
  call_ledfx_api "POST" "/api/audio/stop" || true
  log_entry "INFO" "LedFx visualization deactivated"
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 1
fi

action="$1"
shift || true

case "$action" in
  start)
    if [ $# -gt 0 ]; then
      log_entry "START" "AirPlay session began - $*"
    else
      log_entry "START" "AirPlay session began"
    fi
    play_all
    ;;
  stop)
    if [ $# -gt 0 ]; then
      log_entry "STOP" "AirPlay session ended - $*"
    else
      log_entry "STOP" "AirPlay session ended"
    fi
    pause_all
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

