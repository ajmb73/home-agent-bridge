#!/bin/bash
# Rotate processed message logs — archives old entries from processed.jsonl
# Keeps processed.jsonl lean, stores history in dated archive files

set -e
umask 077

# Allow env var overrides for testing
ARCHIVE_DIR="${ARCHIVE_DIR:-/home/ale/.hermes/logs/bridge-archives}"
PROCESSED_FILE="${PROCESSED_FILE:-/tmp/agent-bridge/processed.jsonl}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"
MAX_ARCHIVE_DAYS="${MAX_ARCHIVE_DAYS:-30}"
LOG_FILE="${LOG_FILE:-/home/ale/.hermes/logs/bridge-rotate.log}"

mkdir -p "$ARCHIVE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Use private temp directory (avoids /tmp world-readable issue)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

if [ -f "$PROCESSED_FILE" ] && [ -s "$PROCESSED_FILE" ]; then
    cutoff=$(date -d "$MAX_AGE_DAYS days ago" +%s 2>/dev/null)
    if [ -z "$cutoff" ]; then
        log "ERROR: failed to compute cutoff date"
        exit 1
    fi

    temp_archive="$WORK_DIR/archive.jsonl"
    remaining="$WORK_DIR/remaining.jsonl"
    archived=0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        ts=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('processed_at',''))" 2>/dev/null)
        if [ -n "$ts" ]; then
            ts_epoch=$(date -d "$ts" +%s 2>/dev/null)
            if [ -n "$ts_epoch" ] && [ "$ts_epoch" -lt "$cutoff" ]; then
                echo "$line" >> "$temp_archive"
                archived=$((archived + 1))
            else
                echo "$line" >> "$remaining"
            fi
        else
            # Preserve malformed lines rather than dropping silently
            echo "$line" >> "$remaining"
        fi
    done < "$PROCESSED_FILE"

    if [ $archived -gt 0 ]; then
        # Atomic: write archive to temp dir, then rename into place
        archive_basename="processed-$(date +%Y%m%d).jsonl.gz"
        archive_tmp="$WORK_DIR/$archive_basename"
        gzip > "$archive_tmp"
        mv "$archive_tmp" "$ARCHIVE_DIR/$archive_basename"
        # Atomic: replace processed.jsonl
        mv "$remaining" "$PROCESSED_FILE"
        log "Archived $archived entries to $ARCHIVE_DIR/$archive_basename"
    fi
fi

# Clean up archives older than MAX_ARCHIVE_DAYS (log errors, don't silence)
find "$ARCHIVE_DIR" -name "processed-*.jsonl.gz" -mtime +$MAX_ARCHIVE_DAYS -delete 2>> "$LOG_FILE" || true