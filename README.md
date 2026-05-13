# Home Agent Bridge

A lightweight HTTP bridge that enables two different AI agent frameworks — [OpenClaw](https://github.com/nousresearch/openclaw) and [Hermes Agent](https://hermes-agent.nousresearch.com/) — to communicate with each other on the same home server, in real-time, without cloud dependencies.

## The Problem

Home server enthusiasts often run multiple AI agents for different tasks (home automation, coding, research, etc.). These agents are built on different frameworks and don't natively talk to each other. Existing solutions require cloud services, complex infrastructure, or custom integrations that break on every update.

## The Solution

Home Agent Bridge creates a simple HTTP-based message queue that runs entirely on your local network:

```
OpenClaw Agent  ←→  HTTP Bridge (port 18473)  ←→  Hermes Agent
```

- OpenClaw Agent POSTs messages to the bridge
- Hermes Agent polls or receives notifications
- Responses written back via shared file
- Entirely local, no internet required

## Features

- **Framework-agnostic**: Works with any AI agent that can make HTTP POST requests
- **Responsive**: Sub-second latency when Hermes polls the bridge frequently (configurable poll interval)
- **Secure**: Binds to localhost only — not exposed to the internet
- **Stateless**: Messages queued in JSONL files — survives restarts
- **Batch operations**: Acknowledge multiple messages in a single request (v2.0.0)

## Requirements

- Python 3.8+
- Both agents running on the same machine (or same local network)
- SSH access between agents (for Hermes CLI invocations)

## Quick Start

### 1. Install the bridge server

```bash
# Navigate to the scripts directory
cd /home/ale/.hermes/scripts

# Start the bridge server (default port: 18473)
python3 agent-bridge-server.py --port 18473 &

# Verify it's running
curl http://127.0.0.1:18473/status
# → {"status": "ok", "bridge": "home-agent-bridge", "version": "2.0.0", ...}
```

### 2. Configure the OpenClaw Agent side

Send a message to the bridge:

```bash
curl -X POST http://127.0.0.1:18473/message \
  -H "Content-Type: application/json" \
  -d '{"text":"your message here", "from":"openclaw", "to":"hermes"}'
```

### 3. Configure the Hermes Agent side

```bash
# Poll for messages addressed to hermes
curl "http://127.0.0.1:18473/messages?for=hermes"

# Acknowledge (remove) a processed message
curl -X DELETE "http://127.0.0.1:18473/message/<id>?by=hermes"

# Batch acknowledge multiple messages at once
curl -X POST http://127.0.0.1:18473/messages/ack \
  -H "Content-Type: application/json" \
  -d '{"ids": ["abc12345", "def67890"], "by": "hermes"}'
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Home Server                             │
│                                                             │
│   ┌──────────────┐                    ┌──────────────────┐  │
│   │  OpenClaw    │                    │   Hermes Agent   │  │
│   │  Agent       │──── HTTP POST ────→│                  │  │
│   │              │<─── poll/file ─────│                  │  │
│   └──────────────┘                    └──────────────────┘  │
│           ↑                                 │               │
│           └──────── SSH + shared files ←────┘               │
│                     (fallback path)                         │
│                                                             │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  Bridge Server (127.0.0.1:18473)                  │   │
│   │  ├── GET /status        → health + stats          │   │
│   │  ├── POST /message      → queue message           │   │
│   │  ├── GET /messages      → list pending messages   │   │
│   │  ├── DELETE /message/<id> → ack single message   │   │
│   │  └── POST /messages/ack → batch ack              │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## API Reference

### GET /status

Health check and statistics. Returns:

```json
{
  "status": "ok",
  "bridge": "home-agent-bridge",
  "version": "2.0.0",
  "uptime_seconds": 3600,
  "total_received": 42,
  "total_processed": 38,
  "total_expired": 1,
  "error_count": 0,
  "queue_len": 3,
  "oldest_message_age_seconds": 120,
  "agents": ["openclaw", "hermes"],
  "last_activity": "2026-05-11T15:30:00+00:00"
}
```

### POST /message

Send a message. Body:

```json
{
  "text": "Your message text",
  "from": "agent-name",
  "to": "recipient-agent",
  "type": "task",
  "expires_at": "2026-05-12T00:00:00+00:00"
}
```

All fields except `text` are optional. `type` defaults to `""` (empty string). Valid types: `health_check`, `proposal`, `task`, `response`, `note`, `alert`.

Response: `{"status": "queued", "id": "abc12345"}`

### GET /messages

Get pending messages. Optional query params:
- `for=<agent>` — filter by recipient
- `type=<type>` — filter by message type

Response:

```json
{
  "messages": [
    {
      "id": "abc12345",
      "text": "hello",
      "from": "openclaw",
      "to": "hermes",
      "type": "task",
      "time": "2026-05-11T15:00:00+00:00",
      "expires_at": ""
    }
  ],
  "count": 1
}
```

### DELETE /message/{id}?by=<agent>

Acknowledge and remove a single message. Query param `by` identifies the acknowledging agent.

Response: `{"status": "removed", "acknowledged_by": "hermes", "acknowledged_at": "2026-05-11T15:05:00+00:00"}`

### POST /messages/ack

Batch acknowledge multiple messages. Body:

```json
{
  "ids": ["abc12345", "def67890", "ghi11111"],
  "by": "hermes"
}
```

Maximum 100 IDs per request. All-or-nothing: if any ID doesn't exist, no messages are removed.

Response:

```json
{
  "acknowledged": ["abc12345", "def67890", "ghi11111"],
  "not_found": [],
  "acknowledged_at": "2026-05-11T15:05:00+00:00"
}
```

## Queue Files

Messages are stored as JSONL files in `/tmp/agent-bridge/`:

- `incoming.jsonl` — all queued messages (from, text, time, id, to, type, expires_at)
- `processed.jsonl` — acknowledged messages (archived daily)
- `stats.jsonl` — cumulative statistics
- `queue.lock` — lock file for atomic operations

Processed entries are archived daily via `bridge-log-rotate.sh` (runs as a cron job) and stored in gzip archives with configurable retention (default: 7-day live, 30-day archive).

## Polling Scripts

Hermes uses a polling script (`bridge-poller-hermy.sh`) to receive messages in real-time. This script runs every minute via cron, polls the bridge for messages addressed to "hermy", and forwards them to Telegram.

### bridge-poller-hermy.sh (Hermes side)

```
*/1 * * * * export TELEGRAM_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN /home/ale/.hermes/.env | cut -d= -f2)" && export TELEGRAM_CHAT_ID="$(grep TELEGRAM_HOME_CHANNEL /home/ale/.hermes/.env | cut -d= -f2)" && /home/ale/.hermes/scripts/bridge-poller-hermy.sh > /dev/null 2>&1
```

Features:
- Polls `GET /messages?to=hermy` every minute
- Forwards messages to Telegram (chat ID from `~/.hermes/.env`)
- Rate-limited to 1 message per 30 seconds (prevents flooding)
- Idempotent via `flock` (prevents duplicate sends)
- Leaves messages in queue if Telegram fails (retry on next poll)
- Logs to `/home/ale/.hermes/logs/bridge-poller.log`

### bridge-poll.sh (OpenClaw side)

Bobby uses a simpler poller at `/tmp/bridge-poll.sh`:
```
*/1 * * * * /tmp/bridge-poll.sh > /dev/null 2>&1
```

Both pollers ensure bidirectional real-time communication between the two agents.

## Version

Current version: `2.0.1` — see `VERSION` file in repo.

## Security Notes

- Server binds to `127.0.0.1` — only accessible from the local machine
- No authentication on endpoints — relies on network isolation
- Queue files stored in `/tmp/agent-bridge/` with `0700` permissions (owner-only read/write)
- Messages stored as JSONL — not encrypted at rest
- **Not intended for internet exposure** — designed for air-gapped home networks

## Why Not Use...?

| Approach | Why Home Agent Bridge is Better |
|----------|--------------------------------|
| REST API between gateways | Both OpenClaw and Hermes use WebSocket-only gateways — no HTTP API exposed |
| MCP (Model Context Protocol) | No existing bridge implementation between different agent frameworks |
| Polling shared files | Works but has minutes of latency; HTTP bridge is real-time |
| Cloud messaging (Slack/Discord) | Requires internet, introduces dependencies and latency |
| Direct agent spawning (ACP) | Only works between agents of the same framework |

## License

MIT — use it freely, contribute improvements.

## Contributing

PRs welcome — the goal is to make multi-agent home setups accessible to everyone.
