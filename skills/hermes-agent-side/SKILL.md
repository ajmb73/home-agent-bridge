---
name: agent-bridge
description: HTTP bridge server + skill for inter-agent communication between OpenClaw Agent and Hermes Agent. Receives messages from OpenClaw via POST, queues them for Hermes to process, and exposes a REST API for message management.
trigger: "When Hermes Agent needs to send/receive messages with OpenClaw Agent via the home-agent-bridge HTTP API."
trigger_strict: false
---

# Agent Bridge — HTTP Receiver for Inter-Agent Communication

## Components

1. **HTTP Server** (`~/.hermes/scripts/agent-bridge-server.py`) — Lightweight FastAPI/stdlib HTTP receiver
2. **Skill** (this file) — Hermes side integration for the bridge
3. **OpenClaw Agent's counterpart** — OpenClaw skill that POSTs to this bridge

## HTTP API

| Method | Endpoint | Description |
|---------|----------|-------------|
| GET | `/status` | Health check |
| POST | `/message` | Submit a message `{text, from}` |
| GET | `/messages` | Get all pending messages |
| DELETE | `/message/<id>` | Acknowledge/remove a message |

## Running the Server

```bash
python3 ~/.hermes/scripts/agent-bridge-server.py --port 18473
```

To run as a persistent background service:
```bash
nohup python3 ~/.hermes/scripts/agent-bridge-server.py --port 18473 > /tmp/agent-bridge.log 2>&1 &
```

## Message Flow

1. OpenClaw Agent sends: `curl -X POST http://127.0.0.1:18473/message -H "Content-Type: application/json" -d '{"text":"do something","from":"openclaw"}'`
2. Message queued at `/tmp/agent-bridge/incoming.jsonl`
3. Hermes Agent polls GET `/messages` or is notified via Telegram
4. Hermes processes and writes response to `/tmp/hermy-to-bobby.md` (shared file fallback)
5. OpenClaw Agent reads the response file

## Checking for New Messages

```bash
curl -s http://127.0.0.1:18473/messages | python3 -c "import json,sys; msgs=json.load(sys.stdin)['messages']; [print(m['id'], m['text'][:50], m['time']) for m in msgs]"
```

## Health Check

```bash
curl -s http://127.0.0.1:18473/status  # → {"status": "ok", "bridge": "home-agent-bridge", "queue_len": N}
```

## Security Notes

- Server binds to `127.0.0.1:18473` — only accessible from the local machine
- No authentication on endpoints — relies on network isolation
- Queue files in `/tmp/agent-bridge/` with `0700` permissions (owner-only)
- 64KB max request body size (prevents memory exhaustion DoS)
- File locking via `fcntl` protects queue integrity under concurrent access
- Messages stored as JSONL — not encrypted at rest
- For home server use only; not intended for internet exposure

## Repo

https://github.com/ajmb73/home-agent-bridge