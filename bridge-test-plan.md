# Bridge Test Plan — v2.0.1

**Last updated:** 2026-05-13  
**Bridge:** http://localhost:18473 | Server uptime: 81.9h | Errors: 0 | Queue: 0  
**Branch:** experimental/refactor

---

## Architecture

```
OpenClaw Agent (Bobby) ──── POST/DELETE ────► Bridge Server (port 18473) ◄── GET/poll ──── Hermes Agent (Hermy)
         │                                             │                              │
         │◄─── /tmp/hermy-to-bobby.md ◄─────────────── Bobby's poller                   │
         │                                                    │                          │
         ▼                                                    ▼                          ▼
   reads messages                                      deletes after read          Telegram push via
   writes responses                                                                bridge-poller-hermy.sh
   to bridge via POST                                                                 (rate-limited 30s)
```

---

## Prerequisites

```bash
# Verify bridge is running
curl -s http://localhost:18473/status | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'OK - Queue:{d[\"queue_len\"]} Errors:{d[\"error_count\"]} Uptime:{d[\"uptime_seconds\"]}s')"

# Verify both pollers in crontab
crontab -l | grep bridge

# Verify both poller scripts exist
ls -la /tmp/bridge-poll.sh /home/ale/.hermes/scripts/bridge-poller-hermy.sh
```

Expected output: bridge OK, both pollers in crontab, both scripts exist.

---

## TEST 1: Bridge Server Health

**Goal:** Verify bridge API is responding correctly.

```bash
# Test all endpoints
curl -s http://localhost:18473/status | python3 -m json.tool | head -20

# Expected: {"status": "ok", "bridge": "home-agent-bridge", "version": "2.0.0", ...}
```

**Pass criteria:** Status 200, JSON with `status: ok`, `queue_len: 0`, `error_count: 0`

---

## TEST 2: Hermy → Bobby (file delivery)

**Goal:** Verify Hermy can send a message to Bobby via the bridge, and Bobby's poller picks it up.

**Steps:**
1. Hermy sends a test message via bridge:
   ```bash
   curl -s -X POST http://localhost:18473/message \
     -H "Content-Type: application/json" \
     -d '{"from":"hermy","to":"bobby","type":"note","text":"[TEST 2] Hermy to Bobby test message"}'
   ```
2. Verify message is in bridge queue:
   ```bash
   curl -s "http://localhost:18473/messages?to=bobby" | python3 -c "import sys,json; d=json.load(sys.stdin); msgs=d.get('messages',[]); print(f'Messages for Bobby: {len(msgs)}'); [print(f'  {m[\"id\"]} - {m[\"text\"][:60]}') for m in msgs]"
   ```
3. Wait up to 2 minutes for Bobby's cron to fire (runs every 1 min)
4. Check Bobby's file:
   ```bash
   cat /tmp/hermy-to-bobby.md | tail -5
   ```
5. Verify message was deleted from bridge:
   ```bash
   curl -s "http://localhost:18473/messages?to=bobby" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Remaining for Bobby: {len(d.get(\"messages\",[]))}')"
   ```

**Pass criteria:** Message appears in `/tmp/hermy-to-bobby.md`, then queue is empty.

---

## TEST 3: Bobby → Hermy (Telegram delivery)

**Goal:** Verify Bobby can send a message to Hermy via the bridge, and Hermy's poller delivers it to Telegram.

**Steps:**
1. Bobby (or test harness) sends a message via bridge:
   ```bash
   curl -s -X POST http://localhost:18473/message \
     -H "Content-Type: application/json" \
     -d '{"from":"bobby","to":"hermy","type":"note","text":"[TEST 3] Bobby to Hermy test message"}'
   ```
2. Wait up to 2 minutes for Hermy's cron to fire
3. Check Hermy's Telegram — message should arrive
4. Verify queue is empty:
   ```bash
   curl -s "http://localhost:18473/messages?to=hermy" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Messages for Hermy: {len(d.get(\"messages\",[]))}')"
   ```

**Pass criteria:** Message arrives in Telegram DM with Ale, queue is empty.

---

## TEST 4: Message Type Filtering

**Goal:** Verify `type` field routing works correctly.

**Steps:**
1. Send a `health_check` message:
   ```bash
   curl -s -X POST http://localhost:18473/message \
     -H "Content-Type: application/json" \
     -d '{"from":"hermy","to":"bobby","type":"health_check","text":"[TEST 4] Health check ping"}'
   ```
2. Fetch all messages:
   ```bash
   curl -s "http://localhost:18473/messages?for=bobby&type=health_check" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Health checks for Bobby: {len(d.get(\"messages\",[]))}')"
   ```
