#!/bin/bash
# sessions-maintenance.sh — weekly prune + optimize of ~/.hermes state.db
#
# Called by the Hermes cron job "Sessions weekly maintenance" (Sunday 5am).
# Runs as a no_agent script — its stdout is delivered verbatim; empty stdout
# means "silent" and produces no user-visible notification (watchdog pattern).
#
# Operations:
#   1. hermes sessions prune --older-than 14 --yes   (delete ended sessions)
#   2. hermes sessions optimize                      (FTS5 merge + VACUUM)
#
# Logs pre/post sizes + timestamps to:
#   ~/.hermes/logs/sessions-maintenance.log
#
# Exit code: 0 on full success, non-zero if any step failed (so cron can
# surface the error to the operator via the delivery channel).

set -euo pipefail

# ── Tunables (env-overridable for testing) ───────────────────────────────
RETENTION_DAYS="${RETENTION_DAYS:-14}"
HERMES_HOME="${HERMES_HOME:-/home/ale/.hermes}"
LOG_FILE="${LOG_FILE:-${HERMES_HOME}/logs/sessions-maintenance.log}"
STATE_DB="${STATE_DB:-${HERMES_HOME}/state.db}"
SESSIONS_DIR="${SESSIONS_DIR:-${HERMES_HOME}/sessions}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

# ── Pre-state snapshot ──────────────────────────────────────────────────
state_db_before=0
if [ -f "$STATE_DB" ]; then
    state_db_before=$(stat -c '%s' "$STATE_DB" 2>/dev/null || echo 0)
fi
sessions_files_before=0
if [ -d "$SESSIONS_DIR" ]; then
    sessions_files_before=$(find "$SESSIONS_DIR" -type f 2>/dev/null | wc -l)
    sessions_bytes_before=$(du -sb "$SESSIONS_DIR" 2>/dev/null | awk '{print $1}')
else
    sessions_bytes_before=0
fi

log "START retention=${RETENTION_DAYS}d state.db=${state_db_before}B sessions_files=${sessions_files_before}"

# ── 1. Prune ended sessions older than retention window ─────────────────
# --yes skips the interactive confirm; the CLI passes sessions_dir to
# prune_sessions() internally, so .jsonl files for pruned sessions are
# also removed (issue #3015).
if ! prune_output=$(/home/ale/.local/bin/hermes sessions prune --older-than "$RETENTION_DAYS" --yes 2>&1); then
    log "ERROR: prune failed: ${prune_output}"
    echo "Sessions maintenance FAILED at prune step — see ${LOG_FILE}"
    exit 1
fi
log "prune: ${prune_output}"

# ── 2. Optimize (FTS5 merge + VACUUM) ──────────────────────────────────
if ! opt_output=$(/home/ale/.local/bin/hermes sessions optimize 2>&1); then
    log "ERROR: optimize failed: ${opt_output}"
    echo "Sessions maintenance FAILED at optimize step — see ${LOG_FILE}"
    exit 1
fi
log "optimize: ${opt_output}"

# ── Post-state snapshot + summary ──────────────────────────────────────
state_db_after=$(stat -c '%s' "$STATE_DB" 2>/dev/null || echo 0)
sessions_files_after=0
sessions_bytes_after=0
if [ -d "$SESSIONS_DIR" ]; then
    sessions_files_after=$(find "$SESSIONS_DIR" -type f 2>/dev/null | wc -l)
    sessions_bytes_after=$(du -sb "$SESSIONS_DIR" 2>/dev/null | awk '{print $1}')
fi

db_delta=$((state_db_before - state_db_after))
files_delta=$((sessions_files_before - sessions_files_after))
bytes_delta=$((sessions_bytes_before - sessions_bytes_after))

db_human_before=$(numfmt --to=iec "$state_db_before" 2>/dev/null || echo "${state_db_before}B")
db_human_after=$(numfmt --to=iec "$state_db_after" 2>/dev/null || echo "${state_db_after}B")
db_human_delta=$(numfmt --to=iec "${db_delta#-}" 2>/dev/null || echo "${db_delta}B")
files_human_delta=$(numfmt --to=iec "${bytes_delta#-}" 2>/dev/null || echo "${bytes_delta}B")

log "DONE state.db: ${db_human_before} -> ${db_human_after} (saved ${db_human_delta}); sessions/: ${sessions_files_before}->${sessions_files_after} files (saved ${files_human_delta})"

# ── Stdout for cron delivery ────────────────────────────────────────────
# Empty stdout on a normal run = silent (no user spam every Sunday at 5am).
# Only emit a line if something interesting happened (prune reclaimed rows
# or DB shrank materially) or if a hard error needs attention. The
# non-empty echo above is the failure path; the success path stays quiet.

# Heuristic: if either DB shrank by >=1MB or >=50 files were pruned, send a
# one-line summary so the user knows the cleanup is working.
if [ "$db_delta" -ge 1048576 ] || [ "$files_delta" -ge 50 ]; then
    echo "Sessions maintenance: ${prune_output}; DB ${db_human_before}->${db_human_after} (saved ${db_human_delta}), sessions/ freed ${files_human_delta}."
fi
# otherwise: silent — empty stdout = no notification (watchdog pattern)
