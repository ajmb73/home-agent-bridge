# Home Agent Bridge — v2 Plan

**Version:** 1.0
**Date:** May 8, 2026
**Status:** Planning

---

## Goal

Extend home-agent-bridge from a localhost-only, two-agent setup to a secure, multi-agent communication layer that works across different networks — home to cloud, cloud to cloud, and meshed home networks.

---

## Principles

1. **No breaking changes to v1** — v1 server keeps running on localhost; v2 is additive
2. **E2E encryption everywhere** — relay never sees plaintext
3. **Tailscale-first** — use direct connections when both agents are on tailnet
4. **Cloud relay fallback** — for agents without Tailscale, a separate relay installer
5. **Simple by default** — local-only should stay trivially simple to deploy

---

## Phase 1: E2E Encryption Layer on v1 (Weekend Project)

**Goal:** Add encryption to v1 without changing the protocol or architecture.

### Changes

**New dependency:** `cryptography` Python library (Fernet — AES-CBC with HMAC, key from env var)

**New env vars:**
- `BRIDGE_ENCRYPTION_KEY` — 32-byte base64-encoded key, generated once and shared between agents

**Agent bridge server changes:**
- `POST /message` — encrypt payload before writing to queue: `{"id":"...", "from":"agent", "encrypted": "base64-fernet-ciphertext", "iv": "..."}`
- `GET /messages` — decrypt payload before returning

**Key distribution:** Out-of-band — agents get the key via a secure channel (SSH copy, Tailscale file sharing, etc.). No key exchange protocol needed for v1.

**New skill:** `agent-bridge-encrypted` — documents how to generate a key and configure both agents.

### Security Properties

- Queue files contain only encrypted payloads — anyone reading `/tmp/agent-bridge/` sees only ciphertext
- Relay still sees metadata: who talks to whom, when, how often, message size
- No auth change — still network-isolated localhost

### Version bump

Since this is a meaningful security improvement, bump: `1.158-2` → `1.258-1`

---

## Phase 2: Cloud Relay Server (Separate Installer)

**Goal:** A lightweight, publicly-hosted relay that any agent with internet access can use.

### Components

**Relay server:**
- Single Python file or small Go binary (~300-500 lines)
- Runs on a cheap VPS or Cloudflare Worker
- WebSocket endpoint for persistent connections
- HTTPS endpoint for agents that can't maintain long connections
- **No message storage** — relay is stateless, messages pass through only
- Agent registry: which agents are connected, heartbeat tracking
- Rate limiting per agent

**Relay installer:** `setup/relay-setup.sh`
- One command to deploy relay to a new VPS
- Generates per-relay API key
- Configures systemd service or Docker

**Protocol:**
```
Agent connects → WebSocket upgrade
Agent sends: {"type": "register", "agent_id": "...", "api_key": "..."}
Agent sends: {"type": "message", "to": "agent-id", "payload": "encrypted-envelope"}
Relay forwards to destination agent (or queues briefly if offline)
```

### Security Properties

- Relay never stores messages — purely a forwarder
- All payloads E2E encrypted — relay sees only encrypted envelopes
- Agents authenticate with API key issued by relay operator
- Rate limiting prevents abuse
- Relay operator sees: traffic volume per agent, connection times, message frequency — but NOT content

### Open Questions

1. **Key distribution for relay agents** — how does a new agent get an encryption key? Options:
   - Pre-shared key via relay operator (trust chain)
   - Diffie-Hellman through relay (relay witnesses key exchange, could MITM — acceptable for threat model)
   - Tailscale magical tailnet key distribution (if both on Tailscale)

2. **Cloud provider** — where should the relay run?
   - $5 VPS (Hetzner, DigitalOcean) — simplest
   - Cloudflare Worker — globally distributed, cheap, but limited compute
   - Fly.io — edge deployment, easy scaling

3. **Relay discovery** — how do agents find the relay?
   - Hardcoded URL in config (simplest)
   - DNS SRV record
   - Relay operator provides relay URL

### Version bump

Separate from main bridge version — relay server is its own component. Maybe `relay v0.1.0`.

---

## Phase 3: Tailscale Integration

**Goal:** Agents on the same tailnet connect directly without relay.

### Changes

- Agent config gets a `tailscale: true` flag
- On startup, agent queries Tailscale API for peer IPs of other registered agents
- If both agents on same tailnet: connect directly via `https://<agent>.tailnet.ts.net:18473`
- If different tailnets: fall back to cloud relay

### Requirements

- Tailscale API key stored in agent config
- Both agents must be on Tailscale
- Network-level: Tailscale ACLs must allow the connection

---

## Phase 4: Multi-Agent Discovery

**Goal:** Support more than 2 agents in the mesh.

### Changes

- Agents register with capabilities on connect: `{"agent_id": "hermes-home", "capabilities": ["chat", "tools"]}`
- Relay maintains a registry: `agent_id → (connection_info, capabilities)`
- Agents can query registry: `GET /agents` → list of available agents
- Routing: agents address each other by ID, relay handles delivery

### Open Question

How do agents learn each other's IDs? Manual config in v1. Discovery in v2 via relay registry.

---

## Immediate Weekend Tasks

- [ ] **E2E encryption for v1** — Fernet encryption on payloads, `BRIDGE_ENCRYPTION_KEY` env var, update skill
- [ ] **Generate and document key generation** — `python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"`
- [ ] **Update setup script** — prompt for encryption key during setup
- [ ] **Write `agent-bridge-encrypted` skill** — for users who want E2E encryption on localhost
- [ ] **Update `VERSION`** — bump to `1.258-1`
- [ ] **Write `v2-plan-relay.md`** — detailed relay server spec for later implementation

---

## Open Questions for Discussion

1. Should the relay be a separate GitHub repo (`home-agent-bridge-relay`) or part of the same one?
2. Who operates the relay? Self-hosted by each user, or a shared public relay with API key issuance?
3. Do we need message acknowledgement / delivery receipts?
4. Should the relay support ephemeral messages (no log on relay) or always store briefly for offline delivery?

---

## References

- Current repo: https://github.com/ajmb73/home-agent-bridge
- Cryptography lib: https://cryptography.io/en/latest/fernet/
- Fernet spec: https://github.com/fernet/spec