3. Send a `task` type message and verify it also routes correctly

**Pass criteria:** Messages with correct `type` are returned by filtered queries.

---

## TEST 5: Bidirectional Stress Test

**Goal:** Verify no message loss under rapid back-and-forth.

**Steps:**
1. Send 5 messages rapidly from Hermy to Bobby:
   ```bash
   for i in $(seq 1 5); do
     curl -s -X POST http://localhost:18473/message \
       -H "Content-Type: application/json" \
       -d "{\"from\":\"hermy\",\"to\":\"bobby\",\"type\":\"note\",\"text\":\"[TEST 5-$i] Rapid fire message $i\"}";
   done
   ```
2. Wait 3 minutes for 3 cron cycles
3. Count messages delivered to Bobby:
   ```bash
   grep -c "TEST 5" /tmp/hermy-to-bobby.md
   ```
4. Verify queue is empty (all 5 processed):
   ```bash
   curl -s "http://localhost:18473/messages?to=bobby" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Queue for Bobby: {len(d.get(\"messages\",[]))}')"
   ```

**Pass criteria:** All 5 messages in Bobby's file, queue at 0.

---

## TEST 6: Rate Limit Behavior (Hermy → Telegram)

**Goal:** Verify Hermy's 30-second rate limit doesn't cause message loss.

**Steps:**
1. Send 4 messages from Bobby to Hermy rapidly:
   ```bash
   for i in $(seq 1 4); do
     curl -s -X POST http://localhost:18473/message \
       -H "Content-Type: application/json" \
       -d "{\"from\":\"bobby\",\"to\":\"hermy\",\"type\":\"note\",\"text\":\"[TEST 6-$i] Rate limit test $i\"}";
   done
   ```
2. Wait 3 minutes — rate limit is 30s, so 4 messages should all arrive within 2.5 min
3. Check Telegram — all 4 messages should arrive
4. Verify queue empty:
   ```bash
   curl -s "http://localhost:18473/messages?to=hermy" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Queue for Hermy: {len(d.get(\"messages\",[]))}')"
   ```

**Pass criteria:** All 4 messages delivered to Telegram, queue at 0.

---

## TEST 7: Poller Recovery After Failure

**Goal:** Verify messages don't pile up if a poller is temporarily down.

**Steps:**
1. Stop Hermy's poller (simulate outage):
   ```bash
   crontab -l | grep -v bridge-poller-hermy > /tmp/crontab_backup && crontab -l | grep -v bridge-poller-hermy > /tmp/crontab_backup
   crontab -l | grep -v bridge-poller-hermy > /tmp/crontab_nopoller
   ```
2. Send 3 messages as Bobby → Hermy
3. Wait 5 minutes (messages accumulate in queue)
4. Restart Hermy's poller:
   ```bash
   # Restore from backup would be: crontab /tmp/crontab_backup
   ```
5. Wait 4 minutes — poller should drain all 3 messages
6. Verify queue is 0 and all 3 Telegram messages received

**Pass criteria:** All accumulated messages delivered after recovery.

---

## Failure Codes and Diagnosis

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Queue grows, Bobby never receives | Bobby's poller not in crontab | Add `*/1 * * * * /tmp/bridge-poll.sh` |
| Queue grows, Hermy never receives | Hermy's poller not in crontab | Add Hermy cron with env vars |
| Messages in queue forever | Poller can't DELETE (script bug) | Check poller delete logic |
| Bridge returns 500 | Server crashed | `kill -9` and restart server |
| Telegram flooding | Rate limit not working | Check RATE_LIMIT_SECONDS in poller |

---

## Verification Checklist (run after any bridge change)

```bash
# 1. Bridge health
curl -s http://localhost:18473/status | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='ok', 'Bridge down'; assert d['error_count']==0, 'Bridge has errors'; print('Bridge: OK')"

# 2. Queue clean
curl -s http://localhost:18473/status | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['queue_len']==0, f'Queue has {d[\"queue_len\"]} messages'; print('Queue: CLEAN')"

# 3. Both pollers in crontab
assert 'bridge-poll.sh' in open('/dev/stdin').read(), 'Bobby poller missing' # run manually
crontab -l | grep -q bridge-poller-hermy && echo "Hermy poller: OK" || echo "Hermy poller: MISSING"
crontab -l | grep -q 'bridge-poll.sh' && echo "Bobby poller: OK" || echo "Bobby poller: MISSING"

# 4. Bridge server process alive
ps aux | grep -q '[a]gent-bridge-server' && echo "Server process: OK" || echo "Server: DOWN"
```

---

## Schedule

Run full test suite:
- After any poller or bridge code change
- Weekly health check (every Sunday)
- After any system update that might affect cron
