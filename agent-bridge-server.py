#!/home/ale/.hermes/hermes-agent/venv/bin/python3
"""
home-agent-bridge v2.0.0: Lightweight HTTP queue for inter-agent communication.
Supports Bobby (OpenClaw) and Hermy (Hermes) messaging.

v2 Features:
  - Structured health endpoint: GET /status returns uptime, counters, queue age
  - Batch acknowledgement: POST /messages/ack for multi-ID acks
  - Message types: health_check, proposal, task, response, note, alert, ""

Usage:
    python3 agent-bridge-server.py [--port 18473] [--host 127.0.0.1]

Endpoints:
    POST /message       — Send a message
    GET /messages      — Get pending messages (?for=<agent>&type=<type>)
    DELETE /message/<id>?by=<agent>  — Acknowledge single message
    POST /messages/ack — Batch acknowledge multiple messages
    GET /status        — Structured health + stats
"""

import os
import re
import json
import uuid
import argparse
import fcntl
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

try:
    from fastapi import FastAPI, HTTPException, Request, Query
    import uvicorn
    HAS_FASTAPI = True
except ImportError:
    HAS_FASTAPI = False

QUEUE_DIR = Path("/tmp/agent-bridge")
QUEUE_DIR.mkdir(exist_ok=True, mode=0o700)
MESSAGE_FILE = QUEUE_DIR / "incoming.jsonl"
PROCESSED_FILE = QUEUE_DIR / "processed.jsonl"
STATS_FILE = QUEUE_DIR / "stats.jsonl"
CONFIG_FILE = QUEUE_DIR / "port.txt"
LOCK_FILE = QUEUE_DIR / "queue.lock"
MAX_BODY_SIZE = 64 * 1024  # 64KB max request body

DEFAULT_TTL_SECONDS = 7 * 24 * 3600  # 7 days

# Valid message types
VALID_MESSAGE_TYPES = frozenset(["health_check", "proposal", "task", "response", "note", "alert", ""])


class BridgeStats:
    """Tracks bridge health metrics."""

    def __init__(self):
        self.start_time = datetime.now(timezone.utc)
        self.total_received = 0
        self.total_processed = 0
        self.total_expired = 0
        self.error_count = 0
        self._load()

    def _load(self):
        """Load persisted stats on startup."""
        if STATS_FILE.exists():
            try:
                lines = STATS_FILE.read_text().strip().splitlines()
                if lines:
                    last = json.loads(lines[-1])
                    self.total_received = last.get("total_received", 0)
                    self.total_processed = last.get("total_processed", 0)
                    self.total_expired = last.get("total_expired", 0)
                    self.error_count = last.get("error_count", 0)
            except (json.JSONDecodeError, OSError):
                pass

    def save(self):
        """Persist stats to disk."""
        stats = {
            "total_received": self.total_received,
            "total_processed": self.total_processed,
            "total_expired": self.total_expired,
            "error_count": self.error_count,
        }
        try:
            with open(STATS_FILE, 'a') as f:
                f.write(json.dumps(stats) + '\n')
        except OSError:
            pass

    def uptime_seconds(self) -> int:
        delta = datetime.now(timezone.utc) - self.start_time
        return int(delta.total_seconds())

    def summary(self) -> dict:
        return {
            "total_received": self.total_received,
            "total_processed": self.total_processed,
            "total_expired": self.total_expired,
            "error_count": self.error_count,
        }


# Global stats instance
_stats = BridgeStats()


def get_default_port() -> int:
    """Read configured port or return default."""
    if CONFIG_FILE.exists():
        try:
            return int(CONFIG_FILE.read_text().strip())
        except (ValueError, FileNotFoundError):
            pass
    return 18473


def now_iso() -> str:
    """Return current UTC time as ISO string."""
    return datetime.now(timezone.utc).isoformat()


def acquire_lock():
    """Acquire exclusive lock on queue file."""
    lock_fd = open(LOCK_FILE, 'w')
    fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
    return lock_fd


def release_lock(lock_fd):
    """Release exclusive lock."""
    fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
    lock_fd.close()


def load_queue() -> list:
    """Load existing messages (caller must hold lock)."""
    if MESSAGE_FILE.exists():
        with open(MESSAGE_FILE) as f:
            return [json.loads(line) for line in f if line.strip()]
    return []


