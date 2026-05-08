#!/bin/bash
# =============================================================================
# OpenClaw Agent Side Setup for home-agent-bridge
# =============================================================================
# License: MIT
# Description: Sets up the OpenClaw Agent side of the home-agent-bridge
#              to enable inter-agent communication with Hermes Agent.
#              Connects to Hermes Agent bridge server at localhost:18473.
# =============================================================================

set -e
umask 077

# ---- Configuration ------------------------------------------------------------
REPO_URL="https://github.com/ajmb73/home-agent-bridge"
BRIDGE_PORT="18473"
SKILL_DEST_DIR="${HOME}/.hermes/skills/openclaw-imports/agent-bridge"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="${HOME}/.hermes/logs/agent-bridge-setup.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# ---- Logging ------------------------------------------------------------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOGFILE"
}

info()  { log "INFO:  $*"; }
warn()  { log "WARN:  $*"; }
error() { log "ERROR: $*"; }

# ---- Pre-flight checks --------------------------------------------------------
check_prerequisites() {
    info "Checking prerequisites..."

    # Python 3
    if ! command -v python3 &>/dev/null; then
        error "Python 3 is not installed. Please install Python 3.8 or later."
        exit 1
    fi
    PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    info "Python version: ${PYTHON_VERSION}"

    # openclaw CLI
    if ! command -v openclaw &>/dev/null; then
        error "openclaw CLI is not installed. Please install OpenClaw Agent CLI."
        exit 1
    fi
    openclaw --version &>/dev/null || warn "Could not determine openclaw version"
    info "openclaw CLI found at: $(which openclaw)"

    # Network access check (localhost:18473)
    if command -v nc &>/dev/null; then
        if nc -z localhost "$BRIDGE_PORT" 2>/dev/null; then
            info "Hermes Agent bridge server detected on port ${BRIDGE_PORT}."
        else
            warn "No service detected on localhost:${BRIDGE_PORT}. Is Hermes Agent running?"
        fi
    else
        warn "netcat (nc) not found; skipping port reachability check."
    fi

    info "Prerequisites check passed."
}

# ---- Clone / update repo ------------------------------------------------------
clone_or_update_repo() {
    info "Setting up home-agent-bridge repository..."

    if [ -d "${SCRIPT_DIR}/home-agent-bridge" ]; then
        info "Repository already exists. Updating..."
        cd "${SCRIPT_DIR}/home-agent-bridge"
        git remote set-url origin "$REPO_URL" 2>/dev/null || true
        git pull --ff origin main 2>/dev/null || git pull --ff origin master 2>/dev/null || \
            warn "Could not pull latest changes."
    else
        info "Cloning repository..."
        git clone "$REPO_URL" "${SCRIPT_DIR}/home-agent-bridge"
    fi

    if [ ! -d "${SCRIPT_DIR}/home-agent-bridge" ]; then
        error "Failed to clone repository."
        exit 1
    fi

    info "Repository ready at: ${SCRIPT_DIR}/home-agent-bridge"
}

# ---- Install OpenClaw Agent-side skill ----------------------------------------
install_skill() {
    info "Installing OpenClaw Agent-side skill..."

    mkdir -p "$SKILL_DEST_DIR"

    # Try to fetch SKILL.md from the repo first
    local skill_src="${SCRIPT_DIR}/home-agent-bridge/openclaw-agent-side/SKILL.md"
    if [ -f "$skill_src" ]; then
        info "Using local SKILL.md from cloned repository."
        cp "$skill_src" "${SKILL_DEST_DIR}/SKILL.md"
    else
        warn "Local SKILL.md not found. You may need to configure the skill manually."
        warn "Fetch it from: https://github.com/ajmb73/home-agent-bridge/blob/main/skills/openclaw-agent-side/SKILL.md"
        # Create a minimal placeholder so the directory structure exists
        cat > "${SKILL_DEST_DIR}/SKILL.md" << 'EOF'
---
name: home-agent-bridge
description: OpenClaw Agent skill for connecting to Hermes Agent via bridge on port 18473
---
# home-agent-bridge — OpenClaw Agent Side

Configure this skill with:
- Bridge endpoint: localhost:18473
- Protocol: TCP socket (JSON messages)
- No authentication required (localhost only)

For the full SKILL.md content, see:
https://github.com/ajmb73/home-agent-bridge
EOF
    fi

    info "Skill installed to: ${SKILL_DEST_DIR}"
}

# ---- Test connection ----------------------------------------------------------
test_connection() {
    info "Testing bridge connection to Hermes Agent on port ${BRIDGE_PORT}..."

    if ! command -v python3 &>/dev/null; then
        warn "Python3 not available; skipping socket test."
        return 0
    fi

    # Simple TCP connectivity test using Python
    if python3 - << 'PYEOF'
import socket, sys, time

HOST = "localhost"
PORT = 18473
TIMEOUT = 5

try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(TIMEOUT)
    sock.connect((HOST, PORT))
    sock.close()
    print("CONNECTION_OK")
    sys.exit(0)
except Exception as e:
    print(f"CONNECTION_FAILED: {e}")
    sys.exit(1)
PYEOF
    then
        info "Successfully connected to Hermes Agent bridge on port ${BRIDGE_PORT}."
    else
        warn "Could not connect to bridge on port ${BRIDGE_PORT}."
        warn "Ensure Hermes Agent bridge server is running and try again."
    fi
}

# ---- Main ---------------------------------------------------------------------
main() {
    info "=== OpenClaw Agent Side Setup for home-agent-bridge ==="
    info "Target: Hermes Agent bridge at localhost:${BRIDGE_PORT}"

    check_prerequisites
    clone_or_update_repo
    install_skill
    test_connection

    info "=== Setup complete ==="
    info "Next steps:"
    info "  1. Start the Hermes Agent bridge server (if not running)"
    info "  2. Run: openclaw skill load agent-bridge"
    info "  3. Test with: openclaw bridge test --to hermes-agent"
}

main "$@"
