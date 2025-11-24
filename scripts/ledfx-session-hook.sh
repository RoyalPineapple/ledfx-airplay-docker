#!/bin/sh
# LedFx session hook - invoked by Shairport-Sync on AirPlay session changes
# Calls ledfx-start.sh or ledfx-stop.sh based on AirPlay state

set -eu

# Configuration
VIRTUAL_ID="${LEDFX_VIRTUAL_ID:-dig-quad}"
LEDFX_HOST="${LEDFX_HOST:-localhost}"
LEDFX_PORT="${LEDFX_PORT:-8888}"
LOG_FILE="${LEDFX_HOOK_LOG:-/var/log/shairport-sync/ledfx-session-hook.log}"

usage() {
  cat <<'EOF'
Usage: ledfx-session-hook.sh <start|stop> [message]

Controls LedFx visualization based on AirPlay session state.
- start: Calls ledfx-start.sh to activate virtual
- stop: Calls ledfx-stop.sh to pause and deactivate virtual

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
    log_entry "INFO" "Calling ledfx-start.sh for virtual ${VIRTUAL_ID}"
    /scripts/ledfx-start.sh "${VIRTUAL_ID}" "${LEDFX_HOST}" "${LEDFX_PORT}" || {
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
    log_entry "INFO" "Calling ledfx-stop.sh for virtual ${VIRTUAL_ID}"
    /scripts/ledfx-stop.sh "${VIRTUAL_ID}" "${LEDFX_HOST}" "${LEDFX_PORT}" || {
      log_entry "ERROR" "Failed to stop LedFx"
      exit 1
    }
    log_entry "INFO" "LedFx stopped successfully"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