def save_queue(messages, lock_fd=None):
    """Save messages to queue file (caller must hold lock)."""
    # Note: lock_fd is accepted for API compatibility but the lock is caller-managed.
    with open(MESSAGE_FILE, 'w') as f:
        for m in messages:
            f.write(json.dumps(m) + '\n')


def is_expired(msg, now_fn=None) -> bool:
    """Check if a message has expired."""
    if now_fn is None:
        now_fn = lambda: datetime.now(timezone.utc)
    expires_at = msg.get("expires_at")
    if not expires_at:
        return False
    try:
        exp_time = datetime.fromisoformat(expires_at)
        if exp_time.tzinfo is None:
            exp_time = exp_time.replace(tzinfo=timezone.utc)
        return exp_time <= now_fn()
    except (ValueError, TypeError):
        return False


def prune_expired(messages, now_fn=None) -> tuple:
    """Remove expired messages. Returns (pruned_list, expired_count)."""
    if now_fn is None:
        now_fn = lambda: datetime.now(timezone.utc)
    before = len(messages)
    remaining = [m for m in messages if not is_expired(m, now_fn)]
    _stats.total_expired += before - len(remaining)
    return remaining, before - len(remaining)


def oldest_message_age_seconds(messages) -> int:
    """Compute age of oldest message in queue."""
    if not messages:
        return 0
    try:
        oldest = min(m["time"] for m in messages)
        ts = datetime.fromisoformat(oldest)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        delta = datetime.now(timezone.utc) - ts
        return int(delta.total_seconds())
    except (ValueError, TypeError, KeyError):
        return 0


def last_activity_time(messages) -> str:
    """Find most recent message timestamp (send or receive)."""
    if not messages:
        return now_iso()
    try:
        latest = max(m["time"] for m in messages)
        return latest
    except (ValueError, KeyError):
        return now_iso()


def validate_expires_at(expires_at: str) -> bool:
    """Validate expires_at is a valid ISO timestamp or empty. Returns True if valid."""
    if not expires_at:
        return True
    try:
        exp_time = datetime.fromisoformat(expires_at)
        if exp_time.tzinfo is None:
            exp_time = exp_time.replace(tzinfo=timezone.utc)
        return True
    except (ValueError, TypeError):
        return False


def add_message(text: str, from_agent: str, to_agent: str = "", expires_at: str = "",
                msg_type: str = "") -> dict:
    """
    Add a message to the queue with file locking.
    Prunes expired messages on write.
    Returns the new message dict.
    Raises ValueError on validation failure.
    """
    if not text or not text.strip():
        raise ValueError("Message text cannot be empty")
    if msg_type not in VALID_MESSAGE_TYPES:
        raise ValueError(f"Invalid message type: {msg_type!r}. Must be one of: {', '.join(sorted(VALID_MESSAGE_TYPES))}")
    if expires_at and not validate_expires_at(expires_at):
        raise ValueError(f"Invalid expires_at format: {expires_at!r}. Must be ISO8601.")

    msg = {
        "id": str(uuid.uuid4())[:8],
        "text": text.strip(),
        "from": from_agent,
        "to": to_agent,
        "type": msg_type,
        "time": now_iso(),
    }
    if expires_at:
        msg["expires_at"] = expires_at

    lock_fd = acquire_lock()
    try:
        messages = load_queue()
        now_fn = lambda: datetime.now(timezone.utc)
        messages, pruned_count = prune_expired(messages, now_fn)
        if pruned_count:
            save_queue(messages)
        messages.append(msg)
        save_queue(messages)
        _stats.total_received += 1
        _stats.save()
    finally:
        release_lock(lock_fd)
    return msg


def get_messages(for_agent: str = "", msg_type: str = "") -> list:
    """
    Get pending messages with file locking.
    Filter by recipient (for_agent) and/or message type.
    """
    lock_fd = acquire_lock()
    try:
        messages = load_queue()
        now_fn = lambda: datetime.now(timezone.utc)
        messages, _ = prune_expired(messages, now_fn)

        if for_agent:
            messages = [m for m in messages if m.get("to", "") == for_agent or m.get("to", "") == ""]
        if msg_type:
            messages = [m for m in messages if m.get("type", "") == msg_type]

        return messages
    finally:
        release_lock(lock_fd)


