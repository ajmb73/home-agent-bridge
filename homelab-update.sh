#!/usr/bin/env bash
# Homelab System Update Script
# Updates all infra systems with pre/post health checks.
# Systems: pve1/pve2/pve3 (SSH), ai-home (QEMU GA via pve1), jax (local)
#
set -euo pipefail

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
NO_ACT=false
SKIP_REBOOT_CHECK=false
for arg in "$@"; do
  case "$arg" in --no-act) NO_ACT=true ;; --skip-reboot-check) SKIP_REBOOT_CHECK=true ;; esac
done

echo "========================================"
echo " Homelab System Update — $TIMESTAMP"
echo "========================================"
echo ""

SUMMARY_GOOD=0
SUMMARY_FAIL=0
REBOOT_NODES=""

health_ssh() {
  local node=$1 ip=$2
  echo "── Health ──"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$ip" "
    echo 'Uptime:'; uptime -p
    echo 'Load:'; cat /proc/loadavg
    echo 'Memory:'; free -h | awk '/^Mem:/ {print \$3 \"/\" \$2}'
    echo 'Disk:'; df -h / | awk 'NR==2 {print \$3 \"/\" \$2 \" (\" \$5 \")\"}'
    echo 'Kernel:'; uname -r
  " 2>&1 || { echo "  FAILED — unreachable"; return 1; }
  echo ""
}

update_ssh() {
  local node=$1 ip=$2
  local label="$node ($ip)"
  echo "═══════ $label ═══════"
  health_ssh "$node" "$ip" || return 1

  if $NO_ACT; then echo "── [NO-ACT] Would run updates ──"; return 0; fi

  echo "── apt update ──"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$ip" "apt update" 2>&1 || return 1

  echo ""; echo "── apt upgrade -y ──"
  local log
  log=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=180 root@"$ip" \
    "DEBIAN_FRONTEND=noninteractive apt upgrade -y 2>&1"; echo "EXIT=$?")
  echo "$log" | grep -v '^EXIT='
  local rc=$(echo "$log" | grep '^EXIT=' | cut -d= -f2)
  [ "$rc" = "0" ] || { echo "FAILED (exit $rc)"; return 1; }

  echo ""; echo "── Post-update ──"
  health_ssh "$node" "$ip" || true

  if ! $SKIP_REBOOT_CHECK; then
    local rb
    rb=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$ip" \
      'if [ -f /var/run/reboot-required ]; then echo "YES"; else echo "NO"; fi')
    echo "Reboot required: $rb"
    [ "$rb" = "YES" ] && REBOOT_NODES="$REBOOT_NODES $node"
  fi

  echo "✓ $label done"; echo ""; return 0
}

