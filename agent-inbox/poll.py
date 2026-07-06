#!/usr/bin/env python3
"""Agent Inbox Poller — Hermes side (ai-home)

Polls the shared NAS inbox for messages from Jax, validates, archives,
sends acks, replays local outbox on NAS recovery.

Protocol: /mnt/nas_share/Obsidian/bobby/infrastructure/agent-inbox-protocol.md
"""

import datetime
import glob
import json
import logging
import os
import pathlib
import shutil
import sys

# ─── Identity ──────────────────────────────────────────────────────────
ME = "hermy"
PARTNER = "jax"

# ─── Paths ─────────────────────────────────────────────────────────────
BASE = "/mnt/nas_share/agent-inbox"
MY_INBOX = f"{BASE}/inbox/{ME}/"          # Jax writes here, I read
MY_OUTBOX = f"{BASE}/inbox/{PARTNER}/"    # I write here, Jax reads
MY_ARCHIVE = f"{BASE}/archive/{ME}/"      # processed inbound go here
TRASH = f"{BASE}/.trash/"
LOCAL_OUTBOX = os.path.expanduser("~/.hermes/inbox-outbox/")
LOCAL_SENT = f"{LOCAL_OUTBOX}sent/"
SEQ_FILE = os.path.expanduser("~/.hermes/inbox-sequence")
HB_COUNTER = os.path.expanduser("~/.hermes/inbox-hb-counter")
LOG_FILE = os.path.expanduser("~/.hermes/cron/output/agent-inbox.log")

# ─── Setup ─────────────────────────────────────────────────────────────
os.makedirs(MY_INBOX, exist_ok=True)
os.makedirs(MY_OUTBOX, exist_ok=True)
os.makedirs(MY_ARCHIVE, exist_ok=True)
os.makedirs(TRASH, exist_ok=True)
os.makedirs(LOCAL_OUTBOX, exist_ok=True)
os.makedirs(LOCAL_SENT, exist_ok=True)
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("inbox-poll")

# ─── Helpers ───────────────────────────────────────────────────────────

def now_utc():
    return datetime.datetime.now(datetime.timezone.utc)

def now_utc_str():
    """Compact UTC timestamp for filenames (e.g. 20260630T002324Z)."""
    return now_utc().strftime("%Y%m%dT%H%M%SZ")

def now_utc_iso():
    """ISO 8601 UTC timestamp for JSON fields (e.g. 2026-06-30T00:23:24Z)."""
    return now_utc().strftime("%Y-%m-%dT%H:%M:%SZ")

def get_seq() -> int:
    try:
        with open(SEQ_FILE) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0

def inc_seq() -> str:
    s = get_seq() + 1
    with open(SEQ_FILE, "w") as f:
        f.write(f"{s:04d}\n")
    return f"{s:04d}"

# ─── Write message (atomic .tmp → rename) ──────────────────────────────