def remove_message(msg_id: str, acknowledged_by: str = "") -> tuple:
    """
    Remove a message by ID with file locking.
    Returns (success, ack_info).
    """
    lock_fd = acquire_lock()
    try:
        messages = load_queue()
        new_messages = [m for m in messages if m['id'] != msg_id]
        if len(new_messages) == len(messages):
            return False, {}
        save_queue(new_messages, lock_fd)
        ack_time = now_iso()
        ack_info = {
            "id": msg_id,
            "processed_at": ack_time,
        }
        if acknowledged_by:
            ack_info["acknowledged_by"] = acknowledged_by
        with open(PROCESSED_FILE, 'a') as f:
            f.write(json.dumps(ack_info) + '\n')
        _stats.total_processed += 1
        _stats.save()
        return True, ack_info
    finally:
        release_lock(lock_fd)


def batch_ack_messages(msg_ids: list, acknowledged_by: str) -> dict:
    """
    Acknowledge multiple messages in one call.
    Returns dict with acknowledged, not_found lists.
    All-or-nothing: only removes messages if ALL IDs exist.
    """
    if not msg_ids:
        return {"acknowledged": [], "not_found": [], "acknowledged_at": now_iso()}
    if not acknowledged_by:
        raise ValueError("acknowledged_by (by) is required for batch acknowledgement")

    acknowledged = []
    not_found = []

    lock_fd = acquire_lock()
    try:
        messages = load_queue()
        existing_ids = {m["id"] for m in messages}

        for mid in msg_ids:
            if mid not in existing_ids:
                not_found.append(mid)

        if not not_found:
            # All IDs exist — remove them all atomically
            remaining = [m for m in messages if m["id"] not in msg_ids]
            save_queue(remaining, lock_fd)
            acknowledged = list(msg_ids)

            ack_time = now_iso()
            for mid in acknowledged:
                ack_info = {"id": mid, "processed_at": ack_time, "acknowledged_by": acknowledged_by}
                with open(PROCESSED_FILE, 'a') as f:
                    f.write(json.dumps(ack_info) + '\n')
            _stats.total_processed += len(acknowledged)
            _stats.save()
        # else: some IDs not found — do nothing (all-or-nothing), return not_found list

    finally:
        release_lock(lock_fd)

    return {
        "acknowledged": acknowledged,
        "not_found": not_found,
        "acknowledged_at": now_iso(),
    }


def get_status() -> dict:
    """Return structured health endpoint response."""
    messages = get_messages()
    queue_len = len(messages)
    oldest_age = oldest_message_age_seconds(messages)
    last_act = last_activity_time(messages)

    # Discover known agents from queue
    agents = set()
    for m in messages:
        agents.add(m.get("from", ""))
        to = m.get("to", "")
        if to:
            agents.discard("")  # broadcast is not an agent
    agents.discard("")
    agents = sorted(agents)

    return {
        "status": "ok",
        "bridge": "home-agent-bridge",
        "version": "2.0.0",
        "uptime_seconds": _stats.uptime_seconds(),
        "total_received": _stats.total_received,
        "total_processed": _stats.total_processed,
        "total_expired": _stats.total_expired,
        "error_count": _stats.error_count,
        "queue_len": queue_len,
        "oldest_message_age_seconds": oldest_age,
        "agents": agents,
        "last_activity": last_act,
    }


