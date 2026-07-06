#!/bin/bash
# Weekly Hermes Agent self-update
set -euo pipefail

cd "$HOME/.hermes/hermes-agent"
BEFORE=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

OUTPUT=$(hermes update 2>&1) || true

AFTER=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

if [ "$BEFORE" = "$AFTER" ]; then
    echo "✅ Hermes Agent already up to date at $BEFORE"
else
    echo "🔄 Hermes Agent updated: $BEFORE → $AFTER"
    echo ""
    echo "--- Update log ---"
    echo "$OUTPUT" | tail -20
fi

echo ""
echo "📋 $(hermes --version 2>/dev/null || echo 'version check failed')"
