#!/bin/bash
# Weekly Docker Health Check — Docker apps inventory, update check, NAS mount verification
set -euo pipefail

REPORT=""
FAIL=0
WARN=0

report() { REPORT+="$1"$'\n'; }

# ─── NAS Mount ──────────────────────────────────────────────────────────────
report "## NAS Mount Check"
NAS_CHECK=$(df -h /mnt/nas_share 2>&1) || true
if echo "$NAS_CHECK" | grep -q "SMB Share"; then
  USED=$(echo "$NAS_CHECK" | awk 'NR==2{print $5}')
  report "✓ /mnt/nas_share — mounted ($USED used)"
else
  report "✗ /mnt/nas_share — NOT MOUNTED"
  FAIL=$((FAIL+1))
fi

# Test qBittorrent's media directories are accessible
for dir in "/mnt/nas_share/Media/Movies" "/mnt/nas_share/Media/Series"; do
  if ls "$dir"/* >/dev/null 2>&1; then
    COUNT=$(ls "$dir" 2>/dev/null | wc -l)
    report "  ✓ $(basename $dir) — $COUNT items accessible"
  else
    report "  ✗ $(basename $dir) — empty or inaccessible"
    WARN=$((WARN+1))
  fi
done

# ─── qBittorrent ────────────────────────────────────────────────────────────
report ""
report "## qBittorrent"
QB_STATUS=$(docker inspect qbittorrent --format '{{.State.Status}}' 2>&1) || true
QB_HEALTHY=""
QB_HEALTH_CHECK=$(docker inspect qbittorrent --format '{{.State.Health.Status}}' 2>&1) || QB_HEALTH_CHECK=""
if [ -n "$QB_HEALTH_CHECK" ] && [ "$QB_HEALTH_CHECK" != "<no value>" ]; then
  QB_HEALTHY=" ($QB_HEALTH_CHECK)"
fi
if echo "$QB_STATUS" | grep -q "running"; then
  QB_IMAGE=$(docker inspect qbittorrent --format '{{.Config.Image}}' 2>&1)
  QB_CREATED=$(docker inspect qbittorrent --format '{{.Created}}' 2>&1 | cut -dT -f1)
  report "✓ qbittorrent — running${QB_HEALTHY} (image: $QB_IMAGE, since: $QB_CREATED)"
  # WebUI reachable?
  QB_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://localhost:8080 2>&1) || QB_HTTP="000"
  if [ "$QB_HTTP" = "200" ] || [ "$QB_HTTP" = "302" ]; then
    report "  ✓ WebUI on :8080 — HTTP $QB_HTTP"
  else
    report "  ✗ WebUI on :8080 — HTTP $QB_HTTP"
    WARN=$((WARN+1))
  fi
  # Check for available update
  QB_LATEST=$(curl -s "https://hub.docker.com/v2/repositories/linuxserver/qbittorrent/tags?page_size=1&name=latest" 2>&1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['last_updated'][:10] if d.get('results') else 'unknown')" 2>&1) || QB_LATEST="unknown"
  report "  ↻ Image latest on hub: $QB_LATEST"
else
  report "✗ qbittorrent — NOT RUNNING"
  WARN=$((WARN+1))
fi

# ─── NetAlertX ──────────────────────────────────────────────────────────────
report ""
report "## NetAlertX"
NA_STATUS=$(docker inspect netalertx --format '{{.State.Status}} {{.State.Health.Status}}' 2>&1) || true
if echo "$NA_STATUS" | grep -q "^running"; then
  NA_IMAGE=$(docker inspect netalertx --format '{{.Config.Image}}' 2>&1)
  NA_CREATED=$(docker inspect netalertx --format '{{.Created}}' 2>&1 | cut -dT -f1)
  report "✓ netalertx — $NA_STATUS (image: $NA_IMAGE, since: $NA_CREATED)"
  NA_LATEST=$(curl -s "https://hub.docker.com/v2/repositories/jokobsk/netalertx/tags?page_size=1&name=latest" 2>&1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['last_updated'][:10] if d.get('results') else 'unknown')" 2>&1) || NA_LATEST="unknown"
  report "  ↻ Image latest on hub: $NA_LATEST"
else
  report "✗ netalertx — NOT RUNNING ($NA_STATUS)"
  FAIL=$((FAIL+1))
fi

# ─── Grimmory (Proxmox CT 105) ─────────────────────────────────────────────
report ""
report "## Grimmory (Proxmox CT 105)"
GRIM_STATUS=$(ssh root@proxmox3 "pct exec 105 -- docker ps --format '{{.Names}} {{.Status}}' --filter name=grimmory" 2>&1) || GRIM_STATUS="unreachable"
if echo "$GRIM_STATUS" | grep -q "healthy"; then
  GRIM_IMAGE=$(ssh root@proxmox3 "pct exec 105 -- docker inspect grimmory --format '{{.Config.Image}}' 2>&1")
  GRIM_UPTIME=$(ssh root@proxmox3 "pct exec 105 -- docker inspect grimmory --format '{{.State.StartedAt}}' 2>&1" | cut -dT -f1)
  report "✓ grimmory — healthy (image: $GRIM_IMAGE, since: $GRIM_UPTIME)"
  # Check NAS books mount inside CT
  BOOKS_MOUNT=$(ssh root@proxmox3 "pct exec 105 -- mount | grep /books" 2>&1) || true
  if echo "$BOOKS_MOUNT" | grep -q "192.168.0.16"; then
    BOOK_COUNT=$(ssh root@proxmox3 "pct exec 105 -- ls /books 2>/dev/null | wc -l" 2>&1) || BOOK_COUNT="?"
    report "  ✓ /books mount OK — $BOOK_COUNT items"
  else
    report "  ✗ /books mount MISSING"
    WARN=$((WARN+1))
  fi
  # WebUI reachable
  GRIM_HTTP=$(ssh root@proxmox3 "pct exec 105 -- curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://localhost:6060" 2>&1) || GRIM_HTTP="000"
  if [ "$GRIM_HTTP" = "200" ] || [ "$GRIM_HTTP" = "302" ]; then
    report "  ✓ WebUI on :6060 — HTTP $GRIM_HTTP"
  else
    report "  ✗ WebUI on :6060 — HTTP $GRIM_HTTP"
    WARN=$((WARN+1))
  fi
elif echo "$GRIM_STATUS" | grep -q "unreachable"; then
  report "✗ proxmox — UNREACHABLE via SSH"
  FAIL=$((FAIL+1))
else
  report "✗ grimmory — $GRIM_STATUS"
  FAIL=$((FAIL+1))
fi

# Grimmory MariaDB
MARIA_STATUS=$(ssh root@proxmox3 "pct exec 105 -- docker ps --format '{{.Names}} {{.Status}}' --filter name=grimmory-mariadb" 2>&1) || MARIA_STATUS="unreachable"
if echo "$MARIA_STATUS" | grep -q "healthy"; then
  report "✓ grimmory-mariadb — healthy"
else
  report "✗ grimmory-mariadb — $MARIA_STATUS"
  FAIL=$((FAIL+1))
fi

# ─── Docker Update Check (pull dry-run) ─────────────────────────────────────
report ""
report "## Docker Image Updates"
pull_check() {
  local name=$1 image=$2 host=$3
  local current=""
  if [ -n "$host" ]; then
    current=$(ssh root@$host "pct exec 105 -- docker images --format '{{.ID}}' $image 2>&1") || true
    # Pull quietly — only downloads layers if digest changed. Weekly cadence = negligible traffic.
    new=$(ssh root@$host "pct exec 105 -- docker pull --quiet $image 2>&1") || true
  else
    current=$(docker images --format '{{.ID}}' "$image" 2>&1)
    # Pull quietly — same rationale.
    new=$(docker pull --quiet "$image" 2>&1) || true
  fi
  if echo "$new" | grep -qi "already up to date\\|up to date\\|already exists"; then
    report "  ✓ $name — up to date"
  elif echo "$new" | grep -qi "downloaded newer\|pulled newer\|digest:"; then
    report "  ⚠ $name — UPDATE AVAILABLE (pulled successfully)"
    WARN=$((WARN+1))
  else
    report "  ? $name — check failed: $(echo "$new" | tail -1)"
  fi
}

# Local containers
pull_check "qbittorrent" "lscr.io/linuxserver/qbittorrent:latest" ""
pull_check "netalertx" "jokobsk/netalertx:latest" ""

# Remote containers (proxmox CT 105)
pull_check "grimmory" "grimmory/grimmory:latest" "proxmox3"
pull_check "grimmory-mariadb" "mariadb:10.11" "proxmox3"

# ─── Summary ─────────────────────────────────────────────────────────────────
report ""
report "─── Summary ───"
report "❌ Failures: $FAIL"
report "⚠  Warnings: $WARN"
report "━━━━━━━━━━━━━━━"

# Print the report
echo "$REPORT"

# Exit code for cron to use
[ $FAIL -gt 0 ] && exit 1 || exit 0