if HAS_FASTAPI:
    app = FastAPI(title="Home Agent Bridge v2", description="HTTP bridge for inter-agent communication")

    @app.get("/status")
    async def status():
        return get_status()

    @app.post("/message")
    async def receive_message(request: Request, body: dict):
        content_len = request.headers.get("content-length")
        if content_len and int(content_len) > MAX_BODY_SIZE:
            raise HTTPException(status_code=413, detail="Request body too large")

        text = body.get("text", "")
        from_agent = body.get("from", "unknown")
        to_agent = body.get("to", "")
        expires_at = body.get("expires_at", "")
        msg_type = body.get("type", "")

        if not text or not text.strip():
            raise HTTPException(status_code=400, detail="Missing or empty 'text' field")
        if len(from_agent) > 256:
            raise HTTPException(status_code=400, detail="'from' field too long (max 256)")
        if len(to_agent) > 256:
            raise HTTPException(status_code=400, detail="'to' field too long (max 256)")
        if msg_type not in VALID_MESSAGE_TYPES:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid 'type': {msg_type!r}. Must be one of: {', '.join(sorted(VALID_MESSAGE_TYPES))}"
            )

        try:
            msg = add_message(text, from_agent, to_agent, expires_at, msg_type)
            return {"status": "queued", "id": msg["id"]}
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        except Exception as e:
            _stats.error_count += 1
            _stats.save()
            raise HTTPException(status_code=500, detail=str(e))

    @app.get("/messages")
    async def list_messages(
        for_agent: str = Query("", description="Filter messages for this recipient"),
        msg_type: str = Query("", description="Filter by message type")
    ):
        if msg_type and msg_type not in VALID_MESSAGE_TYPES:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid 'type': {msg_type!r}. Must be one of: {', '.join(sorted(VALID_MESSAGE_TYPES))}"
            )
        raw = get_messages(for_agent, msg_type)
        messages = [
            {
                "id": m["id"],
                "text": m["text"],
                "from": m["from"],
                "to": m.get("to", ""),
                "type": m.get("type", ""),
                "time": m["time"],
                "expires_at": m.get("expires_at", ""),
            }
            for m in raw
        ]
        return {"messages": messages, "count": len(messages)}

    @app.delete("/message/{msg_id}")
    async def acknowledge_message(msg_id: str, by: str = Query("", description="Agent acknowledging")):
        if not re.match(r'^[a-f0-9-]{8}$', msg_id):
            raise HTTPException(status_code=400, detail="Invalid message ID format")
        success, ack_info = remove_message(msg_id, by)
        if not success:
            raise HTTPException(status_code=404, detail="Message not found")
        response = {"status": "removed"}
        if ack_info.get("acknowledged_by"):
            response["acknowledged_by"] = ack_info["acknowledged_by"]
            response["acknowledged_at"] = ack_info["processed_at"]
        return response

    @app.post("/messages/ack")
    async def batch_acknowledge(request: Request, body: dict):
        """Batch acknowledge multiple messages."""
        ids = body.get("ids", [])
        by = body.get("by", "")

        if not isinstance(ids, list):
            raise HTTPException(status_code=400, detail="'ids' must be a list")
        if not by:
            raise HTTPException(status_code=400, detail="'by' (acknowledging agent) is required")
        if len(ids) > 100:
            raise HTTPException(status_code=400, detail="Maximum 100 IDs per batch")

        # Validate all IDs format first
        for mid in ids:
            if not re.match(r'^[a-f0-9-]{8}$', mid):
                raise HTTPException(status_code=400, detail=f"Invalid message ID format: {mid!r}")

        try:
            result = batch_ack_messages(ids, by)
            return result
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        except Exception as e:
            _stats.error_count += 1
            _stats.save()
            raise HTTPException(status_code=500, detail=str(e))

    def run():
        parser = argparse.ArgumentParser(description="Home Agent Bridge v2 HTTP Server")
        parser.add_argument("--port", type=int, default=get_default_port(),
                            help=f"Port to listen on (default: {get_default_port()})")
        parser.add_argument("--host", default="127.0.0.1", help="Host to bind to (default: 127.0.0.1)")
        args = parser.parse_args()
        print(f"Home Agent Bridge v2.0.0 listening on {args.host}:{args.port}")
        uvicorn.run(app, host=args.host, port=args.port, log_level="error")

