#!/usr/bin/env bash

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
# grimmory-health.sh — Check Grimmory container health and auto-restart if down
# Runs via Hermes cron every 5 minutes
set -euo pipefail

GRIMMORY_URL="http://books.home:6060"
LOG="$HOME/.hermes/logs/grimmory-health.log"
LOCK="$HOME/.hermes/.run/grimmory-health.lock"

# Prevent concurrent runs
[[ -f "$LOCK" ]] && exit 0
trap 'rm -rf "$LOCK"' EXIT
mkdir "$LOCK" 2>/dev/null || exit 0

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Check if Grimmory is responsive
if curl -sf -m 10 "$GRIMMORY_URL" >/dev/null 2>&1; then
    exit 0
fi

log "WARNING: Grimmory not responding at $GRIMMORY_URL — attempting restart..."

# Restart the container via Proxmox
if ssh root@192.168.0.53 "pct status 105" 2>/dev/null | grep -q "running"; then
    ssh root@192.168.0.53 "pct stop 105 --skiplock" 2>/dev/null || true
    sleep 3
    ssh root@192.168.0.53 "pct start 105" 2>/dev/null || true
    sleep 5

    # Verify recovery
    if curl -sf -m 10 "$GRIMMORY_URL" >/dev/null 2>&1; then
        log "SUCCESS: Grimmory restarted and responding."
    else
        log "FAILED: Grimmory still not responding after restart."
    fi
else
    log "Container 105 not running on pve1 — attempting start..."
    ssh root@192.168.0.53 "pct start 105" 2>/dev/null || true
    sleep 5
    if curl -sf -m 10 "$GRIMMORY_URL" >/dev/null 2>&1; then
        log "SUCCESS: Container 105 started and responding."
    else
        log "FAILED: Container 105 still not responding after start."
    fi
fi
