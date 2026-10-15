#!/usr/bin/env python3
# checkmk/ha_datasource.py — Checkmk datasource program for Home Assistant OS host resources.
#
# HA OS can't run the Checkmk agent, so this reads the HA "System Monitor" integration sensors
# (CPU, memory, disk, load, temperature) through the HA REST API and prints them as Checkmk
# local-check lines. Checkmk calls it instead of contacting an agent
# (rule: "Individual program call instead of agent access").
#
# Install inside the site (see homeassistant.md):  ~/local/bin/ha_datasource.py
# Token: HA long-lived access token in ~/etc/ha_token (chmod 600, never in Git)
#
# Usage:  ha_datasource.py --url http://<ha-host>:8123 [--token-file F] [--prefix P] [--cafile F]
import argparse, json, os, re, ssl, sys, urllib.error, urllib.request

# (pattern on entity_id suffix, service name, metric name, warn, crit) — first match wins.
# Thresholds only apply to "%"/"°C" values; None = metric only, never alerts.
RULES = [
    (r"processor_use|cpu",          "CPU utilization",  "util",             80, 90),
    (r"processor_temperature|temp", "CPU temperature",  "temp",             75, 85),
    (r"memory_use_percent|memory_usage$", "Memory",     "mem_used_percent", 85, 95),
    (r"swap_use_percent|swap_usage$", "Swap",           "swap_used_percent", 50, 80),
    (r"disk_use_percent|disk_usage", "Disk",            "fs_used_percent",  80, 90),
    (r"load_(\d+)m",                "Load",             None,             None, None),
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="HA base URL, e.g. http://192.168.1.10:8123")
    ap.add_argument("--token-file", default=os.path.expanduser("~/etc/ha_token"))
    ap.add_argument("--prefix", default="sensor.system_monitor_",
                    help="entity_id prefix of the System Monitor sensors")
    ap.add_argument("--cafile", help="CA bundle for https (e.g. Step-CA root)")
    ap.add_argument("--timeout", type=float, default=10)
    a = ap.parse_args()

    ctx = ssl.create_default_context(cafile=a.cafile) if a.url.startswith("https") else None
    token = open(a.token_file).read().strip()

    def get(path):
        req = urllib.request.Request(a.url.rstrip("/") + path,
                                     headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, timeout=a.timeout, context=ctx) as r:
            return json.load(r)

    print("<<<local:sep(0)>>>")
    try:
        cfg, states = get("/api/config"), get("/api/states")
    except (urllib.error.URLError, OSError, ValueError) as e:
        # One CRIT service instead of a broken datasource, so the cause is visible in the GUI
        print(f'2 "HA API" - Cannot query {a.url}: {e}')
        return
    print(f'0 "HA API" - Home Assistant {cfg.get("version", "?")} reachable, {len(states)} entities')

    found = 0
    for s in sorted(states, key=lambda s: s["entity_id"]):
        eid = s["entity_id"]
        if not eid.startswith(a.prefix):
            continue
        try:
            val = float(s["state"])
        except (TypeError, ValueError):          # "unavailable", "unknown", text states
            continue
        suffix = eid[len(a.prefix):]
        attrs = s.get("attributes", {})
        unit = attrs.get("unit_of_measurement", "")
        for pat, name, metric, warn, crit in RULES:
            m = re.search(pat, suffix)
            if not m:
                continue
            if name == "Load":
                name, metric = f"Load {m.group(1)}m", f"load{m.group(1)}"
            elif name == "Disk":                 # one service per disk sensor (e.g. disk_use_percent_config)
                tail = re.sub(r"^(disk_use_percent|disk_usage)_?", "", suffix)
                name = f"Disk {tail or '/'}"
            if unit not in ("%", "°C"):          # absolute values (GiB etc.): graph only
                warn = crit = None
            levels = f";{warn};{crit}" if warn is not None else ""
            label = attrs.get("friendly_name", eid)
            print(f'P "HA {name}" {metric}={val}{levels} {label}: {val:g} {unit}'.rstrip())
            found += 1
            break

    if not found:
        print(f'1 "HA System Monitor" - No numeric sensors with prefix {a.prefix} — '
              "add/enable the System Monitor integration entities in HA")

if __name__ == "__main__":
    sys.exit(main())