else:
    from http.server import HTTPServer, BaseHTTPRequestHandler

    class BridgeHandler(BaseHTTPRequestHandler):
        def _json_response(self, data: dict, status: int = 200):
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        def _error_response(self, status: int, detail: str):
            self._json_response({"error": detail}, status)

        def do_GET(self):
            if self.path == "/status":
                self._json_response(get_status())
            elif self.path.startswith("/messages"):
                # Parse query params with URL decoding
                params = {}
                if "?" in self.path:
                    query = self.path.split("?", 1)[1]
                    for pair in query.split("&"):
                        if "=" in pair:
                            k, v = pair.split("=", 1)
                            params[k] = urllib.parse.unquote(v)
                for_agent = params.get("for", "")
                msg_type = params.get("type", "")

                if msg_type and msg_type not in VALID_MESSAGE_TYPES:
                    self._error_response(400, f"Invalid 'type': {msg_type!r}")
                    return

                raw = get_messages(for_agent, msg_type)
                msgs = [
                    {
                        "id": m["id"],
                        "text": m["text"],
                        "from": m["from"],
                        "to": m.get("to", ""),
                        "type": m.get("type", ""),
                        "time": m["time"],
                        "expires_at": m.get("expires_at", ""),
                    }
                    for m in raw
                ]
                self._json_response({"messages": msgs, "count": len(msgs)})
            else:
                self._error_response(404, "Not found")

        def do_POST(self):
            if self.path == "/message":
                content_len = int(self.headers.get("Content-Length", 0))
                if content_len > MAX_BODY_SIZE:
                    self._error_response(413, "Request body too large")
                    return
                if content_len == 0:
                    self._error_response(400, "Empty body")
                    return

                body = self.rfile.read(content_len).decode('utf-8', errors='replace')
                try:
                    data = json.loads(body)
                except json.JSONDecodeError:
                    self._error_response(400, "Invalid JSON")
                    return

                text = data.get("text", "").strip()
                if not text:
                    self._error_response(400, "Missing or empty 'text' field")
                    return

                from_agent = data.get("from", "unknown")
                to_agent = data.get("to", "")
                expires_at = data.get("expires_at", "")
                msg_type = data.get("type", "")

                if len(from_agent) > 256 or len(to_agent) > 256:
                    self._error_response(400, "'from' or 'to' field too long (max 256)")
                    return
                if msg_type not in VALID_MESSAGE_TYPES:
                    self._error_response(400, f"Invalid 'type': {msg_type!r}")
                    return

                try:
                    msg = add_message(text, from_agent, to_agent, expires_at, msg_type)
                    self._json_response({"status": "queued", "id": msg["id"]})
                except ValueError as e:
                    self._error_response(400, str(e))
                except Exception as e:
                    _stats.error_count += 1
                    _stats.save()
                    self._error_response(500, str(e))

            elif self.path == "/messages/ack":
                content_len = int(self.headers.get("Content-Length", 0))
                if content_len > MAX_BODY_SIZE:
                    self._error_response(413, "Request body too large")
                    return
                if content_len == 0:
                    self._error_response(400, "Empty body")
                    return

                body = self.rfile.read(content_len).decode('utf-8', errors='replace')
                try:
                    data = json.loads(body)
                except json.JSONDecodeError:
                    self._error_response(400, "Invalid JSON")
                    return

                ids = data.get("ids", [])
                by = data.get("by", "")

                if not isinstance(ids, list):
                    self._error_response(400, "'ids' must be a list")
                    return
                if not by:
                    self._error_response(400, "'by' (acknowledging agent) is required")
                    return
                if len(ids) > 100:
                    self._error_response(400, "Maximum 100 IDs per batch")

                # Validate ID formats
                for mid in ids:
                    if not re.match(r'^[a-f0-9-]{8}$', mid):
                        self._error_response(400, f"Invalid message ID format: {mid!r}")
                        return

                try:
                    result = batch_ack_messages(ids, by)
                    self._json_response(result)
                except ValueError as e:
                    self._error_response(400, str(e))
                except Exception as e:
                    _stats.error_count += 1
                    _stats.save()
                    self._error_response(500, str(e))

            else:
                self._error_response(404, "Not found")

        def do_DELETE(self):
            if not self.path.startswith("/message/"):
                self._error_response(404, "Not found")
                return

            path_id = self.path.split("/", 2)[-1]
            # Parse ?by= query param
            msg_id = path_id
            acknowledged_by = ""
            if "?" in path_id:
                msg_id, query = path_id.split("?", 1)
                for pair in query.split("&"):
                    if pair.startswith("by="):
                        acknowledged_by = pair.split("=", 1)[1]

            if not re.match(r'^[a-f0-9-]{8}$', msg_id):
                self._error_response(400, "Invalid message ID format")
                return

            success, ack_info = remove_message(msg_id, acknowledged_by)
            if not success:
                self._error_response(404, "Message not found")
                return

            response = {"status": "removed"}
            if ack_info.get("acknowledged_by"):
                response["acknowledged_by"] = ack_info["acknowledged_by"]
                response["acknowledged_at"] = ack_info["processed_at"]
            self._json_response(response)

        def log_message(self, format, *args):
            pass

    def run():
        parser = argparse.ArgumentParser(description="Home Agent Bridge v2 HTTP Server")
        parser.add_argument("--port", type=int, default=get_default_port(),
                            help=f"Port to listen on (default: {get_default_port()})")
        parser.add_argument("--host", default="127.0.0.1", help="Host to bind to (default: 127.0.0.1)")
        args = parser.parse_args()
        server = HTTPServer((args.host, args.port), BridgeHandler)
        print(f"Home Agent Bridge v2.0.0 listening on {args.host}:{args.port}")
        server.serve_forever()


if __name__ == "__main__":
    run()