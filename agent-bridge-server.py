#!/home/ale/.hermes/hermes-agent/venv/bin/python3
"""
home-agent-bridge: Lightweight HTTP receiver for inter-agent communication.
Receives messages from an OpenClaw agent via POST and queues them for processing.

Usage:
    python3 agent-bridge-server.py [--port 18473]

Endpoints:
    POST /message - Send a message to Hermes Agent
        Body: {"text": "message content", "from": "openclaw"}
        Returns: {"status": "queued", "id": "<timestamp>"}

    GET /status - Health check
        Returns: {"status": "ok", "bridge": "home-agent-bridge"}

    GET /messages - Get pending messages for Hermes Agent to process
        Returns: {"messages": [{"id": "...", "text": "...", "from": "openclaw", "time": "..."}]}

    DELETE /message/<id> - Acknowledge message was processed
        Returns: {"status": "removed"}
"""

import os
import re
import json
import uuid
import argparse
import fcntl
from datetime import datetime
from pathlib import Path

try:
    from fastapi import FastAPI, HTTPException, Request
    import uvicorn
    HAS_FASTAPI = True
except ImportError:
    HAS_FASTAPI = False

QUEUE_DIR = Path("/tmp/agent-bridge")
QUEUE_DIR.mkdir(exist_ok=True, mode=0o700)  # Restrict to owner only
MESSAGE_FILE = QUEUE_DIR / "incoming.jsonl"
PROCESSED_FILE = QUEUE_DIR / "processed.jsonl"
CONFIG_FILE = QUEUE_DIR / "port.txt"
LOCK_FILE = QUEUE_DIR / "queue.lock"
MAX_BODY_SIZE = 64 * 1024  # 64KB max request body

def get_default_port():
    """Read configured port or return default."""
    if CONFIG_FILE.exists():
        try:
            return int(CONFIG_FILE.read_text().strip())
        except (ValueError, FileNotFoundError):
            pass
    return 18473

def acquire_lock():
    """Acquire exclusive lock on queue file."""
    lock_fd = open(LOCK_FILE, 'w')
    fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
    return lock_fd

def release_lock(lock_fd):
    """Release exclusive lock."""
    fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
    lock_fd.close()

def load_queue():
    """Load existing messages (caller must hold lock)."""
    if MESSAGE_FILE.exists():
        with open(MESSAGE_FILE) as f:
            return [json.loads(line) for line in f if line.strip()]
    return []

def save_queue(messages, lock_fd=None):
    """Save messages to queue file (caller must hold lock)."""
    with open(MESSAGE_FILE, 'w') as f:
        for m in messages:
            f.write(json.dumps(m) + '\n')

def add_message(text: str, from_agent: str) -> dict:
    """Add a message to the queue with file locking."""
    if not text or not text.strip():
        raise ValueError("Message text cannot be empty")

    msg = {
        "id": str(uuid.uuid4())[:8],
        "text": text.strip(),
        "from": from_agent,
        "time": datetime.now().isoformat()
    }
    lock_fd = acquire_lock()
    try:
        messages = load_queue()
        messages.append(msg)
        save_queue(messages, lock_fd)
    finally:
        release_lock(lock_fd)
    return msg

def get_messages():
    """Get all pending messages with file locking."""
    lock_fd = acquire_lock()
    try:
        return load_queue()
    finally:
        release_lock(lock_fd)

def remove_message(msg_id: str) -> bool:
    """Remove a message by ID (after processing) with file locking."""
    lock_fd = acquire_lock()
    try:
        messages = load_queue()
        new_messages = [m for m in messages if m['id'] != msg_id]
        if len(new_messages) == len(messages):
            return False
        save_queue(new_messages, lock_fd)
        with open(PROCESSED_FILE, 'a') as f:
            f.write(json.dumps({"id": msg_id, "processed_at": datetime.now().isoformat()}) + '\n')
        return True
    finally:
        release_lock(lock_fd)

if HAS_FASTAPI:
    app = FastAPI(title="Home Agent Bridge", description="HTTP bridge for inter-agent communication")

    @app.get("/status")
    async def status():
        return {"status": "ok", "bridge": "home-agent-bridge", "queue_len": len(get_messages())}

    @app.post("/message")
    async def receive_message(request: Request, body: dict):
        content_len = request.headers.get("content-length")
        if content_len and int(content_len) > MAX_BODY_SIZE:
            raise HTTPException(status_code=413, detail="Request body too large")
        text = body.get("text", "")
        from_agent = body.get("from", "unknown")
        if not text or not text.strip():
            raise HTTPException(status_code=400, detail="Missing or empty 'text' field")
        if len(from_agent) > 256:
            raise HTTPException(status_code=400, detail="'from' field too long")
        msg = add_message(text, from_agent)
        return {"status": "queued", "id": msg["id"]}

    @app.get("/messages")
    async def list_messages():
        return {"messages": get_messages()}

    @app.delete("/message/{msg_id}")
    async def acknowledge_message(msg_id: str):
        if remove_message(msg_id):
            return {"status": "removed"}
        raise HTTPException(status_code=404, detail="Message not found")

    def run():
        parser = argparse.ArgumentParser(description="Home Agent Bridge HTTP Server")
        parser.add_argument("--port", type=int, default=get_default_port(), help=f"Port to listen on (default: {get_default_port()})")
        parser.add_argument("--host", default="127.0.0.1", help="Host to bind to (default: 127.0.0.1)")
        args = parser.parse_args()
        uvicorn.run(app, host=args.host, port=args.port, log_level="error")

else:
    from http.server import HTTPServer, BaseHTTPRequestHandler

    class BridgeHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/status":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "ok", "bridge": "home-agent-bridge"}).encode())
            elif self.path == "/messages":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"messages": get_messages()}).encode())

        def do_POST(self):
            if self.path != "/message":
                self.send_response(404)
                self.end_headers()
                return

            content_len = int(self.headers.get("Content-Length", 0))
            if content_len > MAX_BODY_SIZE:
                self.send_response(413)
                self.end_headers()
                return

            if content_len == 0:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Empty body"}).encode())
                return

            body = self.rfile.read(content_len).decode('utf-8', errors='replace')
            try:
                data = json.loads(body)
                text = data.get("text", "").strip()
                if not text:
                    raise ValueError("Empty text")
                from_agent = data.get("from", "unknown")
                if len(from_agent) > 256:
                    raise ValueError("'from' field too long")
                msg = add_message(text, from_agent)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "queued", "id": msg["id"]}).encode())
            except (json.JSONDecodeError, ValueError) as e:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())

        def do_DELETE(self):
            if not self.path.startswith("/message/"):
                self.send_response(404)
                self.end_headers()
                return

            msg_id = self.path.split("/")[-1]
            if not re.match(r'^[a-f0-9-]{8}$', msg_id):
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Invalid message ID format"}).encode())
                return
            if remove_message(msg_id):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "removed"}).encode())
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, format, *args):
            pass

    def run():
        parser = argparse.ArgumentParser(description="Home Agent Bridge HTTP Server")
        parser.add_argument("--port", type=int, default=get_default_port(), help=f"Port to listen on (default: {get_default_port()})")
        parser.add_argument("--host", default="127.0.0.1", help="Host to bind to (default: 127.0.0.1)")
        args = parser.parse_args()
        server = HTTPServer((args.host, args.port), BridgeHandler)
        print(f"Home Agent Bridge listening on {args.host}:{args.port}")
        server.serve_forever()

if __name__ == "__main__":
    run()