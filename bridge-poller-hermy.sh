#!/bin/bash
# Bridge poller for Hermy (Hermes Agent)
# Polls messages addressed to "hermy" from the bridge and forwards to Telegram
# Created: 2026-05-13

set -euo pipefail

# Configuration
# NOTE: Telegram bot token is shared across agents per openclaw-admin skill
# In production, these should come from environment variables
BRIDGE_URL="${BRIDGE_URL:-http://localhost:18473}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN environment variable required}"
TELEGRAM_API_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID environment variable required}"
LOG_FILE="/home/ale/.hermes/logs/bridge-poller.log"
LOCK_FILE="/tmp/bridge-poller-hermy.lock"
RATE_LIMIT_FILE="/tmp/bridge-poller-hermy-rate.json"

# Rate limit: minimum seconds between Telegram messages
RATE_LIMIT_SECONDS=30

# Logging function
log() {
    local level="$1"
    shift
    local msg="$*"
    local safe_msg
    safe_msg=$(printf '%s' "$msg" | sed 's/[[:cntrl:]]/_/g')
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$safe_msg" >> "$LOG_FILE"
    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$safe_msg"
}

acquire_lock() {
    local lock_fd=200
    if ! exec 200>"$LOCK_FILE" 2>/dev/null; then
        log "WARN" "Cannot create lock file, exiting"
        exit 0
    fi
    
    if ! flock -n 200; then
        log "INFO" "Another instance is running, exiting"
        exit 0
    fi
    
    printf '%s' "$$" >&200
    
    if ! flock -n 200; then
        log "INFO" "Lost lock, another instance running"
        exit 0
    fi
}

release_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$$" ]]; then
            flock -n 200 && rm -f "$LOCK_FILE" 2>/dev/null || true
        fi
    fi
}

