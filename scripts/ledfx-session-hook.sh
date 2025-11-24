#!/bin/sh
# LedFx session hook - invoked by Shairport-Sync on AirPlay session changes
# Calls ledfx-start.sh or ledfx-stop.sh based on AirPlay state

set -eu

# Configuration - load from config file if available
if [ -f /configs/ledfx-hooks.conf ]; then
  . /configs/ledfx-hooks.conf
fi

# Allow override via environment variables
VIRTUAL_IDS="${LEDFX_VIRTUAL_IDS:-${VIRTUAL_IDS:-dig-quad}}"
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

