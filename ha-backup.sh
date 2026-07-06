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
# HA config backup script - runs on ai.home, backs up HA config via SSH
set -euo pipefail

HA_HOST="192.168.0.71"
NAS_MOUNT="/mnt/nas_share/SMB Share/HA-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="ha_config_${TIMESTAMP}.tar.gz"
RETENTION_DAYS=30

echo "[$(date)] Starting HA backup..."

# 1. Create backup on HA Pi (exclude DB for size, include config/custom_components/automations)
ssh -o StrictHostKeyChecking=no root@${HA_HOST} \
  "tar czf /tmp/${BACKUP_NAME} \
    -C /config \
    --exclude='home-assistant_v2.db' \
    --exclude='home-assistant_v2.db-shm' \
    --exclude='home-assistant_v2.db-wal' \
    --exclude='home-assistant.log*' \
    --exclude='*.tar' \
    ." 2>&1

# 2. Copy backup to ai.home
scp -o StrictHostKeyChecking=no root@${HA_HOST}:/tmp/${BACKUP_NAME} /tmp/${BACKUP_NAME}

# 3. Copy to NAS if mounted
if mountpoint -q /mnt/nas_share; then
  mkdir -p "${NAS_MOUNT}"
  cp /tmp/${BACKUP_NAME} "${NAS_MOUNT}/${BACKUP_NAME}"
  echo "[$(date)] Backup stored on NAS: ${NAS_MOUNT}/${BACKUP_NAME}"
  
  # 4. Clean old backups on NAS (keep 30 days)
  find "${NAS_MOUNT}" -name 'ha_config_*.tar.gz' -mtime +${RETENTION_DAYS} -delete
else
  echo "[$(date)] WARNING: NAS not mounted, backup only on ai.home: /tmp/${BACKUP_NAME}"
fi

# 5. Report size before cleanup
BACKUP_SIZE=$(du -h /tmp/${BACKUP_NAME} 2>/dev/null | cut -f1 || echo 'unknown')
echo "[$(date)] HA backup complete: ${BACKUP_NAME} (${BACKUP_SIZE})"

# 6. Clean up temp files on both hosts
rm -f /tmp/${BACKUP_NAME}
ssh -o StrictHostKeyChecking=no root@${HA_HOST} "rm -f /tmp/${BACKUP_NAME}"
echo "DONE"
