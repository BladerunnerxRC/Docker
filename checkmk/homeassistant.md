# Home Assistant (HA OS) in Checkmk

## Why it needs a special setup
HA OS is an appliance: you can't install the Checkmk agent and it has no SNMP. Home
Assistant can measure its own host through the **System Monitor** integration, though.
[`ha_datasource.py`](ha_datasource.py) reads those sensors over the HA REST API and hands
them to Checkmk in place of an agent.

```
Checkmk ──(rule: Individual program call)──► ha_datasource.py ──HTTP+token──► HA :8123 /api/states
```

## What you get
| Service | Source sensor (System Monitor) | WARN / CRIT |
|---|---|---|
| HA API | `/api/config`: version, reachability | CRIT if HA doesn't answer |
| HA CPU utilization | Processor use | 80 / 90 % |
| HA CPU temperature | Processor temperature | 75 / 85 °C |
| HA Memory | Memory usage (%) | 85 / 95 % |
| HA Swap | Swap usage (%) | 50 / 80 % |
| HA Disk `<name>` | Disk usage (%), one service per disk sensor | 80 / 90 % |
| HA Load 1m/5m/15m | Load | graph only |

Sensors that are disabled, `unavailable`, or not percentages/°C are skipped or only graphed. To
change the thresholds, edit `RULES` at the top of the script.

## Setup
**1. HA: enable System Monitor sensors**
- *Settings → Devices & services → Add integration → **System Monitor***.
- Open the integration → its entities. Most are **disabled by default**. Enable *Processor use*,
  *Processor temperature*, *Memory usage*, *Swap usage*, *Disk usage* (for each mount you care
  about) and *Load (1m/5m/15m)*.
- Check the entity IDs start with `sensor.system_monitor_`. If yours differ, use `--prefix`.

**2. HA: create a token**
- Click your *Profile* (bottom left) → *Security* → *Long-lived access tokens* → *Create token*,
  name it `checkmk`, and copy it. It's only shown once.
- A dedicated non-admin HA user for this token is better than your admin account.

**3. Checkmk: store the token and install the script** (on optiplex-two)
```bash
# Paste the token, press Enter, then Ctrl-D. File is readable by the site user only.
docker exec -i checkmk su - cmk -c 'umask 077; cat > ~/etc/ha_token'

# Install the script into the site
docker cp ~/docker-repo/checkmk/ha_datasource.py checkmk:/omd/sites/cmk/local/bin/ha_datasource.py
docker exec checkmk chown cmk:cmk /omd/sites/cmk/local/bin/ha_datasource.py
docker exec checkmk chmod 755 /omd/sites/cmk/local/bin/ha_datasource.py

# Test (use the HA host's IP or name)
docker exec -it checkmk su - cmk -c 'ha_datasource.py --url http://<ha-ip>:8123'
```
Expect `0 "HA API" - Home Assistant 20xx.x reachable …` followed by `P "HA …"` lines.

**4. Checkmk: point the `homeassistant` host at the script**
- *Setup → search **"Individual program call instead of agent access"** → Add rule*
  - Command line: `ha_datasource.py --url http://$HOSTADDRESS$:8123`
  - Condition: explicit host `homeassistant`
- Host `homeassistant`: it must have its **IP address** set. Leave *Checkmk agent* at the default
  (*API integrations if configured, else Checkmk agent*); the rule replaces the agent. SNMP stays
  off.
- *Save & run service discovery → Accept all → Activate changes.*

If HA is only reachable over HTTPS through Traefik, use `--url https://homeassistant.shome
--cafile <Step-CA root.crt copied into the site>`.

## What it does NOT do
- **No Checkmk agent features.** There are no process or log checks, and no filesystem details
  beyond what System Monitor exposes.
- **Not the hypervisor's view.** If HA OS runs as a VM, the hypervisor sees things the guest
  can't (allocated vs used RAM, VM state). Monitor the hypervisor separately.
- **Doesn't watch HA entities or automations** (batteries, unavailable devices, pending
  updates). That needs a separate script.

## Troubleshooting
| Symptom | Fix |
|---|---|
| `HA API` CRIT, `HTTP Error 401` | Wrong or expired token. Recreate it and rewrite `~/etc/ha_token`. |
| `HA API` CRIT, timeout / refused | HA is on another VLAN/IoT network. Add a router rule from optiplex-two to HA on TCP 8123, or use the Traefik URL. |
| `HA System Monitor` WARN "No numeric sensors" | The entities are still disabled, or they use a different prefix. Check *Developer tools → States*, filter on `system_monitor`. |
| CPU temperature missing | Not every VM/hardware exposes it. That's expected. |
