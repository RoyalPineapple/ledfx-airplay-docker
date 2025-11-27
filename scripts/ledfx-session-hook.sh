#!/bin/sh
# LedFx session hook - invoked by Shairport-Sync on AirPlay session changes
# Calls ledfx-start.sh or ledfx-stop.sh based on AirPlay state
# Checks YAML config to determine if hooks are enabled

set -eu

# Check if hooks are enabled from YAML config
check_hook_enabled() {
  local hook_type="$1"  # "start" or "end"
  
  # Try YAML first
  if [ -f /configs/ledfx-hooks.yaml ]; then
    if [ "$hook_type" = "start" ]; then
      enabled=$(yq eval '.hooks.start_enabled // true' /configs/ledfx-hooks.yaml 2>/dev/null || echo "true")
    else
      enabled=$(yq eval '.hooks.end_enabled // true' /configs/ledfx-hooks.yaml 2>/dev/null || echo "true")
    fi
    
    # yq returns "true" or "false" as strings, convert to exit code
    if [ "$enabled" = "true" ]; then
      return 0
    else
      return 1
    fi
  fi
  
  # Default to enabled if YAML doesn't exist
  return 0
}

# Configuration - load from config file if available
if [ -f /configs/ledfx-hooks.conf ]; then
  . /configs/ledfx-hooks.conf
fi

# Allow override via environment variables
VIRTUAL_IDS="${LEDFX_VIRTUAL_IDS:-${VIRTUAL_IDS:-}}"
LEDFX_HOST="${LEDFX_HOST:-localhost}"
LEDFX_PORT="${LEDFX_PORT:-8888}"
LOG_FILE="${LEDFX_HOOK_LOG:-/var/log/shairport-sync/ledfx-session-hook.log}"

usage() {
  cat <<'EOF'
Usage: ledfx-session-hook.sh <start|stop|log> [message]

Controls LedFx visualization based on AirPlay session state.
- start: Calls ledfx-start.sh to activate virtual
- stop: Calls ledfx-stop.sh to pause and deactivate virtual
- log: Logs the event (for play_begins/play_ends callbacks)

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
    
    # Check if start hook is enabled
    if ! check_hook_enabled "start"; then
      log_entry "INFO" "Start hook is disabled in configuration, skipping"
      exit 0
    fi
    
    log_entry "INFO" "Calling ledfx-start.sh for virtual(s) ${VIRTUAL_IDS}"
    /scripts/ledfx-start.sh "${VIRTUAL_IDS}" "${LEDFX_HOST}" "${LEDFX_PORT}" || {
      log_entry "ERROR" "Failed to start LedFx"
      exit 1
    }
    log_entry "INFO" "LedFx started successfully"
    ;;
  stop)
    if [ $# -gt 0 ]; then
      log_entry "STOP" "AirPlay session ended - $*"
    else
      log_entry "STOP" "AirPlay session ended"
    fi
    
    # Check if end hook is enabled
    if ! check_hook_enabled "end"; then
      log_entry "INFO" "End hook is disabled in configuration, skipping"
      exit 0
    fi
    
    log_entry "INFO" "Calling ledfx-stop.sh for virtual(s) ${VIRTUAL_IDS}"
    /scripts/ledfx-stop.sh "${VIRTUAL_IDS}" "${LEDFX_HOST}" "${LEDFX_PORT}" || {
      log_entry "ERROR" "Failed to stop LedFx"
      exit 1
    }
    log_entry "INFO" "LedFx stopped successfully"
    ;;
  log)
    # Log-only action for play_begins/play_ends callbacks
    if [ $# -gt 0 ]; then
      log_entry "LOG" "Playback event: $*"
    else
      log_entry "LOG" "Playback event"
    fi
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

