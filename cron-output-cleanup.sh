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
# Cron output cleanup — removes old output files by job frequency
# High-frequency jobs (every minute): keep 7 days
# Other jobs: keep 30 days

set -euo pipefail
CRON_OUTPUT="$HOME/.hermes/cron/output"
TODAY=$(date +%s)
REMOVED=0
REMOVED_BYTES=0

# Jobs that run every 1-5 minutes — keep 7 days
HIGH_FREQ_JOBS=("7e76820ab9f6" "02dd9d6878fc")

echo "[$(date)] Cron output cleanup starting..."

# Clean high-frequency jobs (7 day retention)
for job_id in "${HIGH_FREQ_JOBS[@]}"; do
    job_dir="$CRON_OUTPUT/$job_id"
    if [[ -d "$job_dir" ]]; then
        while IFS= read -r -d '' file; do
            file_time=$(stat -c %Y "$file" 2>/dev/null || echo 0)
            age_seconds=$((TODAY - file_time))
            if [[ $age_seconds -gt $((7 * 86400)) ]]; then
                size=$(stat -c %s "$file" 2>/dev/null || echo 0)
                rm -f "$file"
                REMOVED=$((REMOVED + 1))
                REMOVED_BYTES=$((REMOVED_BYTES + size))
            fi
        done < <(find "$job_dir" -type f -print0)
    fi
done

# Clean all other job output (30 day retention)
while IFS= read -r -d '' file; do
    job_id_from_path=$(echo "$file" | sed "s|$CRON_OUTPUT/||" | cut -d/ -f1)
    # Skip already-cleaned high-freq jobs
    skip=0
    for hj in "${HIGH_FREQ_JOBS[@]}"; do
        [[ "$job_id_from_path" == "$hj" ]] && skip=1 && break
    done
    [[ $skip -eq 1 ]] && continue

    file_time=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    age_seconds=$((TODAY - file_time))
    if [[ $age_seconds -gt $((30 * 86400)) ]]; then
        size=$(stat -c %s "$file" 2>/dev/null || echo 0)
        rm -f "$file"
        REMOVED=$((REMOVED + 1))
        REMOVED_BYTES=$((REMOVED_BYTES + size))
    fi
done < <(find "$CRON_OUTPUT" -type f -print0)

# Clean empty directories
find "$CRON_OUTPUT" -type d -empty -delete 2>/dev/null

REMOVED_MB=$((REMOVED_BYTES / 1048576))
REMAINING=$(find "$CRON_OUTPUT" -type f | wc -l)
REMAINING_SIZE=$(du -sh "$CRON_OUTPUT" 2>/dev/null | cut -f1)

echo "[$(date)] Cleanup done: removed $REMOVED files (${REMOVED_MB}MB), $REMAINING files remaining (${REMAINING_SIZE})"
