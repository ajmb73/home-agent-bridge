#!/bin/bash
# Start callback server for instant message delivery
# Adds @reboot crontab entry on first run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLBACK_SCRIPT="${SCRIPT_DIR}/callback-server.py"
PID_FILE="/tmp/callback-server.pid"
LOG_FILE="/home/ale/.hermes/logs/callback-server.log"

# Load env vars for Telegram (only known-safe vars, no blanket source)
if [[ -f /home/ale/.hermes/.env ]]; then
    while IFS='=' read -r key val; do
        # Only export known-safe Telegram variables
        [[ "$key" =~ ^[A-Z_]+$ ]] || continue
        case "$key" in
            TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID|TELEGRAM_HOME_CHANNEL|TELEGRAM_ALLOWED_CHATS|TELEGRAM_REACTIONS)
                export "$key"="$val"
                ;;
        esac
    done < /home/ale/.hermes/.env
fi

# Check if already running
check_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "Callback server already running (PID: $pid)"
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    return 1
}

# Add to crontab if not already there
setup_cron() {
    local cron_entry="@reboot /home/ale/.hermes/scripts/start-callback-server.sh"

    # Check if already in crontab
    if crontab -l 2>/dev/null | grep -q "start-callback-server.sh"; then
        echo "Crontab entry already exists"
        return 0
    fi

    # Add cron entry
    (crontab -l 2>/dev/null || true; echo "$cron_entry") | crontab -
    echo "Added crontab entry: $cron_entry"
}

# Main
main() {
    if check_running; then
        exit 0
    fi

    if [[ ! -f "$CALLBACK_SCRIPT" ]]; then
        echo "ERROR: Callback script not found: $CALLBACK_SCRIPT"
        exit 1
    fi

    # Setup cron if --setup flag passed
    if [[ "${1:-}" == "--setup" ]]; then
        setup_cron
    fi

    # Start callback server in background
    echo "Starting callback server..."
    python3 "$CALLBACK_SCRIPT" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 1

    # Auto-register with bridge (if bridge is up)
    if curl -sf http://localhost:18473/status > /dev/null 2>&1; then
        curl -sf -X POST http://localhost:18473/callback \
            -H "Content-Type: application/json" \
            -d '{"agent": "hermy", "url": "http://localhost:18474/notify"}' \
            > /dev/null 2>&1 && echo "Callback registered with bridge" || echo "Callback registration failed (bridge may be down)"
    else
        echo "Bridge not running - callback will be registered when bridge starts"
    fi

    echo "Callback server started (PID: $pid)"
}

main "$@"
