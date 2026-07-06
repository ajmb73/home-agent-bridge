#!/bin/bash
# Dashboard Watchdog — checks Hermes Dashboard health on port 9118 (jax.home)
# Silent when healthy, alerts when down or unreachable
# Designed for cron with no_agent=true watchdog pattern

DASHBOARD_URL="http://localhost:9118/"
MAX_RESPONSE_TIME=5  # seconds
LOG_FILE="/tmp/hermes-dashboard-watchdog.log"

# Check server is reachable and responding (any HTTP response = alive)
response_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$MAX_RESPONSE_TIME" "$DASHBOARD_URL" 2>/dev/null)
curl_exit=$?

if [ "$curl_exit" -ne 0 ]; then
  # curl exit != 0 means no connection at all — server is DOWN
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Dashboard UNREACHABLE — curl exit: $curl_exit, HTTP: $response_code" >> "$LOG_FILE"
  echo "⚠️ Hermes Dashboard at jax.home:9118 is DOWN (curl exit=$curl_exit, HTTP=$response_code)"
  exit 1
fi

# Any HTTP response (even 3xx redirect to login) means server is alive
exit 0
