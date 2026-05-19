#!/bin/bash
# Bridge poller for Hermy (Hermes Agent) — dumb script, no LLM reasoning.
# Polls messages from the bridge addressed to "hermy", forwards to Telegram,
# acks (deletes) them after delivery. Designed to be run as a no_agent cron job.
#
# This script must NOT generate responses or store anything back in the bridge.
# If it needs to send a message to Bobby, use a separate mechanism (direct HTTP).
#
# Usage: bridge-poller-hermy.sh [--once] [--dry-run]
#   --once     : poll once and exit (for manual testing)
#   --dry-run  : log messages but don't send to Telegram

set -euo pipefail

# =============================================================================
# CONFIG
# =============================================================================
BRIDGE_URL="${BRIDGE_URL:-http://localhost:18473}"
AUTH_TOKEN_FILE="${AUTH_TOKEN_FILE:-/tmp/agent-bridge/auth_token}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN env required}"
TELEGRAM_API_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID env required}"
LOG_FILE="${LOG_FILE:-/home/ale/.hermes/logs/bridge-poller.log}"
LOCK_FILE="/tmp/bridge-poller-hermy.lock"
RATE_LIMIT_FILE="/tmp/bridge-poller-hermy-rate.json"
DRY_RUN="${BRIDGE_POLL_DRY_RUN:-}"
ONCE_MODE=""

# Parse args
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --once) ONCE_MODE=1 ;;
    esac
done

# Rate limit: minimum seconds between Telegram messages to avoid spam
RATE_LIMIT_SECONDS=30

# =============================================================================
# HELPERS
# =============================================================================

log() {
    local level="$1"; shift
    local msg="$*"
    local safe
    safe=$(printf '%s' "$msg" | sed 's/[[:cntrl:]]/_/g')
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$safe"
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$safe" >> "$LOG_FILE"
}

acquire_lock() {
    local lock_fd=200
    if ! exec 200>"$LOCK_FILE" 2>/dev/null; then
        log "WARN" "Cannot create lock file, exiting"
        exit 0
    fi
    if ! flock -n 200; then
        log "INFO" "Another instance running, exiting"
        exit 0
    fi
    printf '%s' "$$" >&200
    if ! flock -n 200; then
        log "INFO" "Lost lock, another instance running"
        exit 0
    fi
}

release_lock() {
    [[ -f "$LOCK_FILE" ]] && flock -n 200 && rm -f "$LOCK_FILE" 2>/dev/null || true
}

