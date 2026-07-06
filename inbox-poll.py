#!/usr/bin/env python3
"""Agent Inbox Poller — reads messages from the shared NAS inbox.

Protocol: https://www.notion.so/... (see Obsidian infra docs)
"""
import json, os, shutil, sys, glob, datetime, pathlib, re, logging

BASE = "/mnt/nas_share/agent-inbox"
ME = "jax"           # my identity
PARTNER = "hermy"    # the other agent

MY_INBOX      = f"{BASE}/inbox/{ME}/"       # I read from here
MY_OUTBOX     = f"{BASE}/inbox/{PARTNER}/"  # I write to here
MY_ARCHIVE    = f"{BASE}/archive/{ME}/"     # processed inbound go here
TRASH         = f"{BASE}/.trash/"
LOCAL_OUTBOX  = os.path.expanduser("~/.hermes/inbox-outbox/")
LOCAL_SENT    = f"{LOCAL_OUTBOX}sent/"
SEQ_FILE      = os.path.expanduser("~/.hermes/inbox-sequence")
HB_COUNTER    = os.path.expanduser("~/.hermes/inbox-hb-counter")
LOG_FILE      = os.path.expanduser("~/.hermes/cron/output/inbox-poll.log")

# Setup
os.makedirs(f"{MY_INBOX}", exist_ok=True)
os.makedirs(f"{MY_OUTBOX}", exist_ok=True)
os.makedirs(f"{MY_ARCHIVE}", exist_ok=True)
os.makedirs(TRASH, exist_ok=True)
os.makedirs(LOCAL_OUTBOX, exist_ok=True)
os.makedirs(LOCAL_SENT, exist_ok=True)
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