check_rate_limit() {
    if [[ ! -f "$RATE_LIMIT_FILE" ]]; then
        return 0
    fi
    
    local last_sent=0
    last_sent=$(python3 -c "
import json
try:
    with open('$RATE_LIMIT_FILE') as f:
        data = json.load(f)
        print(data.get('last_sent', 0))
except Exception:
    print(0)
" 2>/dev/null) || last_sent=0
    
    local now
    now=$(date +%s)
    local elapsed=$((now - last_sent))
    
    if [[ $elapsed -lt $RATE_LIMIT_SECONDS ]]; then
        log "DEBUG" "Rate limited: ${elapsed}s since last message (min: ${RATE_LIMIT_SECONDS}s)"
        return 1
    fi
    return 0
}

update_rate_limit() {
    if ! python3 -c "import json; json.dump({'last_sent': $(date +%s)}, open('$RATE_LIMIT_FILE', 'w'))"; then
        log "WARN" "Failed to update rate limit file"
        return 1
    fi
    return 0
}

send_to_telegram() {
    local sender="$1"
    local timestamp="$2"
    local text="$3"
    
    local formatted_msg="📩 *From:* ${sender}
🕐 *Time:* ${timestamp}

${text}"
    
    # Pass via temp file to avoid command injection
    local payload_file
    payload_file=$(mktemp -p /tmp bridge-poll-XXXXXX.json)
    chmod 600 "$payload_file"
    
    python3 - "$formatted_msg" "$TELEGRAM_CHAT_ID" "$TELEGRAM_API_URL" <<'PYEOF'
import json
import sys
import subprocess

text = sys.argv[1]
chat_id = sys.argv[2]
api_url = sys.argv[3]

# Escape for Telegram MarkdownV2 - must escape backslash FIRST
text = text.replace('\\', '\\\\')

escape_chars = ["_", "*", "[", "]", "(", ")", "~", "`", ">", "#", "+", "-", "=", "|", "{", "}", ".", "!"]
for char in escape_chars:
    text = text.replace(char, "\\" + char)

payload = {
    "chat_id": chat_id,
    "text": text,
    "parse_mode": "MarkdownV2"
}

result = subprocess.run(
    ["curl", "-s", "-w", "\n%{http_code}", "-X", "POST", api_url,
     "-H", "Content-Type: application/json",
     "-d", json.dumps(payload)],
    capture_output=True, text=True
)

output = result.stdout
http_code = output.strip().split("\n")[-1]
body = "\n".join(output.strip().split("\n")[:-1])

if http_code == "200":
    print("SUCCESS")
else:
    print(f"FAIL: HTTP {http_code} - {body}", file=sys.stderr)
    sys.exit(1)
PYEOF
    
    rm -f "$payload_file"
    return $?
}

# Sanitize msg_id to prevent command injection
sanitize_msg_id() {
    local msg_id="$1"
    # msg_id from bridge is UUID prefix (8 hex chars), validate and sanitize
    if [[ "$msg_id" =~ ^[a-f0-9]{8}$ ]]; then
        printf '%s' "$msg_id"
    else
        printf 'INVALID'
    fi
}

poll_bridge() {
    log "INFO" "Polling bridge for messages to hermy..."
    
    local response
    response=$(curl -s -f "${BRIDGE_URL}/messages?to=hermy" 2>&1)
    local curl_exit=$?
    
    if [[ $curl_exit -ne 0 ]]; then
        log "ERROR" "Bridge poll failed: curl exit code ${curl_exit}"
        return 1
    fi
    
    if [[ -z "$response" ]] || [[ "$response" == "{}" ]]; then
        log "INFO" "No messages in queue"
        return 0
    fi
    
    local messages
    messages=$(echo "$response" | python3 -c "
import sys, json

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as e:
    sys.stderr.write(f'JSON parse error: {e}\n')
    sys.exit(1)

if not isinstance(data, dict):
    sys.stderr.write('Invalid response format\n')
    sys.exit(1)

msgs = data.get('messages', [])
if not isinstance(msgs, list):
    sys.stderr.write('messages field is not a list\n')
    sys.exit(1)

filtered = []
for m in msgs:
    if not isinstance(m, dict):
        continue
    if m.get('to') != 'hermy':
        continue
    if not m.get('text'):
        continue
    if not m.get('id'):
        continue
    filtered.append(m)

print(json.dumps(filtered))
" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Message parsing failed"
        return 1
    fi
    
    if [[ -z "$messages" ]] || [[ "$messages" == "[]" ]]; then
        log "INFO" "No messages for hermy"
        return 0
    fi
    
    local msg_count
    msg_count=$(echo "$messages" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
    log "INFO" "Found ${msg_count} message(s)"
    
    local total_sent=0
    local total_failed=0
    
    while IFS= read -r msg_line; do
        [[ -z "$msg_line" ]] && continue
        
        local msg_id sender timestamp text
        msg_id=$(echo "$msg_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id','') or '')" 2>/dev/null) || continue
        sender=$(echo "$msg_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('from','unknown') or 'unknown')" 2>/dev/null) || sender="unknown"
        timestamp=$(echo "$msg_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('time','unknown') or 'unknown')" 2>/dev/null) || timestamp="unknown"
        text=$(echo "$msg_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('text','') or '')" 2>/dev/null) || continue
        
        if [[ -z "$msg_id" ]] || [[ -z "$text" ]]; then
            log "WARN" "Skipping message with missing id or text"
            continue
        fi
        
        # Sanitize msg_id before using in URL
        msg_id=$(sanitize_msg_id "$msg_id")
        if [[ "$msg_id" == "INVALID" ]]; then
            log "WARN" "Invalid msg_id format, skipping"
            continue
        fi
        
        if ! check_rate_limit; then
            log "INFO" "Rate limited, deferring message ${msg_id}"
            continue
        fi
        
        if send_to_telegram "$sender" "$timestamp" "$text"; then
            update_rate_limit || log "WARN" "Rate limit update failed"
            total_sent=$((total_sent + 1))
            
            local delete_exit
            curl -s -f -X DELETE "${BRIDGE_URL}/message/${msg_id}?by=hermy" > /dev/null 2>&1
            delete_exit=$?
            
            if [[ $delete_exit -eq 0 ]]; then
                log "INFO" "Deleted message ${msg_id} from bridge"
            else
                log "WARN" "Failed to delete message ${msg_id} from bridge (exit ${delete_exit})"
            fi
        else
            total_failed=$((total_failed + 1))
            log "ERROR" "Telegram delivery failed for message ${msg_id}, leaving in queue"
        fi
    done < <(echo "$messages" | python3 -c 'import json,sys; [print(json.dumps(m)) for m in json.load(sys.stdin)]' 2>/dev/null)
    
    log "INFO" "Poll complete: ${total_sent} sent, ${total_failed} failed"
    return 0
}

main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    chmod 700 "$(dirname "$LOG_FILE")"
    
    acquire_lock
    trap release_lock EXIT
    
    log "INFO" "=== Bridge poller started ==="
    poll_bridge
    log "INFO" "=== Bridge poller finished ==="
}

main "$@"