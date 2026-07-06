#!/usr/bin/env python3
"""Uptime Kuma alert vetter — cross-refs NetAlertX API, filters noise, outputs structured alerts."""
import json, os, sys, urllib.request, subprocess

WEBHOOK_URL = "http://192.168.0.17:3002"
NETALERTX_API = "http://192.168.0.13:20212"
PP_SHARE_ID = "3RhkIoczlcY4AzztkKZYb5-mxxu8aNzwPWBNO40gGJm1nZ5LZksnyJaF_t-iYDtvusmigdbsPfj0YbWvAqxSrg=="

def get_netalertx_token():
    """Read NetAlertX API token from Proton Pass Agents vault."""
    try:
        env = os.environ.copy()
        env["PROTON_PASS_AGENT_REASON"] = "Kuma vetter: reading NetAlertX API token"
        result = subprocess.run(
            ["pass-cli", "item", "view",
             "--share-id", PP_SHARE_ID,
             "--item-title", "NetAlertX API Token",
             "--field", "note"],
            capture_output=True, text=True, timeout=15, env=env
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return ""

NETALERTX_TOKEN = get_netalertx_token()
STATE_FILE = "/home/ale/.hermes/data/kuma-alert-state.json"
NOTIFIED_DIR = "/home/ale/.hermes/data/kuma-notified"

os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)

def http_get(url, headers=None):
    try:
        req = urllib.request.Request(url, headers=headers or {})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"error": str(e)}

def netalertx_present(mac="", ip=""):
    """Check if a device is present on the network via NetAlertX API."""
    try:
        if mac:
            data = http_get(f"{NETALERTX_API}/device/{mac}",
                {"Authorization": f"Bearer {NETALERTX_TOKEN}"})
            if data.get("success") is False:
                return None
            return bool(data.get("devPresentLastScan"))
        if ip:
            devices = http_get(f"{NETALERTX_API}/devices",
                {"Authorization": f"Bearer {NETALERTX_TOKEN}"})
            if isinstance(devices, dict) and not devices.get("success", True):
                return None
            devs = devices.get("devices", devices) if isinstance(devices, dict) else devices
            for d in devs:
                if d.get("devLastIP") == ip:
                    return bool(d.get("devPresentLastScan"))
            return None
    except Exception as e:
        return None

def load_notified():
    try:
        with open(STATE_FILE) as f: return json.load(f)
    except: return {"notified": {}}

def save_notified(state):
    with open(STATE_FILE, "w") as f: json.dump(state, f)

state = load_notified()
results = []

alerts_data = http_get(f"{WEBHOOK_URL}/alerts")
alerts = alerts_data.get("alerts", [])

for alert in alerts:
    mid = str(alert.get("monitorID", "?"))
    hb = alert.get("heartbeat", {})
    status = hb.get("status", -1)
    name = alert.get("monitorName", "?")
    msg = hb.get("msg", "")
    hostname = alert.get("monitorHostname", "")
    ip = hostname if hostname.startswith("192.168.") else ""
    already = mid in state["notified"]

    if already and status == 1:
        results.append({"type": "resolved", "monitor": name, "msg": f"✅ {name} — recovered"})
        del state["notified"][mid]
        save_notified(state)
        continue
    if already and status == 0:
        continue

    if status == 0:
        present = netalertx_present(ip=ip) if ip else None
        severity = "🔴" if any(x in msg.lower() for x in ["error","timeout","refused"]) else "🟡"
        lines = [f"⬇️ {name}"]
        if msg: lines.append(f"  Reason: {msg}")
        present_label = {None: "? (API error)", True: "present on network", False: "NOT on network"}
        lines.append(f"  NetAlertX: {present_label.get(present, '?')}")

        results.append({"type": "down", "monitor": name, "msg": "\n".join(lines), "severity": severity})
        state["notified"][mid] = True
        save_notified(state)

if results:
    out = "## Uptime Kuma Alerts\n\n"
    for r in results:
        out += f"{r['msg']}\n\n"
    print(out.strip())