logging.basicConfig(
    filename=LOG_FILE, level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("inbox-poll")

def now_utc():
    return datetime.datetime.now(datetime.timezone.utc)

def now_utc_str():
    return now_utc().strftime("%Y%m%dT%H%M%SZ")

def now_utc_iso():
    """ISO 8601 timestamp for JSON fields (e.g. 2026-06-30T00:05:09Z)."""
    return now_utc().strftime("%Y-%m-%dT%H:%M:%SZ")

def get_seq():
    try:
        with open(SEQ_FILE) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0

def inc_seq():
    s = get_seq() + 1
    with open(SEQ_FILE, "w") as f:
        f.write(f"{s:04d}\n")
    return s

def make_msg_id():
    return f"{now_utc_str()}-{ME}-{get_seq():04d}"

def write_message(recipient, msg_type, subject, body, priority="normal",
                  in_reply_to=None, ttl_hours=72):
    """Write a message to partner's inbox (atomic write pattern)."""
    seq = inc_seq()
    msg_id = f"{now_utc_str()}-{ME}-{seq:04d}"
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
        log.error(f"Failed to write message: {e}")
        # save to local outbox instead
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

def validate_msg(data):
    """Validate required fields."""
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

def is_expired(data):
    """Check if message exceeds its TTL. Supports ISO 8601 and compact formats."""
    ttl = data.get("ttl_hours", 72)
    ts_str = data.get("timestamp", "")
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y%m%dT%H%M%SZ"):
        try:
            ts = datetime.datetime.strptime(ts_str, fmt)
            ts = ts.replace(tzinfo=datetime.timezone.utc)
            age = (now_utc() - ts).total_seconds() / 3600
            return age > ttl
        except ValueError:
            continue
    return False  # can't parse any format, don't expire

def already_processed(msg_id):
    """Check if message_id exists in archive (dedup)."""
    # Check current month archive
    month = now_utc().strftime("%Y-%m")
    archive_path = f"{MY_ARCHIVE}{month}/{msg_id}.json"
    if os.path.exists(archive_path):
        return True
    # Check previous months too
    jax_archive = MY_ARCHIVE.rstrip("/")
    for d in sorted(os.listdir(jax_archive), reverse=True)[:6]:  # last 6 months
        if os.path.exists(f"{jax_archive}/{d}/{msg_id}.json"):
            return True
    return False

def send_ack(in_reply_to, subject="", priority="normal"):
    """Send acknowledgment for a processed message."""
    body = f"Received. Processed."
    write_message(PARTNER, "ack", f"Re: {subject}", body,
                  priority=priority, in_reply_to=in_reply_to, ttl_hours=24)

def archive_msg(filepath, msg_id):
    """Move processed message to archive."""
    month = now_utc().strftime("%Y-%m")
    dest_dir = f"{MY_ARCHIVE}{month}/"
    os.makedirs(dest_dir, exist_ok=True)
    shutil.move(filepath, f"{dest_dir}{msg_id}.json")

def trash_msg(filepath, msg_id, reason):
    """Move failed message to trash with error annotation."""
    os.makedirs(TRASH, exist_ok=True)
    shutil.move(filepath, f"{TRASH}{msg_id}.json")
    error = {"message_id": msg_id, "error": reason,
             "timestamp": now_utc_iso()}
    with open(f"{TRASH}{msg_id}.error.json", "w") as f:
        json.dump(error, f, indent=2)

def replay_outbox():
    """Replay local outbox on NAS recovery."""
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
            with open(tmp, "r") as f:  # fsync the copy
                os.fsync(f.fileno())
            os.rename(tmp, final)
            shutil.move(fpath, f"{LOCAL_SENT}{fname}")
            log.info(f"Replayed: {fname}")
        except OSError as e:
            log.error(f"Replay failed for {fname}: {e}")
            break  # NAS flaky again, retry next cycle

def clean_stale_tmp():
    """Remove .tmp files older than 5 minutes."""
    cutoff = now_utc().timestamp() - 300
    for fpath in glob.glob(f"{MY_INBOX}*.tmp") + glob.glob(f"{MY_OUTBOX}*.tmp"):
        try:
            if os.path.getmtime(fpath) < cutoff:
                os.remove(fpath)
                log.info(f"Cleaned stale tmp: {fpath}")
        except OSError:
            pass

def poll():
    """Main poll cycle: read and process inbound messages."""
    clean_stale_tmp()
    replay_outbox()

    # Try writing to NAS as health check — if it fails, outbox replay already handled it
    # (replay_outbox tries to write first)

    files = sorted(glob.glob(f"{MY_INBOX}*.json"))
    if not files:
        return

    log.info(f"Poll: {len(files)} message(s) in inbox")

    hb_count = 0
    for fpath in files:
        fname = os.path.basename(fpath)
        msg_id = fname.replace(".json", "")
        try:
            with open(fpath) as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            log.warning(f"Corrupt JSON: {fname}: {e}")
            trash_msg(fpath, msg_id, f"JSON parse error: {e}")
            print(f"⚠ Corrupt message from {PARTNER}: {fname} — {e}")
            continue

        err = validate_msg(data)
        if err:
            log.warning(f"Validation failed: {fname}: {err}")
            trash_msg(fpath, msg_id, err)
            print(f"⚠ Invalid message from {PARTNER}: {fname} — {err}")
            continue

        # Dedup
        if already_processed(data["message_id"]):
            log.info(f"Dedup: {data['message_id']} already processed")
            # Still send ack for retransmits
            send_ack(data["message_id"], data.get("subject", ""),
                     data.get("priority", "normal"))
            os.remove(fpath)
            continue

        # TTL check
        if is_expired(data):
            log.info(f"Expired: {data['message_id']}")
            trash_msg(fpath, data["message_id"], "expired")
            print(f"⏳ Expired message from {PARTNER}: {data.get('subject', '')}")
            continue

        # --- Process message ---
        msg_type = data["type"]
        subject = data.get("subject", "")
        priority = data.get("priority", "normal")

        log.info(f"Processing: {data['message_id']} ({msg_type}: {subject})")

        # Heartbeat: ack every 4th
        if msg_type == "heartbeat":
            try:
                with open(HB_COUNTER) as f:
                    hb_count = int(f.read().strip())
            except (FileNotFoundError, ValueError):
                hb_count = 0
            hb_count += 1
            with open(HB_COUNTER, "w") as f:
                f.write(f"{hb_count}\n")
            if hb_count % 4 == 0:
                send_ack(data["message_id"], subject, priority)
                log.info(f"Heartbeat acked (count={hb_count})")
            else:
                log.info(f"Heartbeat received (count={hb_count}, no ack)")
        elif msg_type in ("ack", "response"):
            # Inbound ack/response — notify
            print(f"📬 {msg_type.capitalize()} from {PARTNER}: {subject}")
            log.info(f"Received {msg_type}: {subject}")
        elif priority in ("high", "critical"):
            # Notify human via stdout (cron deliver will capture)
            print(f"📬 [{priority.upper()}] from {PARTNER}: {subject}")
            print(f"{data.get('body', '')}")
            send_ack(data["message_id"], subject, priority)
        else:
            # Normal message - notify
            if msg_type in ("message", "request"):
                print(f"📬 {msg_type.capitalize()} from {PARTNER}: {subject}")
            send_ack(data["message_id"], subject, priority)

        # Archive
        archive_msg(fpath, data["message_id"])

if __name__ == "__main__":
    try:
        poll()
    except Exception as e:
        log.exception(f"Poll cycle failed: {e}")
        print(f"[ERROR] Inbox poll failed: {e}", file=sys.stderr)