read_auth_token() {
    if [[ -f "$AUTH_TOKEN_FILE" ]]; then
        cat "$AUTH_TOKEN_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

get_rate_limit() {
    python3 -c "
import json, sys
try:
    with open('$RATE_LIMIT_FILE') as f:
        d = json.load(f)
    print(d.get('last_sent', 0))
except Exception:
    print(0)
" 2>/dev/null || echo "0"
}

set_rate_limit() {
    python3 -c "import json; json.dump({'last_sent': $(date +%s)}, open('$RATE_LIMIT_FILE', 'w'))" 2>/dev/null || true
}

# Escape Telegram MarkdownV2 special characters
escape_telegram() {
    local text="$1"
    text="${text//\\\\/\\\\\\\\}"
    local chars='_*[]()~`>#+-=|{}.!'
    local c
    for c in $chars; do
        text="${text//$c/\\$c}"
    done
    printf '%s' "$text"
}

# Send a formatted message to Telegram. Returns 0 on success, non-zero on failure.
send_telegram() {
    local sender="$1"
    local timestamp="$2"
    local text="$3"

    [[ -n "$DRY_RUN" ]] && {
        log "DRYRUN" "[$sender] $text"
        return 0
    }

    local escaped_sender escaped_timestamp escaped_text
    escaped_sender=$(escape_telegram "$sender")
    escaped_timestamp=$(escape_telegram "$timestamp")
    escaped_text=$(escape_telegram "$text")

    local payload
    payload=$(python3 -c "
import json, sys, subprocess, os

text = '*From:* ' + sys.argv[1] + '\n*Time:* ' + sys.argv[2] + '\n\n' + sys.argv[3]
payload = {
    'chat_id': os.environ['TELEGRAM_CHAT_ID'],
    'text': text,
    'parse_mode': 'MarkdownV2'
}
print(json.dumps(payload))
" "$escaped_sender" "$escaped_timestamp" "$escaped_text")

    local result exit_code
    result=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$TELEGRAM_API_URL" 2>&1)
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "curl failed: exit $exit_code"
        return 1
    fi

    local http_code="${result##*$'\n'}"
    local body="${result%$'\n'*}"

    if [[ "$http_code" == "200" ]]; then
        return 0
    else
        log "ERROR" "Telegram API HTTP $http_code: $body"
        return 1
    fi
}

# Validate a bridge message ID (UUID prefix: 8 hex chars)
valid_msg_id() {
    [[ "$1" =~ ^[a-f0-9]{8}$ ]]
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    chmod 755 "$(dirname "$LOG_FILE")"

    acquire_lock
    trap release_lock EXIT

    log "INFO" "=== Bridge poller started ==="

    local auth_token
    auth_token=$(read_auth_token)
    if [[ -z "$auth_token" ]]; then
        log "WARN" "No auth token found at $AUTH_TOKEN_FILE — bridge may not require auth yet"
        auth_token=""
    fi

    # Poll bridge for messages addressed to 'hermy'
    local curl_cmd=("curl" "-s" "-f")
    if [[ -n "$auth_token" ]]; then
        curl_cmd+=("-H" "x-agent-token: $auth_token")
    fi
    curl_cmd+=("${BRIDGE_URL}/messages?to=hermy")

    local response
    response=$("${curl_cmd[@]}" 2>&1) || {
        log "ERROR" "Bridge poll failed (exit $?)"
        return 1
    }

    # Empty or null = no messages
    if [[ -z "$response" ]] || [[ "$response" == "{}" ]] || [[ "$response" == '{"messages":[]}' ]]; then
        log "INFO" "No messages for hermy"
        return 0
    fi

    # Parse JSON response — extract messages
    local messages
    messages=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(1)
msgs = data.get('messages', [])
if not isinstance(msgs, list):
    print('', file=sys.stderr)
    sys.exit(1)
for m in msgs:
    if isinstance(m, dict) and m.get('to') == 'hermy' and m.get('text') and m.get('id'):
        print(json.dumps({'id': m['id'], 'from': m.get('from',''), 'time': m.get('time',''), 'text': m['text']}))
" 2>&1) || {
        log "ERROR" "Failed to parse bridge response"
        return 1
    }

    [[ -z "$messages" ]] && {
        log "INFO" "No valid messages for hermy after filtering"
        return 0
    }

    local msg_count
    msg_count=$(echo "$messages" | grep -c . || echo "0")
    log "INFO" "Found $msg_count message(s)"

    local sent=0 failed=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local msg_id sender timestamp text
        msg_id=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null) || continue
        sender=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['from'])" 2>/dev/null) || sender="unknown"
        timestamp=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['time'])" 2>/dev/null) || timestamp="unknown"
        text=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['text'])" 2>/dev/null) || continue

        [[ -z "$msg_id" || -z "$text" ]] && continue

        if ! valid_msg_id "$msg_id"; then
            log "WARN" "Invalid msg_id '$msg_id', skipping"
            continue
        fi

        # Rate limit check
        local last_sent now elapsed
        last_sent=$(get_rate_limit)
        now=$(date +%s)
        elapsed=$((now - last_sent))
        if [[ $elapsed -lt $RATE_LIMIT_SECONDS ]]; then
            log "INFO" "Rate limited (${elapsed}s < ${RATE_LIMIT_SECONDS}s), deferring $msg_id"
            continue
        fi

        # Send to Telegram
        if send_telegram "$sender" "$timestamp" "$text"; then
            set_rate_limit
            sent=$((sent + 1))

            # Ack (delete) message from bridge
            local delete_curl=("curl" "-s" "-f" "-X" "DELETE")
            if [[ -n "$auth_token" ]]; then
                delete_curl+=("-H" "x-agent-token: $auth_token")
            fi
            delete_curl+=("${BRIDGE_URL}/message/${msg_id}?by=hermy")

            local del_result del_exit
            del_result=$("${delete_curl[@]}" 2>&1)
            del_exit=$?
            if [[ $del_exit -eq 0 ]]; then
                log "INFO" "Acked message $msg_id"
            else
                log "WARN" "Failed to ack message $msg_id (curl $del_exit): $del_result"
            fi
        else
            failed=$((failed + 1))
            log "ERROR" "Telegram delivery failed for $msg_id, leaving in queue"
        fi
    done <<< "$messages"

    log "INFO" "Poll complete: $sent sent, $failed failed"

    # Exit if --once mode (for manual testing)
    [[ -n "$ONCE_MODE" ]] && exit 0
    return 0
}

main "$@"