def write_message(
    recipient: str,
    msg_type: str,
    subject: str,
    body: str,
    priority: str = "normal",
    in_reply_to: str | None = None,
    ttl_hours: int = 72,
) -> str | None:
    """Write a message to partner's inbox using atomic write pattern."""
    seq = inc_seq()
    msg_id = f"{now_utc_str()}-{ME}-{seq}"

    msg = {
        "protocol_version": "1.0",
        "message_id": msg_id,
        "sender": ME,
        "recipient": recipient,
        "timestamp": now_utc_iso(),
        "type": msg_type,
        "subject": subject,
        "body": body,
        "priority": priority,
        "ttl_hours": ttl_hours,
    }
    if in_reply_to:
        msg["in_reply_to"] = in_reply_to

    target_dir = f"{BASE}/inbox/{recipient}/"
    os.makedirs(target_dir, exist_ok=True)

    tmp = f"{target_dir}{msg_id}.tmp"
    final = f"{target_dir}{msg_id}.json"

    try:
        with open(tmp, "w") as f:
            json.dump(msg, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp, final)
        log.info(f"Wrote {msg_type} to {recipient}: {msg_id}")
        return msg_id
    except OSError as e:
        log.error(f"Failed to write to NAS: {e}")
        # Fallback to local outbox
        local_tmp = f"{LOCAL_OUTBOX}{msg_id}.tmp"
        local_final = f"{LOCAL_OUTBOX}{msg_id}.json"
        try:
            with open(local_tmp, "w") as f:
                json.dump(msg, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.rename(local_tmp, local_final)
            log.info(f"Saved to local outbox: {msg_id}")
        except OSError as e2:
            log.error(f"Local outbox also failed: {e2}")
        return None

# ─── Validation ────────────────────────────────────────────────────────

def validate_msg(data: dict) -> str | None:
    """Return error string if invalid, None if valid."""
    if not isinstance(data, dict):
        return "root is not a dict"
    for field in ["protocol_version", "message_id", "sender", "recipient",
                  "timestamp", "type", "body"]:
        if field not in data or not isinstance(data[field], str):
            return f"missing or invalid: {field}"
    if data["protocol_version"] != "1.0":
        return f"unsupported protocol_version: {data['protocol_version']}"
    if data["sender"] not in ("hermy", "jax"):
        return f"invalid sender: {data['sender']}"
    if data["recipient"] not in ("hermy", "jax"):
        return f"invalid recipient: {data['recipient']}"
    if data["recipient"] != ME:
        return f"not for me (recipient={data['recipient']})"
    if data["type"] not in ("message", "ack", "request", "response",
                            "heartbeat", "error"):
        return f"invalid type: {data['type']}"
    return None

# ─── TTL check (handles both ISO and compact timestamps) ───────────────

def parse_timestamp(ts: str) -> datetime.datetime | None:
    """Try ISO 8601 format first, then compact format."""
    for fmt in ["%Y-%m-%dT%H:%M:%SZ", "%Y%m%dT%H%M%SZ"]:
        try:
            return datetime.datetime.strptime(ts, fmt).replace(
                tzinfo=datetime.timezone.utc
            )
        except ValueError:
            continue
    return None

def is_expired(data: dict) -> bool:
    ttl = data.get("ttl_hours", 72)
    ts = parse_timestamp(data.get("timestamp", ""))
    if ts is None:
        return False  # can't parse, don't expire
    age = (now_utc() - ts).total_seconds() / 3600
    return age > ttl

# ─── Dedup ─────────────────────────────────────────────────────────────

def already_processed(msg_id: str) -> bool:
    """Check if message_id exists in archive (last 6 months)."""
    archive_dir = pathlib.Path(MY_ARCHIVE)
    if not archive_dir.parent.exists():
        return False
    for child in sorted(archive_dir.parent.iterdir(), reverse=True)[:6]:
        if (child / f"{msg_id}.json").exists():
            return True
    return False

# ─── Actions ───────────────────────────────────────────────────────────

def trash_msg(filepath: str, msg_id: str, reason: str):
    """Move failed/expired message to trash with error annotation."""
    os.makedirs(TRASH, exist_ok=True)
    shutil.move(filepath, f"{TRASH}{msg_id}.json")
    error = {
        "message_id": msg_id,
        "error": reason,
        "timestamp": now_utc_iso(),
    }
    with open(f"{TRASH}{msg_id}.error.json", "w") as f:
        json.dump(error, f, indent=2)

def send_ack(in_reply_to: str, subject: str = "", priority: str = "normal"):
    write_message(
        PARTNER, "ack", f"Re: {subject}", "Received. Processed.",
        priority=priority, in_reply_to=in_reply_to, ttl_hours=24,
    )

def replay_outbox():
    """Replay local outbox when NAS recovers."""
    files = sorted(glob.glob(f"{LOCAL_OUTBOX}*.json"))
    if not files:
        return
    log.info(f"Replaying {len(files)} from local outbox")
    print(f"↻ Replaying {len(files)} message(s) from local outbox")
    for fpath in files:
        fname = os.path.basename(fpath)
        try:
            with open(fpath) as f:
                data = json.load(f)
            recipient = data.get("recipient", PARTNER)
            target_dir = f"{BASE}/inbox/{recipient}/"
            os.makedirs(target_dir, exist_ok=True)

            tmp = f"{target_dir}{fname}.tmp"
            final = f"{target_dir}{fname}"
            shutil.copy2(fpath, tmp)
            with open(tmp, "rb") as fh:
                os.fsync(fh.fileno())
            os.rename(tmp, final)
            shutil.move(fpath, f"{LOCAL_SENT}{fname}")
            log.info(f"Replayed: {fname}")
        except OSError as e:
            log.error(f"Replay failed for {fname}: {e}")
            print(f"⚠ Outbox stalled — NAS still unreachable")
            break

def clean_stale_tmp():
    """Remove .tmp files older than 5 minutes."""
    cutoff = now_utc().timestamp() - 300
    for pattern in (f"{MY_INBOX}*.tmp", f"{MY_OUTBOX}*.tmp"):
        for fpath in glob.glob(pattern):
            try:
                if os.path.getmtime(fpath) < cutoff:
                    os.remove(fpath)
                    log.info(f"Cleaned stale tmp: {fpath}")
            except OSError:
                pass

# ─── Main poll ─────────────────────────────────────────────────────────

def poll():
    clean_stale_tmp()
    replay_outbox()

    files = sorted(glob.glob(f"{MY_INBOX}*.json"))
    if not files:
        return

    log.info(f"Poll: {len(files)} message(s) in inbox")

    for fpath in files:
        fname = os.path.basename(fpath)
        msg_id = fname.replace(".json", "")

        # Parse JSON
        try:
            with open(fpath) as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            log.warning(f"Corrupt JSON: {fname}: {e}")
            trash_msg(fpath, msg_id, f"JSON parse error: {e}")
            print(f"⚠ Corrupt message from {PARTNER}: {fname} — {e}")
            continue

        # Validate
        err = validate_msg(data)
        if err:
            log.warning(f"Validation failed: {fname}: {err}")
            trash_msg(fpath, msg_id, err)
            print(f"⚠ Invalid message from {PARTNER}: {fname} — {err}")
            continue

        # Dedup
        if already_processed(data["message_id"]):
            log.info(f"Dedup: {data['message_id']} already processed, re-acking")
            send_ack(data["message_id"], data.get("subject", ""),
                     data.get("priority", "normal"))
            os.remove(fpath)
            continue

        # TTL
        if is_expired(data):
            log.info(f"Expired: {data['message_id']}")
            trash_msg(fpath, data["message_id"], "expired")
            print(f"⏳ Expired message from {PARTNER}: {data.get('subject', '')}")
            continue

        # ─── Process ───
        msg_type = data["type"]
        subject = data.get("subject", "")
        priority = data.get("priority", "normal")

        log.info(f"Processing: {data['message_id']} ({msg_type}: {subject})")

        # Archive first (before ack — ensures at-least-once)
        archive_month = now_utc().strftime("%Y-%m")
        archive_dir = f"{MY_ARCHIVE}{archive_month}/"
        os.makedirs(archive_dir, exist_ok=True)
        shutil.move(fpath, f"{archive_dir}{data['message_id']}.json")

        # Heartbeat: ack every 4th
        if msg_type == "heartbeat":
            hb_count = 0
            try:
                with open(HB_COUNTER) as f:
                    hb_count = int(f.read().strip())
            except (FileNotFoundError, ValueError):
                pass
            hb_count += 1
            with open(HB_COUNTER, "w") as f:
                f.write(f"{hb_count}\n")
            if hb_count % 4 == 0:
                send_ack(data["message_id"], subject, priority)
                log.info(f"Heartbeat acked (count={hb_count})")
            continue  # heartbeats are silent

        # Ack
        send_ack(data["message_id"], subject, priority)

        # Priority escalation → notify
        emoji = "📩"
        tag = ""
        if priority in ("high", "critical"):
            emoji = "🚨" if priority == "critical" else "⚡"
            tag = f" [{priority.upper()}]"
            log.info(f"{priority.upper()} priority: {subject}")

        # Print to stdout → cron delivery
        print(f"{emoji} **From {PARTNER.capitalize()}{tag}:** {subject}")
        print(data.get("body", ""))

# ─── Entry ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    try:
        poll()
    except Exception as e:
        log.exception(f"Poll cycle failed: {e}")
        print(f"[ERROR] Inbox poll failed: {e}", file=sys.stderr)
