#!/bin/bash
# Backup Uptime Kuma data via SSH to monitoring.home
set -euo pipefail
ssh monitoring.home "bash /opt/uptime-kuma/backup.sh" 2>&1
