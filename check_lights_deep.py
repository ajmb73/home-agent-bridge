#!/usr/bin/env python3
"""Check problem entities and automation history more carefully."""
import json, os, subprocess, sys, urllib.request
from datetime import datetime, timezone, timedelta

def get_ha_token():
    """Fetch HA token from Proton Pass."""
    result = subprocess.run(
        ["pass-cli", "item", "view",
         "--vault-name", "Agents",
         "--item-title", "Home Assistant (ha.home)",
         "--output", "json",
         "--field", "password"],
        capture_output=True, text=True, timeout=20,
        env={**os.environ, "PROTON_PASS_AGENT_REASON": "lights-deep-check"}
    )
    if result.returncode != 0:
        print(f"FAIL: pass-cli error: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()

token = get_ha_token()
BASE = "http://ha.home:8123/api"

def api_get(path):
    req = urllib.request.Request(f"{BASE}/{path}")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {"error": str(e)}

# Check the two problem entities
print("=== CHECKING PROBLEM ENTITIES ===")
for eid in ["light.smart_rgbtw_bulb_2", "light.backyard_light"]:
    data = api_get(f"states/{eid}")
    print(f"{eid}:")
    print(json.dumps(data, indent=2))
    print()

# Get all light entities to see what's actually registered
print("=== ALL LIGHT ENTITIES ===")
states = api_get("states")
lights = [s for s in states if s["entity_id"].startswith("light.")]
for l in sorted(lights, key=lambda x: x["entity_id"]):
    friendly = l.get("attributes", {}).get("friendly_name", l["entity_id"])
    print(f"  {l['entity_id']:45s} => {l['state']:5s}  ({friendly})")

print()

# Check automation logs/trace
auto = api_get("states/automation.evening_lights_on_45")
print("=== AUTOMATION FULL ===")
print(json.dumps(auto, indent=2))
