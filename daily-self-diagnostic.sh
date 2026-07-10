#!/bin/bash
# Daily Self-Diagnostic Watchdog — v3
# Silent when healthy, alerts only on real problems.
# Designed for no_agent mode: empty output = silent, non-empty = delivered.
set -uo pipefail

ISSUES=0
REPORT=""

check() {
  local label="$1"
  local result="$2"
  if [ "$result" != "0" ]; then
    ISSUES=$((ISSUES + 1))
    REPORT+="$label"$'\n'
  fi
}

# ── Core system ──
LOAD=$(awk '{print $1}' /proc/loadavg)
check "High load: $LOAD" "$(echo "$LOAD > 4" | bc -l 2>/dev/null || echo 1)"

MEM_USED=$(free -m | awk '/^Mem:/{printf "%.0f", $3/$2 * 100}')
check "Memory >80%: ${MEM_USED}%" "$([ "$MEM_USED" -gt 80 ] && echo 1 || echo 0)"

DISK_USED=$(df / | awk 'NR==2{print+$5}')
check "Disk / >80%: ${DISK_USED}%" "$([ "$DISK_USED" -gt 80 ] && echo 1 || echo 0)"

# ── Systemd ──
FAILED=$(systemctl --user list-units --state=failed --no-pager 2>/dev/null | grep -c "failed" || true)
check "$FAILED user services failed" "$([ "$FAILED" -gt 0 ] && echo 1 || echo 0)"

FAILED_SYS=$(sudo systemctl list-units --state=failed --no-pager 2>/dev/null | grep -c "failed" || true)
check "$FAILED_SYS system services failed" "$([ "$FAILED_SYS" -gt 0 ] && echo 1 || echo 0)"

# ── Gateway ──
GW_ACTIVE=$(systemctl --user is-active hermes-gateway 2>/dev/null || echo "inactive")
check "Gateway: $GW_ACTIVE" "$([ "$GW_ACTIVE" = "active" ] && echo 0 || echo 1)"

# ── Hindsight ──
HS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8888/health --connect-timeout 3 2>/dev/null || echo "000")
check "Hindsight health: HTTP $HS_CODE" "$([ "$HS_CODE" = "200" ] && echo 0 || echo 1)"

# ── Network infrastructure ──
for target in "NAS:192.168.0.16" "tech1:192.168.0.67" "tech2:192.168.0.68" "pve1:192.168.0.53" "pve2:192.168.0.50" "pve3:192.168.0.51" "Hermy:192.168.0.13" "HA:192.168.0.71" "internet:1.1.1.1"; do
  name="${target%%:*}"
  ip="${target##*:}"
  if ! ping -c 1 -W 2 "$ip" &>/dev/null; then
    ISSUES=$((ISSUES + 1))
    REPORT+="Host down: $name ($ip)"$'\n'
  fi
done

# ── DNS ──
for dns in "tech1:192.168.0.67" "tech2:192.168.0.68"; do
  name="${dns%%:*}"
  ip="${dns##*:}"
  result=$(dig +short +timeout=2 @"$ip" google.com 2>/dev/null | head -1)
  if [ -z "$result" ]; then
    ISSUES=$((ISSUES + 1))
    REPORT+="DNS resolution failed: $name ($ip)"$'\n'
  fi
done

# ── Internet ──
WEB_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 https://www.google.com/ 2>/dev/null || echo "000")
check "Internet: HTTP $WEB_CODE" "$([ "$WEB_CODE" = "200" ] && echo 0 || echo 1)"

# ── HA Web UI ──
HA_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://192.168.0.71:8123/ 2>/dev/null || echo "000")
check "HA Web: HTTP $HA_CODE" "$([ "$HA_CODE" = "200" ] && echo 0 || echo 1)"

# ── A2A Inbox Protocol ──
if [ ! -d /mnt/nas_share/agent-inbox/inbox/jax/ ]; then
  check "A2A inbox not mounted or inaccessible" 1
fi

# ── Output ──
if [ "$ISSUES" -gt 0 ]; then
  echo "⚠️  $ISSUES issue(s) found:"
  echo "$REPORT"
  exit 1
fi
# Silent exit 0 — nothing delivered
