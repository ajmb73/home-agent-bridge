#!/bin/bash

# Cron runs with a minimal env (no HOME, no extended PATH). Set sane defaults,
# extend PATH for user-installed bins, and source Hermes .env so this script
# has the same API keys an interactive shell does. Idempotent — if .env is
# missing or vars are already set, nothing breaks.
export HOME="${HOME:-/home/ale}"
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
for d in /home/ale/.local/bin /home/ale/.hermes/hermes-agent/venv/bin /home/ale/.npm-global/bin; do
    [[ -d "$d" ]] && PATH="$d:$PATH"
done
export PATH

# Source Hermes .env — auto-export every var (set -a) so the script below
# doesn't need to know which keys exist. .env is chmod 600 (Ale-only).
if [[ -f "$HOME/.hermes/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$HOME/.hermes/.env"
    set +a
fi
# Bridge poller for Hermy (Hermes Agent) — dumb script, no LLM reasoning.
# Polls messages from the HTTP bridge addressed to "hermy", processes them,
# writes responses back to the bridge if needed, then acks.
#
# The bridge is a simple agent-to-agent queue. Messages go from Bobby → Hermy
# or Hermy → Bobby. Telegram is NOT involved — this is operational coordination
# between the two agents, not user-facing notifications.
#
# Usage: bridge-poller-hermy.sh [--once] [--dry-run]
#   --once    : poll once and exit (for manual testing)
#   --dry-run : log messages but don't ack

set -euo pipefail

# =============================================================================
# CONFIG
# =============================================================================
BRIDGE_URL="${BRIDGE_URL:-http://localhost:18473}"
AUTH_TOKEN_FILE="${AUTH_TOKEN_FILE:-/tmp/agent-bridge/auth_token}"
LOG_FILE="${LOG_FILE:-/home/ale/.hermes/logs/bridge-poller.log}"
LOCK_FILE="/tmp/bridge-poller-hermy.lock"

# Encryption key path for E2E queue encryption
export BRIDGE_ENCRYPTION_KEY_FILE="/home/ale/.hermes/bridge.key"
DRY_RUN=""
ONCE_MODE=""

# Parse args
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --once) ONCE_MODE=1 ;;
    esac
done

# =============================================================================
# HELPERS
# =============================================================================

log() {
    local level="$1"; shift
    local msg="$*"
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG_FILE"
}

acquire_lock() {
    local lock_fd=200
    if ! exec 200>"$LOCK_FILE" 2>/dev/null; then
        log "WARN" "Cannot create lock file"
        exit 0
    fi
    if ! flock -n 200; then
        log "INFO" "Another instance running"
        exit 0
    fi
    printf '%s' "$$" >&200
    if ! flock -n 200; then
        log "INFO" "Lost lock"
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
        log "WARN" "No auth token at $AUTH_TOKEN_FILE"
        auth_token=""
    fi

    # Build curl command
    local curl_cmd=("curl" "-s" "-f")
    if [[ -n "$auth_token" ]]; then
        curl_cmd+=("-H" "x-agent-token: $auth_token")
    fi
    curl_cmd+=("${BRIDGE_URL}/messages?for=hermy")

    # Poll bridge
    local response
    response=$("${curl_cmd[@]}" 2>&1) || {
        log "ERROR" "Bridge poll failed (exit $?)"
        return 1
    }

    # Empty = no messages
    if [[ -z "$response" ]] || [[ "$response" == "{}" ]] || [[ "$response" == '{"messages":[]}' ]]; then
        log "INFO" "No messages for hermy"
        return 0
    fi

    # Parse messages — extract id, from, text
    local messages
    messages=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data.get('messages', [])
for m in msgs:
    if isinstance(m, dict) and m.get('to') == 'hermy' and m.get('id'):
        print(json.dumps({
            'id': m['id'],
            'from': m.get('from', ''),
            'text': m.get('text', ''),
            'time': m.get('time', '')
        }))
" 2>&1) || {
        log "ERROR" "Failed to parse bridge response"
        return 1
    }

    [[ -z "$messages" ]] && {
        log "INFO" "No valid messages for hermy after filtering"
        return 0
    }

    local msg_count
    msg_count=$(echo "$messages" | wc -l)
    log "INFO" "Found $msg_count message(s)"

    # Process each message
    local acked=0 failed=0
    while IFS= read -r msg_line; do
        [[ -z "$msg_line" ]] && continue

        local id from text
        id=$(echo "$msg_line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
        from=$(echo "$msg_line" | python3 -c "import sys,json; print(json.load(sys.stdin)['from'])")
        text=$(echo "$msg_line" | python3 -c "import sys,json; print(json.load(sys.stdin)['text'])")

        log "INFO" "From=$from id=$id text=${text:0:80}"

        if [[ "$from" == "bobby" ]]; then
            local timestamp
            timestamp=$(date '+%Y-%m-%d %H:%M')

            # Write to bridge-inbox.md (cumulative record)
            local inbox_file="/home/ale/.hermes/bridge-inbox.md"
            if [[ ! -f "$inbox_file" ]] || ! grep -q "## 📨 Bridge Messages from Bobby" "$inbox_file" 2>/dev/null; then
                printf '\n## 📨 Bridge Messages from Bobby\n\n' >> "$inbox_file"
            fi
            printf -- '- **%s** — [bobby] %s\n' "$timestamp" "$text" >> "$inbox_file"

            # Write to daily memory (same pattern as Bobby's poller)
            local mem_file="/home/ale/.hermes/memory/$(date +%Y-%m-%d).md"
            mkdir -p "$(dirname "$mem_file")"
            if ! grep -q "## 📨 Bridge Messages from Bobby" "$mem_file" 2>/dev/null; then
                printf '\n## 📨 Bridge Messages from Bobby\n\n' >> "$mem_file"
            fi
            printf -- '- **%s** — %s\n' "$timestamp" "$text" >> "$mem_file"
        fi || true

        if [[ -z "$DRY_RUN" ]]; then
            local ack_resp
            ack_resp=$(curl -s -X POST "${BRIDGE_URL}/messages/ack" \
                -H "Content-Type: application/json" \
                ${auth_token:+-H "x-agent-token: $auth_token"} \
                -d "{\"ids\":[\"$id\"],\"by\":\"hermy\"}" 2>&1) && acked=$((acked+1)) || {
                log "ERROR" "Ack failed for $id"
                failed=$((failed+1))
            }
        else
            log "DRYRUN" "Would ack: $id"
            acked=$((acked+1))
        fi
    done <<< "$messages"

    log "INFO" "Poll complete: $acked acked, $failed failed"
    [[ -n "$ONCE_MODE" ]] && return 0
    [[ -n "$DRY_RUN" ]] && return 0
}

main "$@"
