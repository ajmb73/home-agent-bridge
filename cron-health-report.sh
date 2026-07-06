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
# cron-health-report.sh — Scan Hermes cron output directory for issues
# Produces a concise summary table of job health
# Usage: ./cron-health-report.sh [--json]
set -euo pipefail

CRON_OUTPUT_DIR="${HOME}/.hermes/cron/output"
REPORT=""
ISSUES=0
TOTAL_SIZE=0
TOTAL_FILES=0

echo "=== Cron Output Health Report — $(date '+%Y-%m-%d %H:%M') ==="
echo ""

# Header
printf "%-40s %-8s %-16s %-10s %s\n" "JOB" "FILES" "TOTAL SIZE" "STALE(>48h)" "OLDEST FILE"
printf "%-40s %-8s %-16s %-10s %s\n" "----------------------------------------" "--------" "----------------" "----------" "-----------------"

for job_dir in "$CRON_OUTPUT_DIR"/*/; do
    [ -d "$job_dir" ] || continue
    job_id=$(basename "$job_dir")
    
    # Count files and total size
    file_count=$(find "$job_dir" -type f 2>/dev/null | wc -l)
    total_size=$(du -sh "$job_dir" 2>/dev/null | cut -f1)
    total_bytes=$(du -sb "$job_dir" 2>/dev/null | cut -f1)
    TOTAL_SIZE=$((TOTAL_SIZE + (total_bytes)))
    TOTAL_FILES=$((TOTAL_FILES + file_count))
    
    # Count stale files (older than 48 hours)
    stale_count=$(find "$job_dir" -type f -mtime +2 2>/dev/null | wc -l)
    
    # Find oldest file
    oldest=$(find "$job_dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | awk '{print $2}' | xargs -I{} basename {} 2>/dev/null)
    oldest_date=$(find "$job_dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | awk '{print strftime("%Y-%m-%d", $1)}' 2>/dev/null)
    [ -z "$oldest_date" ] && oldest_date="-"
    
    # Check latest file for error keywords
    latest_file=$(find "$job_dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
    error_hint=""
    if [ -n "$latest_file" ] && [ -f "$latest_file" ]; then
        errors=$(head -20 "$latest_file" | grep -iE 'error|fail|critical|traceback|exception' 2>/dev/null | head -3 | tr '\n' '; ' | sed 's/; $//')
        if [ -n "$errors" ]; then
            error_hint="⚠ ERR"
            ISSUES=$((ISSUES + 1))
        fi
    fi
    
    # Flag large jobs
    if [ "$total_bytes" -gt 10485760 ] 2>/dev/null; then  # >10MB
        error_hint="${error_hint} ⚠ BIG"
        ISSUES=$((ISSUES + 1))
    fi
    
    # Flag stale-heavy jobs
    if [ "$stale_count" -gt 100 ]; then
        error_hint="${error_hint} ⚠ STALE"
        ISSUES=$((ISSUES + 1))
    fi
    
    printf "%-40s %-8s %-16s %-10s %s\n" "$job_id" "$file_count" "$total_size" "$stale_count" "$oldest_date"
    if [ -n "$error_hint" ]; then
        echo "  └─ ${error_hint}"
    fi
done

# Summary
TOTAL_SIZE_HR=$(numfmt --to=iec $TOTAL_SIZE 2>/dev/null || echo "${TOTAL_SIZE}B")
echo ""
echo "=== Summary ==="
echo "Total jobs:       $(find "$CRON_OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
echo "Total files:      $TOTAL_FILES"
echo "Total size:       $TOTAL_SIZE_HR"
echo "Issues flagged:   $ISSUES"

if [ "$ISSUES" -gt 0 ]; then
    echo ""
    echo "⚠ $ISSUES issue(s) found — see ⚠ markers above for details."
    exit 1
else
    echo ""
    echo "✓ All cron output directories look healthy."
    exit 0
fi
