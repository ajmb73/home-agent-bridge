---
name: agent-bridge
description: OpenClaw Agent skill for inter-agent communication with Hermes Agent via the home-agent-bridge HTTP server (localhost:18473). Use when you need to send messages to or coordinate with Hermes Agent.
trigger: "When you need to communicate with Hermes Agent, send a task, or request coordination"
---

# agent-bridge — OpenClaw Agent → Hermes Agent Communication

## Overview

This skill enables OpenClaw Agent to send messages to and receive responses from Hermes Agent using the home-agent-bridge HTTP server running at `localhost:18473`.

## Prerequisites

- Home agent bridge server running on port 18473 (`python3 agent-bridge-server.py --port 18473`)
- SSH access to the machine where Hermes Agent runs

## Communication Pattern

### Send a message to Hermes Agent

```bash
curl -X POST http://127.0.0.1:18473/message \
  -H "Content-Type: application/json" \
  -d '{"text": "your message here", "from": "openclaw"}'
```

### Poll for pending messages (Hermes → OpenClaw)

```bash
curl http://127.0.0.1:18473/messages
```

### Acknowledge a message

```bash
curl -X DELETE http://127.0.0.1:18473/message/<id>
```

## Fallback: Shared File Pattern

If the HTTP bridge is unavailable, use shared files:

**OpenClaw → Hermes:** Write to `/tmp/hermy-to-bobby.md`, then invoke Hermes via SSH:
```bash
ssh ale@ai.home "~/.hermes/hermes-agent/venv/bin/hermes chat -q 'Read /tmp/hermy-to-bobby.md' -Q --max-turns 5"
```

**Hermes → OpenClaw:** Write to `/tmp/bobby-to-hermy.md`, poll via Hermes skill.

## Health Check

```bash
curl http://127.0.0.1:18473/status
# → {"status": "ok", "bridge": "home-agent-bridge", "queue_len": N}
```

## Limitations

- No direct OpenClaw agent-to-agent RPC between frameworks
- No MCP bridge
- No REST/HTTP API between gateways
- Communication requires SSH to ai.home for the fallback path

## Files

- Bridge server: `~/.hermes/scripts/agent-bridge-server.py`
- Queue directory: `/tmp/agent-bridge/`
- Incoming messages: `/tmp/agent-bridge/incoming.jsonl`
- Processed log: `/tmp/agent-bridge/processed.jsonl`