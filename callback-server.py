#!/usr/bin/env python3
"""
Callback server for instant message delivery.
Receives messages from bridge and forwards to Telegram.
"""

import os
import re
import json
import time
import fcntl
import subprocess
import logging
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# Configuration
CALLBACK_PORT = 18474
CALLBACK_HOST = "127.0.0.1"
BRIDGE_URL = "http://localhost:18473"
LOG_FILE = Path("/home/ale/.hermes/logs/callback-server.log")
LOCK_FILE = Path("/tmp/callback-server.lock")
RATE_LIMIT_FILE = Path("/tmp/callback-server-rate.json")
RATE_LIMIT_SECONDS = 30

# Load env for Telegram
# NOTE: .env uses TELEGRAM_HOME_CHANNEL for the chat ID
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID") or os.environ.get("TELEGRAM_HOME_CHANNEL", "")
TELEGRAM_API_URL = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"

# Setup logging
LOG_FILE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("callback-server")


def load_rate_limit():
    """Load last sent timestamp."""
    if RATE_LIMIT_FILE.exists():
        try:
            data = json.loads(RATE_LIMIT_FILE.read_text())
            return data.get("last_sent", 0)
        except (json.JSONDecodeError, OSError):
            pass
    return 0


def save_rate_limit():
    """Save current timestamp as last sent (0600 perms for security)."""
    try:
        # Write with explicit owner-only permissions (0600)
        RATE_LIMIT_FILE.write_text(json.dumps({"last_sent": int(time.time())}))
        RATE_LIMIT_FILE.chmod(0o600)
    except OSError as e:
        logger.warning(f"Failed to save rate limit: {e}")


def check_rate_limit():
    """Check if we're rate limited. Returns True if OK to send."""
    elapsed = time.time() - load_rate_limit()
    if elapsed < RATE_LIMIT_SECONDS:
        logger.info(f"Rate limited: {elapsed:.1f}s since last message (min: {RATE_LIMIT_SECONDS}s)")
        return False
    return True


def send_to_telegram(text: str, sender: str, timestamp: str) -> bool:
    """Send message to Telegram. Returns True on success."""
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        logger.error("TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set")
        return False

    formatted = f"📩 *From:* {sender}\n🕐 *Time:* {timestamp}\n\n{text}"

    payload = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": formatted,
        "parse_mode": "MarkdownV2"
    }

    # Escape special characters for MarkdownV2
    for char in ["_", "*", "[", "]", "(", ")", "~", "`", ">", "#", "+", "-", "=", "|", "{", "}", ".", "!"]:
        formatted = formatted.replace(char, "\\" + char)

    payload["text"] = formatted

    try:
        result = subprocess.run(
            ["curl", "-s", "-w", "\n%{http_code}", "-X", "POST", TELEGRAM_API_URL,
             "-H", "Content-Type: application/json",
             "-d", json.dumps(payload)],
            capture_output=True, text=True, timeout=30
        )
        output = result.stdout.strip()
        if output:
            lines = output.split("\n")
            http_code = lines[-1]
            body = "\n".join(lines[:-1]) if len(lines) > 1 else ""
            if http_code == "200":
                logger.info("Telegram delivery successful")
                return True
            else:
                logger.error(f"Telegram API error: HTTP {http_code} - {body}")
        else:
            logger.error("Telegram API returned empty response")
    except subprocess.TimeoutExpired:
        logger.error("Telegram API request timed out")
    except Exception as e:
        logger.error(f"Telegram API request failed: {e}")

    return False


