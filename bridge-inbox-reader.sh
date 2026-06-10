#!/bin/bash
# Hermy bridge inbox reader — checks for pending Bobby messages and brings them
# to my attention by writing to a file checked at conversation start.
# Runs every 15 minutes via cron.

set -euo pipefail

export HOME="${HOME:-/home/ale}"
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
for d in /home/ale/.local/bin /home/ale/.hermes/hermes-agent/venv/bin /home/ale/.npm-global/bin; do
    [[ -d "$d" ]] && PATH="$d:$PATH"
done
export PATH

if [[ -f "$HOME/.hermes/.env" ]]; then
    set -a
    . "$HOME/.hermes/.env"
    set +a
fi

BRIDGE_URL="http://localhost:18473"
AUTH_TOKEN_FILE="/tmp/agent-bridge/auth_token"
INBOX_FILE="${HOME}/.hermes/bridge-inbox.md"
PENDING_FILE="${HOME}/.hermes/.bridge-pending"
LOG="${HOME}/.hermes/logs/bridge-inbox-reader.log"

mkdir -p "$(dirname "$LOG")"

# Check if there are pending messages for hermy still on the bridge
AUTH_TOKEN="$(cat "$AUTH_TOKEN_FILE" 2>/dev/null || echo '')"
if [[ -z "$AUTH_TOKEN" ]]; then
    echo "$(date): No auth token" >> "$LOG"
    exit 1
fi

RESPONSE="$(curl -s "${BRIDGE_URL}/messages?for=hermy" \
    -H "X-Agent-Token: ${AUTH_TOKEN}" 2>/dev/null)"

COUNT=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    msgs = [m for m in d.get('messages',[]) if m.get('from') == 'bobby']
    print(len(msgs))
except:
    print('0')
" 2>/dev/null || echo "0")

if [[ "$COUNT" == "0" ]]; then
    rm -f "$PENDING_FILE"
    echo "$(date): No pending messages from Bobby" >> "$LOG"
    exit 0
fi

echo "$(date): $COUNT pending message(s) from Bobby on bridge" >> "$LOG"
date +%s > "$PENDING_FILE"
echo "$(date): Set pending flag" >> "$LOG"
