#!/usr/bin/env bash
# Common functions for Airglow diagnostic scripts
# This file is sourced by individual component diagnostic scripts

# Plain text output functions
check_ok() {
    echo "[OK] $1"
}

check_fail() {
    echo "[ERROR] $1"
}

check_warn() {
    echo "[WARN] $1"
}

section() {
    echo
    echo "─────────────────────────────────────────────────────────────"
    echo "  $1"
    echo "─────────────────────────────────────────────────────────────"
}

# Initialize diagnostic environment
# This should be called by the main diagnose-airglow.sh script
# Individual component scripts will inherit these variables
diagnose_init() {
    # Parse arguments
    TARGET_HOST="${1:-}"
    LEDFX_PORT="${LEDFX_PORT:-8888}"

    # If target host specified and it's not "localhost", use SSH; otherwise run locally
    if [ -n "$TARGET_HOST" ] && [ "$TARGET_HOST" != "localhost" ]; then
        SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=5 root@${TARGET_HOST}"
        # When checking remote host, API calls are made from local machine
        LEDFX_HOST="${TARGET_HOST}"
        REMOTE=true
    else
        SSH_CMD=""
        # When running locally, API is at localhost
        LEDFX_HOST="${LEDFX_HOST:-localhost}"
        REMOTE=false
    fi

    LEDFX_URL="http://${LEDFX_HOST}:${LEDFX_PORT}"

    # Export for use by component scripts
    export TARGET_HOST LEDFX_PORT SSH_CMD LEDFX_HOST REMOTE LEDFX_URL
}

# Function to run commands (local or remote)
run_cmd() {
    if [ "${REMOTE:-false}" = true ]; then
        $SSH_CMD "$1"
    else
        eval "$1"
    fi
}

# Function to run docker commands
docker_cmd() {
    if [ "${REMOTE:-false}" = true ]; then
        $SSH_CMD "docker $*"
    else
        docker "$@"
    fi
}

