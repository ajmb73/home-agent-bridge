# Home Agent Bridge

A lightweight HTTP bridge that enables two different AI agent frameworks — [OpenClaw](https://github.com/nousresearch/openclaw) (Bobby) and [Hermes Agent](https://hermes-agent.nousresearch.com/) — to communicate with each other on the same home server, in real-time, without cloud dependencies.

## The Problem

Home server enthusiasts often run multiple AI agents for different tasks (home automation, coding, research, etc.). These agents are built on different frameworks and don't natively talk to each other. Existing solutions require cloud services, complex infrastructure, or custom integrations that break on every update.

## The Solution: Two-Stage Inbox Pipeline

Home Agent Bridge provides a simple HTTP message queue with a **two-stage pipeline** that ensures no messages are lost:

```
                ┌────────────────────────────────────────────┐
                │              Bridge Server                 │
                │         (127.0.0.1:18473)                  │
                │  ┌─────────────────────────────────────┐   │
                │  │  Stage 1: Queue (JSONL files)       │   │
                │  │  Messages survive restarts           │   │
                │  └─────────────────────────────────────┘   │
                └────────────────────────────────────────────┘
                           ▲            │
                  POST /message    GET /messages
                           │            ▼
                ┌────────────────────────────────────────────┐
                │         Dumb Bash Pollers (every 1 min)    │
                │  Stage 2: Write to persistent JSONL inbox  │
                │  + set .bridge-pending flag, ACK bridge    │
                └────────────────────────────────────────────┘
                           │            │
                           ▼            ▼
                ┌────────────────────────────────────────────┐
                │      LLM Agent Processors (every 10 min)   │
                │  Read inbox → trigger agent → respond via  │
                │  bridge HTTP POST → mark processed         │
                └────────────────────────────────────────────┘
```

### Architecture Decision: Two Dumb Pollers vs One Smart Agent

The previous architecture (v1 File Bridge, v2 SQLite Bus) used LLM-powered pollers that created feedback loops — one agent responded to its own messages. The current design uses a **deliberate separation**:

- **Dumb pollers** (bash scripts, no LLM) — just move messages from bridge to persistent inbox
- **LLM processors** (triggered by cron) — read the inbox, understand, respond, and mark processed
- Messages are never destroyed until the LLM agent explicitly marks them as `processed_by`

### Key Insight: What Broke Before (Fixed Jun 10 2026)

The original dumb pollers had a critical bug: they **acked messages from the bridge queue** immediately after logging them to a daily memory file, without ever handing them to the LLM agent. The message went: bridge → logged → acked → gone, silently. When the agent checked the bridge, it saw nothing.

The fix: pollers now write to a **machine-readable JSONL inbox file** before acking. A separate cron-driven processor reads the inbox and triggers the agent.

## Features

- **Framework-agnostic**: Works with any AI agent that can make HTTP POST requests
- **Responsive**: Sub-second latency when pollers run every minute
- **No message loss**: Two-stage architecture ensures agent sees every message
- **Secure**: Binds to localhost only — not exposed to the internet
- **Stateless**: Messages queued in JSONL files — survives restarts
- **Batch operations**: Acknowledge multiple messages in a single request (v2.0.0)
- **E2E encryption**: Optional Fernet encryption of message text at rest (v2.1.0)

## Requirements

- Python 3.8+
- Both agents running on the same machine (or same local network)
- Auth token file at `/tmp/agent-bridge/auth_token` (auto-generated on first server start)

## Quick Start

### 1. Start the bridge server

The server auto-generates an auth token on first start. Subsequent calls must include it.

```bash
# Navigate to the scripts directory
cd /home/ale/.hermes/scripts

# Start the bridge server (default port: 18473)
python3 agent-bridge-server.py --port 18473 &

# Verify it's running
curl http://127.0.0.1:18473/status
# → {"status": "ok", "bridge": "home-agent-bridge", "version": "2.0.2", ...}

# Auth token is at:
cat /tmp/agent-bridge/auth_token
```

### 2. Send a message (auth required)

All endpoints except `GET /status` require the `x-agent-token` header:

```bash
curl -X POST http://127.0.0.1:18473/message \
  -H "Content-Type: application/json" \
  -H "x-agent-token: $(cat /tmp/agent-bridge/auth_token)" \
  -d '{"text":"hello from bobby", "from":"bobby", "to":"hermy"}'
```

### 3. Poll for messages

Messages are filtered by default — `to=""` broadcast messages are excluded from agent-specific queries. Use `?include_broadcast=true` to include them.

```bash
# Get messages for hermy
curl "http://127.0.0.1:18473/messages?for=hermy" \
  -H "x-agent-token: $(cat /tmp/agent-bridge/auth_token)"

# Include broadcast messages (to="")
curl "http://127.0.0.1:18473/messages?for=hermy&include_broadcast=true" \
  -H "x-agent-token: $(cat /tmp/agent-bridge/auth_token)"

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
│   │  Bridge Server (127.0.0.1:18473)                    │   │
│   │  ├── GET /status        → health + stats            │   │
│   │  ├── POST /message      → queue message             │   │
│   │  ├── GET /messages      → list pending messages     │   │
│   │  ├── DELETE /message/<id> → ack single message      │   │
│   │  └── POST /messages/ack → batch ack                 │   │
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

Get pending messages. **Auth required** (except `/status`). Optional query params:
- `for=<agent>` — filter by recipient
- `type=<type>` — filter by message type
- `include_broadcast=true` — include broadcast messages (to="")

Response:

```json
{
  "messages": [
    {
      "id": "abc12345",
      "text": "hello",
      "from": "bobby",
      "to": "hermy",
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

Maximum 100 IDs per request. Partial processing: any IDs that don't exist are returned in `not_found`, the rest are still acked.

Response:

```json
{
  "acknowledged": ["abc12345", "def67890"],
  "not_found": ["ghi11111"],
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

## Two-Stage Pipeline: Pollers + Processors

### Stage 1: Dumb Pollers (every 1 min)

Both agents have bash pollers that run every minute via system cron. They are intentionally **dumb** (no LLM) to avoid feedback loops:

**Hermes side** — `bridge-poller-hermy.sh`:
- Polls `GET /messages?for=hermy` from the bridge
- Writes each message to:
  - Machine-readable JSONL: `~/.hermes/bridge-inbox.jsonl`
  - Human-readable log: `~/.hermes/bridge-inbox.md`
  - Daily memory: `~/.hermes/memory/YYYY-MM-DD.md`
- Sets `.bridge-pending` flag (timestamp)
- Acks the message from the bridge queue
- Logs to `~/.hermes/logs/bridge-poller.log`

**OpenClaw side** — `bobby-http-poller.sh`:
- Polls `GET /messages?for=bobby` from the bridge
- Writes each message to:
  - Machine-readable JSONL: `~/clawd/bridge-inbox.jsonl`
  - Daily memory: `~/clawd/memory/YYYY-MM-DD.md`
- Sends a receipt back via bridge POST
- Sets `.bridge-inbox-pending` flag
- Acks the message from the bridge queue
- Logs to `~/clawd/logs/bobby-http-poller.log`

### Stage 2: Agent Processors

**OpenClaw side** — `bridge-inbox-processor.sh` (every 10 min via cron):
- Reads `~/clawd/bridge-inbox.jsonl` for unprocessed messages
- Triggers Bobby's agent via `hermes chat -q` with instructions to:
  1. Read and understand each message
  2. Send a meaningful response back via bridge HTTP POST
  3. Mark inbox line as `processed_by: "bobby"`
- Clears the pending flag on completion
- Logs to `~/clawd/logs/bridge-inbox-processor.log`

### Key Files

| File | Purpose |
|------|---------|
| `~/clawd/bridge-inbox.jsonl` | Bobby's machine-readable inbox |
| `~/.hermes/bridge-inbox.jsonl` | Hermy's machine-readable inbox |
| `~/.hermes/bridge-inbox.md` | Hermy's human-readable inbox log |
| `~/clawd/.bridge-inbox-pending` | Pending flag (Bobby side) |
| `~/.hermes/.bridge-pending` | Pending flag (Hermy side) |

### Cron Jobs

```bash
# Bobby's poller (every 1 min)
*/1 * * * * /home/ale/scripts/bobby-http-poller.sh

# Hermy's poller (every 1 min)
*/1 * * * * /home/ale/.hermes/scripts/bridge-poller-hermy.sh

# Bobby's inbox processor (every 10 min)
*/10 * * * * /home/ale/scripts/bridge-inbox-processor.sh >> /home/ale/clawd/logs/bridge-inbox-processor.log
```

## Version

Current version: `2.1.0` — see `VERSION` file in repo.

## Changelog

### 2.1.0 (Jun 10 2026)
- **Two-stage inbox pipeline**: Pollers now write to persistent JSONL inbox instead of just acking
- **Bridge inbox processor**: New `bridge-inbox-processor.sh` cron to trigger agent message processing
- **No message loss**: Fixed bug where pollers acked messages before LLM agents could read them
- **E2E encryption**: Fernet encryption for message text at rest (v2.1.0 bridge server)

## Security Notes

- Server binds to `127.0.0.1` — only accessible from the local machine
- All endpoints except `GET /status` require `x-agent-token` header (token stored in `/tmp/agent-bridge/auth_token`)
- Token validated with `secrets.compare_digest` (timing-safe)
- Broadcast messages (`to=""`) excluded from agent-specific queries by default — prevents cross-contamination
- Message text capped at 10KB — prevents unbounded payload attacks
- SSRF protection: callback hostnames resolved to IP before checking `127.0.0.0/8`
- Queue files in `/tmp/agent-bridge/` with `0700` permissions (owner-only)
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
