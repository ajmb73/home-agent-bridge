#!/bin/bash
# Send a message from Jax to Hermy via webhook
# Hermy processes it and the response is delivered per her webhook subscription config
# Usage: ./send-to-hermy.sh "your message here"
set -euo pipefail

MESSAGE="${1:-Hello from Jax!}"
HERMY_WEBHOOK="http://192.168.0.13:8644/webhooks/jax-inbox"
SHARE_ID="3RhkIoczlcY4AzztkKZYb5-mxxu8aNzwPWBNO40gGJm1nZ5LZksnyJaF_t-iYDtvusmigdbsPfj0YbWvAqxSrg=="

# Read HMAC secret from Proton Pass Agents vault
SECRET=$(PROTON_PASS_AGENT_REASON="Send-to-hermy: reading webhook secret" \
  pass-cli item view --share-id "$SHARE_ID" \
  --item-title "Hermy Webhook Secret" \
  --field note 2>/dev/null) || {
  echo "✗ Failed to read Hermy Webhook Secret from Proton Pass" >&2
  exit 1
}

# Use temp files — avoids shell expansion issues and /tmp race conditions
JSON_TMP=$(mktemp) || { echo "✗ Failed to create temp file" >&2; exit 1; }
RESP_TMP=$(mktemp) || { echo "✗ Failed to create temp file" >&2; rm -f "$JSON_TMP"; exit 1; }
trap 'rm -f "$JSON_TMP" "$RESP_TMP"' EXIT

# Build JSON payload (no shell expansion risk via python3)
python3 -c "import json,sys; json.dump({'text': sys.argv[1]}, open('${JSON_TMP}', 'w'))" "$MESSAGE"
SIGNATURE=$(openssl dgst -sha256 -hmac "$SECRET" < "$JSON_TMP" | cut -d' ' -f2)

echo "→ Sending to Hermy: $MESSAGE"
HTTP_CODE=$(curl -s -o "$RESP_TMP" -w "%{http_code}" -X POST "$HERMY_WEBHOOK" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIGNATURE" \
  -d @"$JSON_TMP")

if [ "$HTTP_CODE" = "202" ]; then
  echo "✓ Accepted (HTTP 202) — Hermy is processing it"
elif [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Delivered (HTTP 200)"
else
  echo "✗ Failed (HTTP $HTTP_CODE)"
  cat "$RESP_TMP"
fi
