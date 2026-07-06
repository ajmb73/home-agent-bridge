#!/bin/bash
# Daily Self-Diagnostic Data Collector — v2
# Feeds system state into the agent's context for AI-driven analysis.
# The agent reasons about this data, it doesn't just pass/fail.
set -uo pipefail

echo "=== TIMESTAMP ==="
date -u '+%Y-%m-%dT%H:%M:%SZ'
echo "=== UPTIME ==="
uptime -p
echo "=== LOAD ==="
cat /proc/loadavg
echo "=== MEMORY ==="
free -h
echo "=== DISK ==="
df -h / /tmp /var 2>/dev/null | tail -n +1

echo "=== TOP PROCESSES (by mem) ==="
ps aux --sort=-%mem | head -15

echo "=== FAILED SYSTEMD SERVICES ==="
systemctl --user list-units --state=failed --no-pager 2>/dev/null || echo "(none or unavailable)"
sudo systemctl list-units --state=failed --no-pager 2>/dev/null || echo "(no sudo available)"

echo "=== DOCKER CONTAINERS ==="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || echo "Docker not available"

echo "=== NAS ==="
ping -c 1 -W 3 192.168.0.16 2>&1 | tail -1
mount | grep -E "cifs|smb|nfs" 2>/dev/null || echo "No network mounts found"

echo "=== HERMES GATEWAY ==="
systemctl --user is-active hermes-gateway 2>/dev/null || echo "inactive"
systemctl --user status hermes-gateway --no-pager -l 2>/dev/null | head -8
# Gateway memory
GW_PID=$(systemctl --user show hermes-gateway 2>/dev/null | grep ^MainPID= | cut -d= -f2 || echo "0")
if [ "$GW_PID" != "0" ] && [ -n "$GW_PID" ]; then
  GW_MEM=$(ps -o rss= -p "$GW_PID" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}' || echo "N/A")
  echo "Gateway RSS: $GW_MEM"
fi

echo "=== HERMES VERSION ==="
hermes --version 2>&1 || echo "hermes not in PATH"

echo "=== HERMES DOCTOR (summary) ==="
hermes doctor 2>&1 | head -40

echo "=== HINDSIGHT ==="
for port in 8888 9177; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/health" --connect-timeout 3 2>/dev/null || echo "000")
  echo "Port $port: HTTP $CODE"
done

echo "=== CRON JOBS ==="
hermes cron list 2>&1 | head -30

echo "=== NETWORK INFRASTRUCTURE ==="
for target in "NAS:192.168.0.16" "tech1:192.168.0.67" "tech2:192.168.0.68" "pve1:192.168.0.53" "pve2:192.168.0.50" "pve3:192.168.0.51" "Hermy:192.168.0.13" "HA:192.168.0.71" "monitor:192.168.0.17" "internet:1.1.1.1"; do
  name="${target%%:*}"
  ip="${target##*:}"
  ping -c 1 -W 2 "$ip" &>/dev/null && echo "  $name ($ip): OK" || echo "  $name ($ip): UNREACHABLE"
done

echo "=== DNS RESOLUTION ==="
for dns in "192.168.0.67" "192.168.0.68"; do
  result=$(dig +short +timeout=2 @$dns google.com 2>/dev/null | head -1)
  [ -n "$result" ] && echo "  $dns: OK ($result)" || echo "  $dns: FAIL"
done

echo "=== HA WEB UI ==="
curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://192.168.0.71:8123/ 2>/dev/null || echo "HA unreachable"

echo "=== HERMY A2A ==="
curl -s -o /dev/null -w "%{http_code}" http://192.168.0.13:8644/health --connect-timeout 5 2>/dev/null || echo "Hermy a2a unreachable"

echo "=== INTERNET ==="
curl -s -o /dev/null -w "%{http_code}" --max-time 5 https://www.google.com/ 2>/dev/null || echo "Internet HTTPS unreachable"

echo "=== TAILSCALE ==="
tailscale status 2>/dev/null || echo "tailscale not available"

echo "=== GATEWAY LOG ERRORS (last 24h) ==="
tail -1000 ~/.hermes/logs/gateway.log 2>/dev/null | grep -i -E "error|fail|crash|oom|killed|timeout|unreachable" | tail -10 || echo "None found"

echo "=== SESSION DB ==="
ls -lh ~/.hermes/state.db 2>/dev/null
hermes sessions stats 2>/dev/null | head -5 || true

echo "=== END ==="
