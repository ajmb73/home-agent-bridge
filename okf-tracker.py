#!/usr/bin/env python3
"""Check if Google OKF SPEC.md has changed since last check.

Runs monthly. Compares the latest commit SHA of SPEC.md against
a saved hash. Reports changes so Ale can decide whether to adopt updates.

Silent if no change. Reports summary if changed.
"""
import json, os, urllib.request, re
from datetime import datetime, timezone

STATE_FILE = os.path.expanduser("~/.hermes/data/okf-tracker-state.json")
os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)

# Load previous state
prev = {}
if os.path.exists(STATE_FILE):
    with open(STATE_FILE) as f:
        prev = json.load(f)

prev_sha = prev.get("spec_sha", "")
prev_version = prev.get("version", "")
prev_date = prev.get("checked", "")

# Fetch current SPEC.md info via GitHub API
API_URL = "https://api.github.com/repos/GoogleCloudPlatform/knowledge-catalog/contents/okf/SPEC.md"
req = urllib.request.Request(API_URL, headers={
    "Accept": "application/vnd.github.v3+json",
    "User-Agent": "hermes-okf-tracker/1.0"
})

current_sha = None
current_version = "?"
current_date = ""
raw_url = ""

try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
        current_sha = data.get("sha", "")
        raw_url = data.get("download_url", "")
    
    if raw_url:
        with urllib.request.urlopen(raw_url, timeout=15) as raw:
            content = raw.read().decode("utf-8")
            m = re.search(r'\*\*Version\s+([\d.]+)\s*[—-]\s*(.+?)\*\*', content)
            if m:
                current_version = m.group(1)
    
    # Extract date from API response
    current_date = data.get("last_modified", "") if "last_modified" in data else ""
    
except Exception as e:
    # API failure is not actionable — stay silent
    exit(0)

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Save new state
new_state = {
    "spec_sha": current_sha,
    "version": current_version,
    "checked": now
}
with open(STATE_FILE, "w") as f:
    json.dump(new_state, f, indent=2)

# No change — silent
if current_sha == prev_sha:
    exit(0)

# Change detected!
lines = []
lines.append(f"🔍 OKF spec has changed")
lines.append(f"")
lines.append(f"| | Before | Now |")
lines.append(f"|---|---|---|")
lines.append(f"| Version | {prev_version or '?'} | {current_version} |")
lines.append(f"| Last checked | {prev_date or '?'} | {now} |")
lines.append(f"| Commit SHA | `{(prev_sha or '?')[:10]}...` | `{current_sha[:10]}...` |")
lines.append(f"")
lines.append(f"Changes: https://github.com/GoogleCloudPlatform/knowledge-catalog/commits/main/okf/SPEC.md")
lines.append(f"Current spec: https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md")

if current_version != prev_version:
    lines.append(f"")
    lines.append(f"Version changed from `{prev_version}` to `{current_version}`.")
    lines.append(f"Review for breaking changes or features to adopt.")

lines.append(f"")
lines.append(f"Decision: review → update infrastructure/adopting-google-okf-frontmatter.md in Obsidian if needed.")

print("\n".join(lines))
