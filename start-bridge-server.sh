#!/bin/bash
# Start bridge server for inter-agent communication
# Auto-registers callbacks from callbacks.json on startup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_SCRIPT="${SCRIPT_DIR}/agent-bridge-server.py"
PID_FILE="/tmp/bridge-server.pid"
LOG_FILE="/tmp/agent-bridge.log"

# Check if already running
check_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "Bridge server already running (PID: $pid)"
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    return 1
}

# Setup @reboot cron
setup_cron() {
    local cron_entry="@reboot /home/ale/.hermes/scripts/start-bridge-server.sh"

    if crontab -l 2>/dev/null | grep -q "start-bridge-server.sh"; then
        echo "Crontab entry already exists"
        return 0
    fi

    (crontab -l 2>/dev/null || true; echo "$cron_entry") | crontab -
    echo "Added crontab entry: $cron_entry"
}

main() {
    if check_running; then
        exit 0
    fi

    if [[ ! -f "$BRIDGE_SCRIPT" ]]; then
        echo "ERROR: Bridge script not found: $BRIDGE_SCRIPT"
        exit 1
    fi

    if [[ "${1:-}" == "--setup" ]]; then
        setup_cron
    fi

    echo "Starting bridge server..."
    python3 "$BRIDGE_SCRIPT" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 2

    # Verify it started
    if curl -sf http://localhost:18473/status > /dev/null 2>&1; then
        echo "Bridge server started (PID: $pid)"
    else
        echo "WARNING: Bridge server may have failed to start. Check $LOG_FILE"
    fi
}

main "$@"
