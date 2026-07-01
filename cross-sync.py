#!/usr/bin/env python3
"""Weekly knowledge exchange between two AI agents (jax and hermy)."""

import argparse
import datetime
import fcntl
import os
import re
import subprocess
import sys
from pathlib import Path


DAILY_DIR = Path("/mnt/nas_share/Obsidian/bobby/daily")
XCHANGE_DIR = Path("/mnt/nas_share/Obsidian/bobby/xchange")
LOCK_PATH = "/tmp/cross-sync.lock"

KEYWORDS = [
    "fixed", "deployed", "installed", "configured", "migrated", "updated",
    "changed", "removed", "created", "added", "rebuilt", "restarted",
    "upgraded", "patched", "resolved", "broke", "failed", "deprecated",
    "replaced", "switched", "enabled", "disabled", "moved", "renamed",
    "rolled-back", "restored",
]

EMOJI_PREFIXES = ["\u2705", "\u274c", "\u26a0\ufe0f", "\U0001F527", "\U0001F680", "\U0001F41B", "\U0001F4E6", "\U0001F504"]

KEYWORD_RE = re.compile(
    "|".join(re.escape(kw) for kw in KEYWORDS), re.IGNORECASE
)


def get_agent():
    result = subprocess.run(
        ["hostname"], capture_output=True, text=True
    )
    hostname = result.stdout.strip()
    return "jax" if "jax" in hostname else "hermy"


def get_last_7_dates():
    today = datetime.date.today()
    return [today - datetime.timedelta(days=i) for i in range(7)]


def extract_lines(filepath):
    lines = []
    in_frontmatter = False
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            if stripped == "---":
                in_frontmatter = not in_frontmatter
                continue
            if in_frontmatter:
                continue
            if stripped:
                lines.append(stripped)
    return lines


def is_relevant_line(line):
    if KEYWORD_RE.search(line):
        return True
    for emoji in EMOJI_PREFIXES:
        if line.startswith(emoji):
            return True
    return False


def categorize_line(line):
    line_lower = line.lower()
    if any(w in line_lower for w in ["fix", "resolved", "broke", "failed",
                                      "crash", "restor", "rollback"]) \
       or "\u274c" in line or "\u26a0\ufe0f" in line:
        return "Incidents & Resolutions"
    if "decid" in line_lower \
       or "switch" in line_lower \
       or re.search(r"chang.*policy", line_lower) \
       or "elect" in line_lower:
        return "Decisions"
    if any(w in line_lower for w in ["working on", "planning", "next",
                                      "todo", "in progress", "ongoing"]):
        return "Current Work"
    return "Infrastructure Changes"


def run(daily_dir=None, xchange_dir=None, verbose=False):
    daily_dir = Path(daily_dir) if daily_dir else DAILY_DIR
    xchange_dir = Path(xchange_dir) if xchange_dir else XCHANGE_DIR

    if not daily_dir.exists():
        return

    agent = get_agent()
    today = datetime.date.today()
    date_str = today.isoformat()
    week_str = today.strftime("%Y-W%V")

    target_filename = f"{agent}-sync-{date_str}.md"
    target_path = xchange_dir / target_filename

    dates = get_last_7_dates()
    sections = {
        "Infrastructure Changes": [],
        "Incidents & Resolutions": [],
        "Decisions": [],
        "Current Work": [],
    }

    any_files = False
    for d in dates:
        fpath = daily_dir / f"{d.isoformat()}.md"
        if not fpath.exists():
            continue
        any_files = True
        file_lines = extract_lines(fpath)
        for line in file_lines:
            if not is_relevant_line(line):
                continue
            cat = categorize_line(line)
            sections[cat].append(line)

    if not any_files or all(len(v) == 0 for v in sections.values()):
        return

    if xchange_dir.exists():
        for fpath in xchange_dir.glob(f"{agent}-sync-*.md"):
            try:
                fname = fpath.name
                date_part = fname.replace(f"{agent}-sync-", "").replace(".md", "")
                fdate = datetime.date.fromisoformat(date_part)
                if (today - fdate).days > 14:
                    fpath.unlink()
            except (ValueError, IndexError):
                pass

    other = "hermy" if agent == "jax" else "jax"
    description = f"Weekly knowledge exchange from {agent} to {other}"

    xchange_dir.mkdir(parents=True, exist_ok=True)
    with open(target_path, "w", encoding="utf-8") as f:
        f.write("---\n")
        f.write("type: reference\n")
        f.write(f'title: "cross-sync: {agent} \u2014 {date_str}"\n')
        f.write(f'description: "{description}"\n')
        f.write(f"tags: [cross-sync, {agent}, {week_str}]\n")
        ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
        f.write(f"timestamp: {ts}\n")
        f.write("---\n\n")

        for section_name in [
            "Infrastructure Changes",
            "Incidents & Resolutions",
            "Decisions",
            "Current Work",
        ]:
            items = sections[section_name]
            if not items:
                continue
            f.write(f"## {section_name}\n")
            for item in items:
                f.write(f"- {item}\n")
            f.write("\n")

    if verbose:
        total = sum(len(v) for v in sections.values())
        print(f"File: {target_path}")
        for sec, items in sections.items():
            if items:
                print(f"  {sec}: {len(items)} lines")
        print(f"  Total: {total} lines")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    lock_fd = None
    try:
        lock_fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (IOError, OSError):
        if lock_fd is not None:
            os.close(lock_fd)
        sys.exit(0)

    try:
        run(verbose=args.verbose)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


if __name__ == "__main__":
    main()