update_aihome() {
  local node="ai-home" pve_ip="192.168.0.53" vmid="101"
  echo "═══════ ai-home (VM $vmid on $pve_ip) ═══════"

  echo "── Health ──"
  local raw
  raw=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$pve_ip" \
    "qm guest exec $vmid -- bash -c 'echo Uptime:; uptime -p; echo Load:; cat /proc/loadavg; echo Memory:; free -h | awk \"/^Mem:/ {print \\\$3 \\\" / \\\" \\\$2}\"; echo Disk:; df -h / | awk \"NR==2 {print \\\$3 \\\" / \\\" \\\$2 \\\" (\\\" \\\$5 \\\")\\\"}\"; echo Kernel:; uname -r'" 2>&1)
  echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data',''))" 2>/dev/null
  echo ""

  if $NO_ACT; then echo "── [NO-ACT] Would run updates ──"; return 0; fi

  echo "── apt update ──"
  raw=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 root@"$pve_ip" \
    "qm guest exec $vmid -- bash -c 'apt update 2>&1'" 2>&1)
  echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data',''))" 2>/dev/null
  local ec=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exitcode',1))" 2>/dev/null)
  [ "$ec" = "0" ] || { echo "FAILED"; return 1; }

  echo ""; echo "── apt upgrade -y ──"
  raw=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=180 root@"$pve_ip" \
    "qm guest exec $vmid -- bash -c 'DEBIAN_FRONTEND=noninteractive apt upgrade -y 2>&1; echo EXITCODE=\$?'" 2>&1)
  echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data',''))" 2>/dev/null
  ec=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exitcode',1))" 2>/dev/null)
  [ "$ec" = "0" ] || { echo "FAILED (exit $ec)"; return 1; }

  echo ""; echo "── Post-update ──"
  raw=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$pve_ip" \
    "qm guest exec $vmid -- bash -c 'echo Uptime:; uptime -p; echo Memory:; free -h | awk \"/^Mem:/ {print \\\$3 \\\" / \\\" \\\$2}\"; echo Disk:; df -h / | awk \"NR==2 {print \\\$3 \\\" / \\\" \\\$2 \\\" (\\\" \\\$5 \\\")\\\"}\"; echo Kernel:; uname -r'" 2>&1)
  echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data',''))" 2>/dev/null

  if ! $SKIP_REBOOT_CHECK; then
    raw=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$pve_ip" \
      "qm guest exec $vmid -- bash -c 'if [ -f /var/run/reboot-required ]; then echo YES; else echo NO; fi'" 2>&1)
    local rb=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data','').strip())" 2>/dev/null)
    echo "Reboot required: $rb"
    [ "$rb" = "YES" ] && REBOOT_NODES="$REBOOT_NODES ai-home"
  fi

  echo "✓ ai-home done"; echo ""; return 0
}

update_jax() {
  echo "═══════ jax (localhost) ═══════"
  echo "── Health ──"
  echo "Uptime: $(uptime -p)"
  echo "Load: $(cat /proc/loadavg)"
  echo "Memory: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
  echo "Disk: $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')"
  echo "Kernel: $(uname -r)"
  echo ""

  if $NO_ACT; then echo "── [NO-ACT] Would run updates ──"; return 0; fi

  echo "── apt update ──"
  sudo apt update 2>&1 || return 1

  echo ""; echo "── apt upgrade -y ──"
  sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y 2>&1 || { echo "FAILED"; return 1; }

  echo ""; echo "── Post-update ──"
  echo "Uptime: $(uptime -p)"
  echo "Kernel: $(uname -r)"

  if ! $SKIP_REBOOT_CHECK; then
    if [ -f /var/run/reboot-required ]; then
      echo "Reboot required: YES"
      REBOOT_NODES="$REBOOT_NODES jax"
    else
      echo "Reboot required: NO"
    fi
  fi

  echo "✓ jax done"; echo ""; return 0
}

# ── Run ──
update_ssh "pve1" "192.168.0.53" && SUMMARY_GOOD=$((SUMMARY_GOOD+1)) || SUMMARY_FAIL=$((SUMMARY_FAIL+1))
update_ssh "pve2" "192.168.0.50" && SUMMARY_GOOD=$((SUMMARY_GOOD+1)) || SUMMARY_FAIL=$((SUMMARY_FAIL+1))
update_ssh "pve3" "192.168.0.51" && SUMMARY_GOOD=$((SUMMARY_GOOD+1)) || SUMMARY_FAIL=$((SUMMARY_FAIL+1))
update_aihome && SUMMARY_GOOD=$((SUMMARY_GOOD+1)) || SUMMARY_FAIL=$((SUMMARY_FAIL+1))
update_jax && SUMMARY_GOOD=$((SUMMARY_GOOD+1)) || SUMMARY_FAIL=$((SUMMARY_FAIL+1))

# ── Summary ──
echo "========================================"
echo " UPDATE SUMMARY"
echo "========================================"
echo "  Total: 5 | OK: $SUMMARY_GOOD | Failed: $SUMMARY_FAIL"
if [ -n "$REBOOT_NODES" ]; then
  echo "  ⚠️  Reboot needed: $REBOOT_NODES"
fi
echo "========================================"
