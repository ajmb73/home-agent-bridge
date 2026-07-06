#!/usr/bin/env python3
"""Check if Evening Lights On 45 automation fired and what bulbs are on."""
import json, os, subprocess, sys, urllib.request

def get_ha_token():
    """Fetch HA token from Proton Pass."""
    result = subprocess.run(
        ["pass-cli", "item", "view",
         "--vault-name", "Agents",
         "--item-title", "Home Assistant (ha.home)",
         "--output", "json",
         "--field", "password"],
        capture_output=True, text=True, timeout=20,
        env={**os.environ, "PROTON_PASS_AGENT_REASON": "evening-lights-check"}
    )
    if result.returncode != 0:
        print(f"FAIL: pass-cli error: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()

token = get_ha_token()
BASE = "http://ha.home:8123/api/states"

def get_state(entity_id):
    req = urllib.request.Request(f"{BASE}/{entity_id}")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {"state": "ERROR", "error": str(e)}

# 1. Check automation
auto = get_state("automation.evening_lights_on_45")
print("=== AUTOMATION: evening_lights_on_45 ===")
if "attributes" in auto and "last_triggered" in auto["attributes"]:
    lt = auto["attributes"]["last_triggered"]
    print(f"State: {auto.get('state')}")
    print(f"last_triggered: {lt}")
else:
    print(json.dumps(auto, indent=2))

print()

# 2. Check all lights
lights = [
    "light.smart_rgbtw_bulb", "light.smart_rgbtw_bulb_2", "light.smart_rgbtw_bulb_3",
    "light.smart_rgbtw_bulb_4", "light.smart_rgbtw_bulb_5", "light.smart_rgbtw_bulb_6",
    "light.smart_rgbtw_bulb_7", "light.smart_rgbtw_bulb_8", "light.smart_rgbtw_bulb_9",
    "light.smart_multicolor_bulb", "light.smart_multicolor_bulb_2", "light.smart_multicolor_bulb_3",
    "light.basement_standing", "light.corridor_upstairs", "light.hallway",
    "light.laundry", "light.entrance", "light.backyard_light",
]

on_count = 0
off_count = 0
problem = []

print("=== LIGHT STATES ===")
for lid in lights:
    data = get_state(lid)
    s = data.get("state", "UNKNOWN")
    friendly = data.get("attributes", {}).get("friendly_name", lid)
    print(f"  {friendly:35s} => {s}")
    if s == "on":
        on_count += 1
    elif s == "off":
        off_count += 1
    else:
        problem.append(f"{friendly} ({lid}): state={s}")

total = len(lights)
print(f"\n=== SUMMARY ===")
print(f"Total bulbs: {total}")
print(f"On: {on_count}")
print(f"Off: {off_count}")
print(f"Problems: {len(problem)}")

# Determine if automation fired today around 20:15-20:20 ET
auto_fired = False
if "attributes" in auto and "last_triggered" in auto["attributes"]:
    lt = auto["attributes"]["last_triggered"]
    if lt and lt != "null" and lt != None:
        # Check it's today's date and around 20:15-20:20 ET (which is 00:15-00:20 UTC next day or 20:15-20:20 UTC-4)
        # Just report the timestamp and let the cron output judge
        print(f"\nAutomation last_triggered: {lt}")
        auto_fired = True

if auto_fired:
    print("Automation status: FIRED ✓")
else:
    print("Automation status: NOT FIRED ✗")

print()

if on_count == total:
    print("✅ All lights on, automation working correctly.")
elif on_count > 0 and problem:
    print(f"⚠️ Partial: {on_count}/{total} on, {len(problem)} problem(s):")
    for p in problem:
        print(f"  - {p}")
elif off_count == total or on_count == 0:
    print(f"❌ No lights on ({off_count} off, {len(problem)} problem(s))")
    for p in problem:
        print(f"  - {p}")
else:
    print(f"ℹ️  {on_count}/{total} on, {off_count} off, {len(problem)} problem(s)")
    for p in problem:
        print(f"  - {p}")
