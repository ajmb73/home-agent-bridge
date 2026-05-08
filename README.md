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

## Requirements

- Python 3.8+
- Both agents running on the same machine (or same local network)
- SSH access between agents (for Hermes CLI invocations)

## Quick Start

### 1. Install the bridge server

```bash
# Clone the repo
git clone https://github.com/ajmb73/home-agent-bridge.git
cd home-agent-bridge

# Start the bridge server
python3 agent-bridge-server.py --port 18473 &

# Verify it's running
curl http://127.0.0.1:18473/status
# → {"status": "ok", "bridge": "home-agent-bridge"}
```

### 2. Configure the OpenClaw Agent side

Add to your OpenClaw agent's communication skill:

```bash
curl -X POST http://127.0.0.1:18473/message \
  -H "Content-Type: application/json" \
  -d '{"text":"your message here", "from":"openclaw"}'
```

### 3. Configure the Hermes Agent side

Add to your Hermes agent's communication skill:

```bash
# Poll for messages
curl http://127.0.0.1:18473/messages

# Acknowledge processed messages
curl -X DELETE http://127.0.0.1:18473/message/<id>
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
│   │  Bridge Server (127.0.0.1:18473)                    │   │
│   │  ├── POST /message   → queue to incoming.jsonl      │   │
│   │  ├── DELETE /message/<id> → acknowledge             │   │
│   │  └── GET /status    → health check                  │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## API Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/status` | Health check. Returns `{"status": "ok", "bridge": "home-agent-bridge", "queue_len": N}` |
| `POST` | `/message` | Send a message. Body: `{"text": "...", "from": "agent-name"}`. Returns `{"status": "queued", "id": "..."}` |
| `GET` | `/messages` | Get all pending messages. Returns `{"messages": [...]}` |
| `DELETE` | `/message/<id>` | Acknowledge and remove a message. Returns `{"status": "removed"}` |

## Queue Files

Messages are stored as JSONL files in `/tmp/agent-bridge/`:

- `incoming.jsonl` — all queued messages (from, text, time, id)
- `processed.jsonl` — acknowledged messages (archived daily)
- `queue.lock` — lock file for atomic operations

Processed entries are archived daily via `bridge-log-rotate.sh` (runs as a cron job) and stored in gzip archives with configurable retention (default: 7-day live, 30-day archive).

## Version

Current version: `1.158-2` (see `VERSION` file in repo). Calendar versioning: `Y.MMDD-N`.

## Security Notes

- Server binds to `127.0.0.1` — only accessible from the local machine
- No authentication on endpoints — relies on network isolation
- Queue files stored in `/tmp/agent-bridge/` with `0700` permissions (owner-only read/write)
- Messages stored as JSONL — not encrypted at rest
- **Not intended for internet exposure** — designed for air-gapped home networks

## Why Not Use...?

| Approach | Why Home Agent Bridge is Better |
|----------|-------------------------------|
| REST API between gateways | Both OpenClaw and Hermes use WebSocket-only gateways — no HTTP API exposed |
| MCP (Model Context Protocol) | No existing bridge implementation between different agent frameworks |
| Polling shared files | Works but has minutes of latency; HTTP bridge is real-time |
| Cloud messaging (Slack/Discord) | Requires internet, introduces dependencies and latency |
| Direct agent spawning (ACP) | Only works between agents of the same framework |

## License

MIT — use it freely, contribute improvements.

## Contributing

PRs welcome — the goal is to make multi-agent home setups accessible to everyone.
