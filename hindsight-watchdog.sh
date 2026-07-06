#!/bin/bash
# Hindsight daemon health check — silent when healthy, alerts when broken
HEALTH=$(curl -sf http://localhost:8888/health 2>&1)
if [ $? -ne 0 ] || ! echo "$HEALTH" | grep -q '"status":"healthy".*"database":"connected"'; then
  echo "⚠️ Hindsight daemon at localhost:8888 is UNHEALTHY or down"
  echo "Curl output: $HEALTH"
  exit 1
fi
exit 0