def delete_from_bridge(msg_id: str):
    """DELETE message from bridge after successful delivery."""
    # Sanitize msg_id - bridge uses 8 char hex format
    if not re.match(r'^[a-f0-9]{8}$', msg_id):
        logger.warning(f"Invalid msg_id format: {msg_id}")
        return

    try:
        result = subprocess.run(
            ["curl", "-s", "-f", "-X", "DELETE", f"{BRIDGE_URL}/message/{msg_id}?by=callback"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            logger.info(f"Deleted message {msg_id} from bridge")
        else:
            logger.warning(f"Failed to delete message {msg_id}: {result.stderr}")
    except Exception as e:
        logger.warning(f"Delete request failed for {msg_id}: {e}")


def acquire_lock():
    """Acquire exclusive lock for idempotency."""
    try:
        lock_fd = open(LOCK_FILE, 'w')
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        lock_fd.write(str(os.getpid()))
        return lock_fd
    except (IOError, OSError) as e:
        logger.error(f"Failed to acquire lock: {e}")
        return None


def release_lock(lock_fd):
    """Release exclusive lock."""
    if lock_fd:
        try:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
            lock_fd.close()
        except Exception:
            pass


class CallbackHandler(BaseHTTPRequestHandler):
    """HTTP handler for callback requests."""

    def _json_response(self, status: int, data: dict):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _error(self, status: int, message: str):
        self._json_response(status, {"error": message})

    def do_GET(self):
        """Health check endpoint."""
        if self.path == "/health":
            self._json_response(200, {"status": "ok", "service": "callback-server"})
        else:
            self._error(404, "Not found")

    def do_POST(self):
        """Receive message and forward to Telegram."""
        parsed = urlparse(self.path)

        if parsed.path != "/notify":
            self._error(404, "Not found")
            return

        # Read body
        content_len = int(self.headers.get("Content-Length", 0))
        if content_len == 0:
            self._error(400, "Empty body")
            return
        if content_len > 65536:
            self._error(413, "Request body too large")
            return

        try:
            body = self.rfile.read(content_len).decode("utf-8", errors="replace")
            data = json.loads(body)
        except json.JSONDecodeError:
            self._error(400, "Invalid JSON")
            return

        # Validate required fields
        text = data.get("text", "").strip()
        msg_id = data.get("id", "")
        sender = data.get("from", "unknown")
        timestamp = data.get("time", "")
        msg_type = data.get("type", "")

        if not text:
            self._error(400, "Missing or empty 'text' field")
            return
        if not msg_id:
            self._error(400, "Missing 'id' field")
            return

        # Validate msg_id format (no newlines or special chars)
        if not re.match(r'^[a-f0-9]{8}$', msg_id):
            self._error(400, f"Invalid message ID format: {msg_id}")
            return

        logger.info(f"Received message {msg_id} from {sender}: {text[:50]}...")

        # Acquire lock for idempotency
        lock_fd = acquire_lock()
        if not lock_fd:
            self._error(503, "Server busy, try again")
            return

        try:
            # Check rate limit
            if not check_rate_limit():
                self._json_response(429, {"error": "Rate limited", "retry_after": RATE_LIMIT_SECONDS})
                return

            # Send to Telegram
            if send_to_telegram(text, sender, timestamp):
                save_rate_limit()
                delete_from_bridge(msg_id)
                self._json_response(200, {"status": "delivered", "id": msg_id})
            else:
                # Telegram failed - return 500 so bridge keeps message for polling fallback
                self._error(500, "Telegram delivery failed")
        finally:
            release_lock(lock_fd)

    def log_message(self, format, *args):
        """Suppress default logging."""
        pass


def run():
    """Start the callback server."""
    logger.info(f"Starting callback server on {CALLBACK_HOST}:{CALLBACK_PORT}")

    # Check if already running
    try:
        result = subprocess.run(
            ["curl", "-s", "-f", "-X", "GET", f"http://{CALLBACK_HOST}:{CALLBACK_PORT}/health"],
            timeout=5
        )
        if result.returncode == 0:
            logger.warning("Callback server already running")
            return
    except subprocess.TimeoutExpired:
        pass
    except Exception:
        pass

    server = HTTPServer((CALLBACK_HOST, CALLBACK_PORT), CallbackHandler)
    logger.info(f"Callback server listening on {CALLBACK_HOST}:{CALLBACK_PORT}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Callback server shutting down")
        server.shutdown()


if __name__ == "__main__":
    run()
