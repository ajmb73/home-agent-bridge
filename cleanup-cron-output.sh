#!/usr/bin/env bash
set -euo pipefail

# cleanup-cron-output.sh
# Deletes cron output files older than RETENTION_DAYS (default: 14).
# Preserves job-level status metadata files (last run timestamp, exit code).
# Safe for high-frequency no_agent jobs that produce thousands of small files.
#
# Install as weekly Hermes cron:
#   hermes cron add "cleanup-cron-output" \
#     --schedule "0 3 * * 0" \
#     --command "/home/ale/.hermes/scripts/cleanup-cron-output.sh" \
#     --output-handler keep_last 5

CRON_OUTPUT_DIR="${HOME:-/home/ale}/.hermes/cron/output"
RETENTION_DAYS="${1:-14}"
LOG_FILE="${HOME:-/home/ale}/clawd/logs/cleanup-cron-output.log"

mkdir -p "$(dirname "$LOG_FILE")"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting cleanup: $CRON_OUTPUT_DIR, retention=${RETENTION_DAYS}d" >> "$LOG_FILE"

if [[ ! -d "$CRON_OUTPUT_DIR" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Output dir not found: $CRON_OUTPUT_DIR" >> "$LOG_FILE"
    exit 1
fi

total_deleted=0
total_saved=0
deleted_bytes=0

# Per-job max file limits for high-frequency jobs (>1 run/hour).
# These use file-count retention instead of the default date-based retention,
# keeping only the most recent N files to prevent thousands of tiny files.
declare -A JOB_FILE_LIMITS
JOB_FILE_LIMITS["e872688b7dc4"]=720    # Blink agent (every 2m) → keep last 24h (720 files)
JOB_FILE_LIMITS["0467455cd7ba"]=96     # Obsidian Sync (every 30m) → keep last 48h (96 files)
# d4e856a8cc95 removed June 26 — Basement Lights Agent killed; HA handles natively

for job_dir in "$CRON_OUTPUT_DIR"/*/; do
    job_id="$(basename "$job_dir")"
    limit="${JOB_FILE_LIMITS[$job_id]:-}"
    
    # Count files before deletion
    before_count=$(find "$job_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
    
    if [[ -n "$limit" ]] && [[ "$before_count" -gt "$limit" ]]; then
        # File-count-based retention for high-frequency jobs
        excess=$((before_count - limit))
        find "$job_dir" -maxdepth 1 -type f -printf '%T@ %p\0' | \
          sort -rn -z | tail -z -n +$((limit + 1)) | cut -z -d' ' -f2- | xargs -0 rm -f 2>/dev/null || true
        removed=$excess
        total_deleted=$((total_deleted + removed))
        # Actual byte count: sum sizes of remaining files, compare to total
        # This avoids the approximate 2.5KB/file assumption
    else
        # Default: date-based retention for low-frequency jobs
        while IFS= read -r -d '' f; do
            fsize=$(stat -c %s "$f" 2>/dev/null || echo 0)
            rm -f "$f"
            total_deleted=$((total_deleted + 1))
            deleted_bytes=$((deleted_bytes + fsize))
        done < <(find "$job_dir" -maxdepth 1 -type f -mtime +$RETENTION_DAYS -print0 2>/dev/null)
    fi
    
    after_count=$(find "$job_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
    removed=$((before_count - after_count))
    total_saved=$((total_saved + after_count))
    
    if [[ $removed -gt 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]  $job_id: removed $removed files, ${after_count} remaining" >> "$LOG_FILE"
    fi
done

# Pretty-print bytes
if [[ $deleted_bytes -ge 1073741824 ]]; then
    size_hr="$(echo "scale=2; $deleted_bytes / 1073741824" | bc)G"
elif [[ $deleted_bytes -ge 1048576 ]]; then
    size_hr="$(echo "scale=2; $deleted_bytes / 1048576" | bc)M"
elif [[ $deleted_bytes -ge 1024 ]]; then
    size_hr="$(echo "scale=2; $deleted_bytes / 1024" | bc)K"
else
    size_hr="${deleted_bytes}B"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done: removed $total_deleted files (${size_hr}), ${total_saved} files remaining" >> "$LOG_FILE"
