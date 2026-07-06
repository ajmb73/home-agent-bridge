#!/bin/bash
# DNS config backup for tech1 and tech2 via Python (handles special chars safely)
set -euo pipefail

LOCK="${HOME}/.run/$(basename "$0").lock"
acquire_lock() { mkdir "$LOCK" 2>/dev/null; }
release_lock() { rm -rf "$LOCK"; }
trap release_lock EXIT
acquire_lock || { echo "Already running, skipping"; exit 0; }

BACKUP_DIR="${HOME}/clawd/backups/dns"
GIT_DIR="${HOME}/clawd/backups"
LOG="${HOME}/clawd/logs/dns-backup.log"
mkdir -p "$BACKUP_DIR" "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Source pass-cli token
if ! source ~/.proton/token.env 2>/dev/null; then
    log "ERROR: cannot source token.env"
    exit 1
fi

# Ensure valid PAT session — handles session expiry/corruption
if ! pass-cli test &>/dev/null; then
    pass-cli login --pat "$PROTON_PASS_PERSONAL_ACCESS_TOKEN" &>/dev/null || {
        log "ERROR: pass-cli PAT login failed"
        exit 1
    }
fi

get_pass() {
    local title="$1"
    PROTON_PASS_AGENT_REASON="DNS backup - retrieving $title" \
        pass-cli item view --vault-name "Agents" --item-title "$title" --output json \
        --field password 2>/dev/null
}

PY_BACKUP_SCRIPT=$(cat << 'PYEOF'
import json, urllib.request, urllib.parse, sys, os

ip = os.environ['DNS_IP']
password = os.environ['DNS_PASS']
settings_path = os.environ['SETTINGS_PATH']
zone_path = os.environ['ZONE_PATH']
settings_tmp = settings_path + '.tmp'
zone_tmp = zone_path + '.tmp'

base = f'http://{ip}:5380'

def api_get(path, params):
    url = f'{base}/api/{path}?{urllib.parse.urlencode(params)}'
    req = urllib.request.Request(url, method='GET')
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.read().decode()

def api_post_form(path, data):
    url = f'{base}/api/{path}'
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, method='POST')
    req.add_header('Content-Type', 'application/x-www-form-urlencoded')
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.read().decode()

# Login
resp = json.loads(api_post_form('user/login', {'user': 'admin', 'pass': password}))
token = resp.get('token') or resp.get('response', {}).get('token', '')
if not token:
    print('ERROR: login failed - no token in response', file=sys.stderr)
    sys.exit(1)
print(f'Login OK (token len {len(token)})')

# Settings (GET with ?token=)
settings = api_get('settings/get', {'token': token})
with open(settings_tmp, 'w') as f:
    f.write(settings)
sz1 = os.path.getsize(settings_tmp)
print(f'Settings OK: {sz1} bytes')

# Zone export (GET with ?token=&zone=)
zone = api_get('zones/export', {'token': token, 'zone': 'home'})
with open(zone_tmp, 'w') as f:
    f.write(zone)
sz2 = os.path.getsize(zone_tmp)
print(f'Zone OK: {sz2} bytes')
PYEOF
)

backup_server() {
    local ip="$1" label="$2" pass="$3"
    local settings_file="${BACKUP_DIR}/${label}-settings.json"
    local zone_file="${BACKUP_DIR}/${label}-home-zone.txt"

    # Clear any stale tmp files
    rm -f "${settings_file}.tmp" "${zone_file}.tmp"

    export DNS_IP="$ip" DNS_LABEL="$label" DNS_PASS="$pass"
    export SETTINGS_PATH="$settings_file" ZONE_PATH="$zone_file"

    python3 -c "$PY_BACKUP_SCRIPT" 2>&1 | while read line; do log "${label}: $line"; done
    local py_exit="${PIPESTATUS[0]}"

    if [ "$py_exit" -eq 0 ] && [ -f "${settings_file}.tmp" ] && [ -f "${zone_file}.tmp" ]; then
        mv "${settings_file}.tmp" "$settings_file"
        mv "${zone_file}.tmp" "$zone_file"
        log "${label}: ✅ $(stat --format='%s' "$settings_file")B settings, $(stat --format='%s' "$zone_file")B zone"
        return 0
    else
        rm -f "${settings_file}.tmp" "${zone_file}.tmp"
        log "${label}: ❌ backup failed (exit=$py_exit)"
        return 1
    fi
}

log "=== DNS Backup Start ==="

PASS1=$(get_pass "Technitium DNS (tech1)")
if [ -z "$PASS1" ]; then
    log "ERROR: cannot get tech1 password"
    exit 1
fi
backup_server "192.168.0.67" "tech1" "$PASS1"

PASS2=$(get_pass "Technitium DNS (tech2)")
if [ -z "$PASS2" ]; then
    log "ERROR: cannot get tech2 password"
    exit 1
fi
backup_server "192.168.0.68" "tech2" "$PASS2"

# Git commit
DATE=$(date '+%Y-%m-%d')
cd "$GIT_DIR"
git add dns/ 2>/dev/null || log "WARN: git add failed"
if git diff --cached --quiet 2>/dev/null; then
    log "No changes to commit"
else
    git commit -m "backup: daily DNS config ${DATE}" 2>&1 | while read line; do log "git: $line"; done
    git push 2>/dev/null || log "WARN: no remote configured, push skipped"
fi

log "=== DNS Backup Complete ==="
