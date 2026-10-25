# Checkmk Deployment — Session Handoff

> Last updated 2026-10-25 (optiplex-three NTP flapping diagnosed, temperature levels). Previous: 2026-10-23 (CPU-starvation fix, router interfaces, failed-unit cleanup). Read this first, then continue from "Next steps".
> This file merges the former branches `checkmk-handoff-update` (2026-10-12/13) and `dev-checkmk-onboarding-docs` (2026-10-14/20).
> Host addresses, hardware specs, SNMP communities and other environment details live in the gitignored
> `HANDOFF-POC.local.md` next to this file (local only — not in the public repo).

## Working style
- Professional, clear, concise. When asked for clarification, answer at an 11th-grade reading level.
- Direct and technical; no sugar-coating. Check work before delivering.
- Scripts: ask for diagnostics/logs before proposing fixes; iterate run → logs → fix.
- "mod and print" = modify the file in progress and print the ENTIRE file.
- Infra/config: stack-ready YAML, commented.
- Suggest continued improvements to code.
- Changes to `main` go through a PR (branch protection); don't push to `main` directly. Branch names: `dev-…` / `fix-…` (see `CLAUDE.md`).
- Claude has no SSH access to the hosts: the user runs commands and pastes output. The admin workstation can reach the router over SNMP.

## Goal
Deploy Checkmk Community (formerly Raw) to monitor the home lab, fronted by Traefik at `https://checkmk.shome`.

## Environment
See `HANDOFF-POC.local.md` for IPs, OS, CPU/RAM/disk per host.

| Host | K3s role | Checkmk role |
|---|---|---|
| optiplex-two | worker | **Checkmk server (Docker)** + agent |
| optiplex-docker | **control plane** | agent; also runs Borg UI; **Tailscale subnet router + exit node** |
| optiplex-three | worker (cordoned — see open items) | agent; **only disk is a 29 GB eMMC — migration planned** |
| smiddleware | n/a | agent — Traefik/Step-CA/AdGuard host (ARM64) |
| homeassistant | n/a | SNMP + HTTP + `ha_datasource.py` (Home Assistant OS — no agent possible) |

- K3s with MetalLB and Traefik. `kubectl` works only on optiplex-docker (workers have no kubeconfig).
- Internal domain pattern: `https://appname.shome`. Internal PKI: Step-CA.
- Portainer (Business Edition 2.45) GitOps from public repo `BladerunnerxRC/Docker`, ref `refs/heads/main`, Compose path `checkmk/docker_compose.yml`, stack name `checkmk`. Public repo — no Git authentication. Secrets go in Portainer stack env vars only. **A merge to `main` redeploys (restarts) the container.**
- Backups: Borg UI (on optiplex-docker) to Synology NAS. Checkmk site backed up nightly by the optiplex-two Borg prep script (borg-backup 3.0.0).
- LibreNMS (K3s) was **removed 2026-10-13; Checkmk replaces it** — see "LibreNMS — removed" below.

## Decisions made
- **Server host:** optiplex-two, Docker (not K3s, not native .deb).
  - smiddleware rejected: ARM64 (Checkmk server/image is amd64 only) and it hosts critical infra.
  - optiplex-three rejected: too little RAM, eMMC storage.
  - optiplex-docker: backup option only (busiest node, weaker CPU).
- **Version:** Checkmk 2.5.x, must be **≥ 2.5.0p9** (CVE-2026-8593). **Image pinned to `2.5.0p17`** (2026-10-22, commit `67746a4`). Agents on hosts are 2.5.0p15.
- **Core:** this Community site runs **Nagios** (`omd config cmk show CORE`). Its `nagios.cfg` is generated under `tmp/`, not `etc/nagios/nagios.cfg`. Service check timeout is the 60 s default.
- **CPU cap 3.0, memory 4 GiB** (2026-10-22). Steady load is 0.6–0.9 cores; 2.0 was too tight for bursts (see Completed 2026-10-22).
- **Periodic service discovery: every 24 h** (was the 2 h default; changed in the UI 2026-10-22).
- **Web UI port:** host `8081` → container `5000`. Not 8080: `kubectl` on optiplex-two defaults to `localhost:8080`.
- **TZ:** `America/Detroit` (Eastern, same DST as New_York). See gotcha 1.
- **Site ID stays `cmk`.** Renaming it breaks the compose (`CMK_SITE_ID` creates a new empty site), the tmpfs path, every agent registration, the `/cmk/` URL and the Borg prep (`omd backup … cmk`). The display name is the site **alias** ("Smith LAN"); change only that. Hide `/cmk/` behind the Traefik route instead.
- **Docker plugin naming:** `container_id: combined` on every Docker host → piggyback hosts named `<host>_<container>`. Names like `portracker` / `portainer` exist on several hosts and would collide otherwise.
- **SNMP for Home Assistant:** HA OS is read-only and add-ons are containers, so no agent; SNMPD add-on + HTTP check on :8123 + [`ha_datasource.py`](ha_datasource.py).
- **No custom Synology drive-health plugin** (2026-10-18). DSM's own notifications already alert on drive health; SNMP gives no drive serials, so SMART rows can't be matched to bays.

## Stack
Source of truth: [`docker_compose.yml`](docker_compose.yml) in this folder.

## Scripts in this folder
| Script | Purpose | Docs |
|---|---|---|
| [`snmp-preflight.sh`](snmp-preflight.sh) | Test SNMP from inside the Checkmk container before adding a device | header comment |
| [`create-piggyback-hosts.sh`](create-piggyback-hosts.sh) | Create container hosts from piggyback data and place them in stack folders | [`create-piggyback-hosts.md`](create-piggyback-hosts.md) |
| [`ha_datasource.py`](ha_datasource.py) | Datasource program: HA OS host resources (System Monitor sensors via HA API) | [`homeassistant.md`](homeassistant.md) |

## Checkmk host layout
Established 2026-10-14/15. IPs and SNMP credentials are in `HANDOFF-POC.local.md` or Checkmk only. Never put them in this public file.

### Folder tree
```
Main/                          servers + network gear (agent / SNMP hosts)
└─ Docker Stacks/                every container host lives below here (folder *name* = ROOT_FOLDER in the script, default `docker`; check the URL)
    ├─ <stack>/                     one subfolder per Compose / Portainer stack
    │   ├─ stack-<stack>            dummy "stack host" (topology node only)
    │   └─ <node>_<container> …     container hosts (piggyback)
    └─ <node>_<container>           single-container apps without a stack folder
```

| Level | Attributes set **here** (everything else inherited) |
|---|---|
| **Docker Stacks** folder | IP address family **No IP** · Checkmk agent **No API integrations, no Checkmk agent** · SNMP **No SNMP** · Piggyback **Always use and expect piggyback data** · label `type:container` |
| **`<stack>`** subfolder | Parents **`stack-<stack>`** · label `stack:<stack>` |
| **`stack-<stack>`** host | Parents **the Docker node** (overrides the folder, which would otherwise make it its own parent → core config error) · Piggyback **Never use piggyback data** · labels `role:stack`, `stack:<stack>` (host labels replace folder labels, so repeat `stack:`) |
| **Container** hosts | **Nothing.** All inherited. Exception: containers directly in Docker Stacks set Parents = their Docker node. |

Topology result: `sw-t2600g → <docker node> → stack-<stack> → containers`.

### Container hosts (piggyback)
- Agent plugin `mk_docker.py` is installed by hand on each Docker node (Community edition has no Agent Bakery): `/usr/lib/check_mk_agent/plugins/mk_docker.py` (sync, **not** `plugins/300/`), plus `python3-docker`.
- `/etc/check_mk/docker.cfg` → `container_id: combined`, so host names are **`<node>_<container>`** (e.g. `optiplex-docker_komga`). A host named after the bare container gets no data.
- `skip_sections: docker_container_agent` (no agents inside containers; avoids a `docker exec` per container per poll).
- Bulk-create with [`create-piggyback-hosts.sh`](create-piggyback-hosts.sh): usage, scope and limits are in [`create-piggyback-hosts.md`](create-piggyback-hosts.md) (dry run by default, `--apply` to change). New hosts get no attributes and go into their Compose project's stack folder. The script creates the folder and the stack host when a project has ≥ 2 containers. It never touches existing hosts.
- `Docker container health` service = the container's own `HEALTHCHECK` (Dockerfile or compose `healthcheck:`); Checkmk only reads Docker's status. Containers without one get no health service, so add healthchecks to stacks that lack them.
- "No rate available (time anomaly)" / "Initializing counters" on a new container is normal for 1–2 check cycles. If it persists, check that the piggyback files refresh every minute and that node clocks agree.
- `smart_posix` (needs smartctl 7.x) goes in `/usr/lib/check_mk_agent/plugins/300/` (async, 5 min). Installed on optiplex-docker; smiddleware/optiplex-two status unverified.

### Rules (Setup → search for the rule name)
| Rule | Value | Condition |
|---|---|---|
| Host check command | Always assume host to be up | host label `role:stack` |
| Enable/disable notifications for hosts | Disable | host label `role:stack` |
| Network interface and switch port discovery — *Single Port Switch Discovery* | Appearance: **Use alias**; port states up + down | host label `cmk/device_type:switch` |
| Network interface and switch port discovery — *Name interfaces by description* | Appearance: **Use description**; pad port numbers; **up ports only** | hosts `router`, `sw-t2600g` |
| Network interface and switch port discovery — *Group … as …* (one rule per renamed interface) | Single interfaces as above **+ one interface group** (name = new service name) | host `router` + *Match interface description (regex)* `^<if>$`; placed **above** "Name interfaces by description" |
| Network interfaces and switch ports | Ignore speed; states 1/2/7 → OK (desktop/room ports keep graphs, never alert) | host `sw-t2600g`, explicit services **negated** = infrastructure ports |
| Network interfaces and switch ports (planned) | Error levels 25 % / 50 %, averaged 15 min | host `router`, service `Interface wifi` |
| Disabled services — *Router: hide loop/flash disks and virtual Wi-Fi* | loop / mtdblock / mmcblk0p* / `Interface wlan` / `Interface bwlan` / `Interface lo$` / `Interface wifi0..2` | host `router` |
| Periodic service discovery | every **24 h** | (existing rule, edited 2026-10-22) |
| State of NTP time synchronization (planned 2026-10-25, not yet confirmed created) | Time without sync: WARN **1 h** / CRIT **2 h**; offset + stratum left at defaults | host `optiplex-three` (or all chrony hosts) |

### Router (Synology RT6600ax, SRM) interfaces
Mapped 2026-10-22/23 over SNMP; MACs, subnets and the full interface table are in the local file.
- **`ifAlias` is empty on every interface** and SRM can't set port descriptions, so *Use alias* can't rename anything. Readable names come from **one-interface groups** (rule above): group `wifi 2.4G` → service `Interface wifi 2.4G`.
- **Wi-Fi:** `wifiN` = the radio itself, carrying mostly broadcast/management traffic (all three spike together; RX near zero). Client data is on the per-SSID interfaces `wlan<R><SS>` (R = radio, SS = SSID slot) and the mesh backhaul `bwlan<R>`, which the Disabled-services rule hides. Each `wlan<R><SS>` MAC equals a BSSID from a Wi-Fi scan, which gives:

  | Radio | Band | Group name |
  |---|---|---|
  | `wifi0` / `wlan0xx` / `bwlan0` | 2.4 GHz | `wifi 2.4G` |
  | `wifi1` / `wlan1xx` / `bwlan1` | 5 GHz upper (SRM "5G-2") | `wifi 5G-2` |
  | `wifi2` / `wlan2xx` / `bwlan2` | 5 GHz lower (SRM "5G-1") | `wifi 5G-1` |

  `wifiN` ↔ radio N is from naming only (the router has no `ifStackTable`). SSID slot `00` = primary network, `02` = S-IoT, `01` = a hidden SSID (unidentified). The SRM *Wi-Fi Transfer Rates* widget likely totals all mesh points, so it won't match the main router's counters exactly.
- **Ports:** `eth0` = WAN. `eth1`, `eth3`, `eth4` = the three trunk ports (Primary untagged; Guest 1733, S-test 111, S-IoT 50 tagged). `eth2` = **SRM Port 3** (S-test access port, nothing plugged in, down). So Linux `ethN` ≠ SRM "Port N"; which of eth1/3/4 is Port 1/2/4 is unknown. `eth1` is **likely** the uplink to `sw-t2600g` (its MAC is the LLDP neighbor on the switch's fiber port).
- **Bridges** (one per network; counters show only traffic to/from the router — internet, inter-VLAN, router services): `lbr0` primary LAN, `gbr0` guest, `lbr2` S-IoT, `lbr3` S-test, `lbr4` VLAN 30 (**orphan**: no name, IP or port in SRM, but still present on every trunk).
- Planned group names: `WAN eth0`, `Trunk-T2600G eth1`, `Trunk eth3`, `Trunk eth4`, `LAN lbr0`, `Guest gbr0`, `IoT lbr2`, `S-test lbr3`, `VLAN30-orphan lbr4`. Old single services hidden with Disabled-services patterns `Interface eth0`, `Interface eth1$`, `Interface eth3$`, `Interface eth4$`, `Interface lbr`, `Interface gbr` (optional `Interface eth\d+\.` for the VLAN subinterfaces).
- S-IoT has Wi-Fi devices only; SRM firewall rules route it to Home Assistant and the primary LAN.

### Switch (SNMP)
- **TP-Link T2600G-18TS v2** (JetStream), host `sw-t2600g`, SNMP **v2c**, read-only community, `viewDefault` (whole tree). Credentials are in the Checkmk host properties only.
- Verified with [`snmp-preflight.sh`](snmp-preflight.sh): sysDescr, ifTable, ifAlias, **64-bit counters** all pass.
- Port names come from switch port descriptions (ifAlias). Set them in the switch UI under *L2 Features → Port Config*.
- Parents: `sw-t2600g` has none (root). Every host cabled to it has Parents = `sw-t2600g`.
- Expected quirks: CPU reads 75–85 % on this model (raise *CPU utilization for simple devices* to 90/95 if it alerts); PCs that are off report 10 Mbit/s (Wake-on-LAN), which is why desktop ports ignore speed.
- TODO: move from the v2c community to a dedicated SNMPv3 `authPriv` user.

### Pitfalls hit (don't repeat)
- **A host must never be its own parent**, including through an inherited folder parent. It fails activation with `Host 'x' cannot be a child/parent of itself`. Find it with `docker exec -it checkmk su - cmk -c 'cmk -U 2>&1 | grep -i error'`.
- **Revert changes** restores the snapshot from the last activation *attempt*, failed ones included. Fix the config and activate instead.
- **Dummy hosts need IP address family = No IP**, otherwise activation warns `Cannot lookup IP address` and the host shows DOWN.
- **Discovered host labels only apply after they're accepted**, so rules conditioned on `cmk/…` labels don't match until you click *Accept all*.

### Checklist: add a new stack
1. **Folder.** Create *Docker Stacks → Add folder* `<stack>`, then in its properties set Parents = `stack-<stack>` and Labels = `stack:<stack>`.
2. **Dummy host.** Add `stack-<stack>` inside the folder with Parents = the Docker node it runs on (explicitly), Piggyback = **Never use piggyback data**, and Labels = `role:stack` + `stack:<stack>`. Leave IP/agent/SNMP inherited (No IP / no agent / no SNMP).
3. **Containers.** Create or move the `<node>_<container>` hosts into the folder with **no** host attributes set (each field should read *inherited*). Or run `./create-piggyback-hosts.sh` first as a dry run, then with `--apply`.
4. **Activate.** *Save & run service discovery* on one container to check that the data source reads `[piggyback] Success`, then **Activate changes**. On *Monitor → Parent / Child topology* the containers should hang under `stack-<stack>`.

## Completed (2026-10-12)
1. **Checkmk deployed** on optiplex-two via Portainer; healthy; container uses ~2 GiB of its 4 GiB cap. `cmkadmin` password reset with `cmk-passwd` (the `CMK_PASSWORD` env var only applies at first site creation — it was empty then).
2. **Agents:**

   | Host | Mode | Docker plugin | Notes |
   |---|---|---|---|
   | optiplex-two | TLS registered | ✅ `combined` | Server polls its own host from the Docker bridge subnet, not the LAN IP |
   | optiplex-docker | TLS registered | ✅ installed; verify `combined` cfg | Checkmk host IP was wrong (pointed at the admin workstation); fixed |
   | optiplex-three | TLS registered | n/a | Confirm `cmk-agent-ctl status` shows hostname `optiplex-three` |
   | smiddleware | **Legacy plaintext** (ARM: no agent controller) | ✅ `combined` | systemd socket drop-in limits TCP 6556 to the Checkmk server + localhost |

3. **Plugins:** `mk_docker.py` with `/etc/check_mk/docker.cfg`:
   ```ini
   [DOCKER]
   container_id: combined
   skip_sections: docker_container_agent   # no agents inside containers; avoids a docker exec per container per poll
   ```
4. **Container hosts:** first 8 hosts created by hand; superseded by the *Docker Stacks* layout and `create-piggyback-hosts.sh` (2026-10-14/15). Host state follows the `Docker container status` service via Checkmk's built-in rule (label `cmk/docker_object:container`).
5. **Kubelet reservations + memory eviction on all three nodes** (`/etc/rancher/k3s/config.yaml`, `kubelet-arg`; every node also has `eviction-hard=memory.available<256Mi,nodefs.available<5%,imagefs.available<5%`). Verified allocatable:

   | Node | system-reserved | kube-reserved | Allocatable mem | Allocatable CPU | Restart unit |
   |---|---|---|---|---|---|
   | optiplex-two | cpu=1500m, mem=5Gi | cpu=250m, mem=512Mi | 9699068Ki | 2250m | `k3s-agent` |
   | optiplex-docker | cpu=1000m, mem=4Gi | cpu=500m, mem=1Gi | 10157196Ki | 2500m | `k3s` |
   | optiplex-three | cpu=250m, mem=512Mi | cpu=250m, mem=256Mi | 2432200Ki | 3500m | `k3s-agent` |

   These budget scheduling only (K3s enforces `pods`), so Docker containers outside K3s (including Checkmk) are not capped by them.
6. **PRs merged:** #21 (host details → gitignored local file), #23 (TZ fix).

## Completed (2026-10-13) — alert cleanup
1. **optiplex-docker stale NFS mounts removed** (`/mnt/docker_grafana_data`, `/mnt/docker_postgres_main_data`, `/mnt/docker_postgres_main_dumps` from the NAS). They were CRIT `NFS mount … State: Hanging`. No container used them. Lazily unmounted, automount units stopped, fstab lines commented out (backup `/etc/fstab.bak.2026-10-13`), `daemon-reload` + `reset-failed`, empty mountpoint dirs deleted. See gotcha 10.
2. **smiddleware memory cgroup enabled** (Pi 5). Container `Memory` services were UNKN ("Reported total memory is 0 B"). Appended `cgroup_enable=memory cgroup_memory=1` to `/boot/firmware/cmdline.txt` (backup `cmdline.txt.bak.2026-10-13`), rebooted. See gotcha 9.
3. **smiddleware `/mnt/backups` (Borg NFS share) now mounts at boot** (removed `x-systemd.automount,x-systemd.idle-timeout=600`; kept `_netdev,nofail`; backup `/etc/fstab.bak.2026-10-13`).
4. **NFS usage levels:** rule in Main folder, ruleset "Network file system - overall status and usage (e.g. NFS)": warn 85% / crit 90%. Every NFS mount points at NAS volume1, so they all WARN together. Now that smithvault is on SNMP, monitor volume1 there and drop the usage levels from this rule.
5. **optiplex-docker `/mnt` strays removed** and the four Borg repo NFS mounts switched from automount to mount-at-boot (backup `/etc/fstab.bak.2026-10-13-borg`). Left alone: `Software_Backup` and the Manyfold bind mount `/srv/manyfold/library_nas`.
6. **optiplex-three `systemd-networkd-wait-online` fixed:** `sudo netplan set ethernets.enp1s0.optional=true` (unused second NIC, no cable). `enp2s0` is the live NIC.
7. **optiplex-two `logrotate.service` fixed** (duplicate cloud-init logrotate config). Same fix applied proactively on optiplex-docker. See gotcha 12.
8. **Diagnosed Check_MK Discovery WARN** on container hosts: unaccepted services/labels. See gotcha 11.

## Completed (2026-10-14 → 2026-10-20)
1. Docker Stacks folder layout, stack hosts and `create-piggyback-hosts.sh` (see "Checkmk host layout").
2. Switch `sw-t2600g` on SNMP, verified with `snmp-preflight.sh`.
3. Home Assistant host resources via `ha_datasource.py` (see [`homeassistant.md`](homeassistant.md)).
4. Former LibreNMS devices re-created: router, the three NASes, printer, loft access point, ONT, Home Assistant (see open items for the two still broken).
5. **checkmk-sites Borg backup done** (borg-backup 3.0.0, PR #28). optiplex-two's Borg prep runs `omd backup --no-compression cmk` every night into `databases/checkmk-cmk-<version>-<date-time>.omd.tar` (consistent; restore with `omd restore` on the same Checkmk version). The raw volume is also covered via `/var/lib/docker/volumes`. Still to do: one restore test — see [`borg-backup/HANDOFF.md`](../borg-backup/HANDOFF.md).

## Completed (2026-10-22/23)
1. **`Check_MK Discovery` timed out on almost every host — fixed.** Root cause: the container was **CPU-starved at its 2.0 cap**: throttled in 89 % of CFS periods (`/sys/fs/cgroup/cpu.stat`), averaging 1.83 cores. Real load is only **0.6–0.9 cores** (49 hosts, 786 services). Discovery checks ran in bursts of ~10 every 2 h. Each burst pushed the site over the cap, checks hit the 60 s timeout, their CPU was wasted and they re-ran, so the site stayed pinned. The Nagios log showed 872 `Check_MK` + 402 `Check_MK Discovery` timeouts (2026-10-19 → 22), peaking every even hour, starting right after SMITHVAULT added 136 SNMP services. The p17 auto-update was **not** the trigger: it came 25 h after the first timeout. Fixes:
   - `cpus: "3.0"` and image pinned to `2.5.0p17` in [`docker_compose.yml`](docker_compose.yml) (commit `67746a4`).
   - Periodic service discovery 2 h → 24 h.
   - One-time staggered reschedule (one Discovery check every 10 s): 29 CRIT → 35 OK / 1 CRIT (the remaining one is `RT2600AC-Loft`, a config issue). Command in "Useful commands".
   - Ruled out on the way: the agents and network (piggyback hosts timed out too), a piled-up process, the web UI (an open tab costs ~0.3 cores), host iowait.
2. **Router interfaces mapped** (see "Router interfaces"): Wi-Fi band per radio, ports/VLANs, bridges. Wi-Fi radio services renamed with interface groups (`Interface wifi 2.4G / 5G-1 / 5G-2`); old `Interface wifi0..2` disabled.
3. **optiplex-docker: 6 failed units cleared** (all date from the Oct 3 release upgrade to 26.04):
   - `pmcd`, `pmie`, `pmlogger`, `pmproxy`: `pcp` was removed-not-purged during the upgrade and `pcp-conf` purged, so leftover `/etc/init.d/pm*` scripts failed with `/etc/pcp.conf not found`. Fix: `apt purge pcp`, `rm -rf /var/log/pcp /var/lib/pcp`.
   - `swap.img.swap`: `/swap.img` gone (8 GB `/swapfile` is active). fstab line commented out (backup `/etc/fstab.bak-2026-10-23`).
   - `netfilter-persistent`: during the upgrade, `iptables-persistent` saved the **full live ruleset** (K3s/Docker/Tailscale rules), which can't be restored at boot (`RULE_APPEND failed … KUBE-FORWARD`). Its 3 hand-made rules (2× FORWARD tailnet↔LAN, 1× nat MASQUERADE tailnet→LAN, needed because Docker sets FORWARD policy DROP) now come from **`tailscale-lan-forward.service`** → `/usr/local/sbin/tailscale-lan-forward.sh` (idempotent `iptables -C || -A`, runs after docker + tailscaled). `iptables-persistent` + `netfilter-persistent` purged; old rules backed up in `~/iptables-backup-2026-10-23/`. Tailscale LAN access verified working afterwards. See gotcha 17.
4. **optiplex-three `smartmontools` diagnosed:** smartd exits 17 "No devices to monitor" because the only disk is eMMC (`mmcblk0`, no SMART). Fix: `sudo systemctl disable --now smartmontools && sudo systemctl reset-failed smartmontools` (not yet confirmed run), or NVMe migration (open items).
5. **Site alias** set to "Smith LAN".

## Diagnosed (2026-10-25)
1. **optiplex-three `NTP Time` flapping** (FLAPPINGSTART several times a day). Not the offset: max 3.16 ms over 35 days vs 200/500 ms levels. Every WARN is *Time since last sync* at 17 min 15–41 s against **warn 17 min 5 s / crit 1 h**. chrony backs off to `maxpoll 10` = 1024 s (17 min 4 s), so before each poll the age crosses 17:05 by a few seconds of jitter, then resets to ~1 min → OK. One WARN/OK pair per poll cycle; the clock is fine. The service has only one source (`ntp.ubuntu.com`, 91.189.91.112). Fix: the NTP rule in "Rules" above (no rule existed; defaults in use). **Unverified assumption:** the 17:05 WARN is the check raising the default 5 min *alert delay* to poll interval + 1 s (CRIT 1 h = default). If the summary still shows `17 minutes 5 seconds` after the rule, the check forces it and the alternative is `maxpoll 9` in chrony.conf.
2. **optiplex-three `Temperature Zone 1` went straight to CRIT at 50 °C:** WARN and CRIT are both 50 °C, so it never WARNs, and 50 °C is low for a CPU/SoC zone under load. Raise to ~70/80 °C (ruleset *Temperature*, condition host `optiplex-three`, service `Zone 1`).

## Gotchas learned
1. **TZ with `_` crash-loops the container.** Checkmk 2.5.0 `docker-entrypoint.sh` runs `sed -i -E "s_^TZ=.*_TZ=\"${TZ}\"_"` on every start after the first; the `_` in `America/New_York` breaks the expression, `set -e` exits, `restart: unless-stopped` loops. First boot works, so it only shows on redeploy. Upstream bug — could be reported.
2. **`CMK_PASSWORD` is read once**, at site creation. Changing it later does nothing; use `docker exec -it checkmk su - cmk -c "cmk-passwd cmkadmin"`.
3. **ARM hosts:** the agent `.deb` installs in legacy mode (no `cmk-agent-ctl`). **Never click "Provide TLS connection"** on them. Fix if done: host properties → **Host → Remove TLS registration**.
4. **Piggyback-only hosts** must use **No API integrations, no Checkmk agent**. "Configured API integrations, no Checkmk agent" raises `host configuration requires a datasource but none configured` (this is what `RT2600AC-Loft` shows now).
5. **Server monitoring its own host:** traffic to the host's agent comes from the Checkmk container's Docker bridge subnet, not the LAN IP — firewall rules on optiplex-two must allow that subnet.
6. **Ubuntu 26.04 uses Rust coreutils/sudo-rs**: errors look like `(os error 2)`; `tee` cannot create a missing directory.
7. **Heredocs pasted into a terminal** sometimes arrive incomplete (shell sits at `>`). Prefer single-line `printf ... | sudo tee` when that happens.
8. `mk_docker.py ... | head` ends in `BrokenPipeError` — harmless, caused by `head`.
9. **Pi 5 container Memory UNKN** ("Reported total memory is 0 B"): Pi firmware injects `cgroup_disable=memory`. Append `cgroup_enable=memory cgroup_memory=1` to `/boot/firmware/cmdline.txt` and reboot. Redo after any reimage.
10. **Removing an fstab line doesn't unmount.** With `x-systemd.automount`, systemd re-mounts on any access. Comment out the line, `systemctl stop <unit>.automount`, `daemon-reload`, `reset-failed`.
11. **Check_MK Discovery WARN on container hosts** = unaccepted services/labels. Run bulk discovery on the container folder; the `cmk/docker_object:container` label must be accepted for the host-state rule to apply.
12. **Ubuntu `cloud-init` + `cloud-init-base` logrotate overlap:** both ship the same rotation, so `logrotate.service` fails nightly. Fix: `sudo mv /etc/logrotate.d/cloud-init /root/logrotate.d-cloud-init.old && sudo systemctl start logrotate`.
13. **A CPU cap that's slightly too small looks like a much bigger load.** When checks time out they waste CPU and re-run, so usage climbs to whatever the cap allows. Check throttling, not just usage: `docker exec checkmk cat /sys/fs/cgroup/cpu.stat` (`nr_throttled / nr_periods`). Measure true load right after raising the cap (`docker update --cpus N checkmk`, live, no restart; a redeploy resets it).
14. **A floating image tag updates itself on every Portainer redeploy.** Keep `image:` pinned; `omd restore` needs the same version. Bump deliberately, after an `omd backup`.
15. **Livestatus `GET log` returns newest first**, so "first"/"last" swap when post-processing. Its `execution_time` is wall time, inflated by throttling; Checkmk's own reported check time leaves out interpreter startup (~2.6 s CPU per `cmk` run).
16. **Router Wi-Fi `wifiN` error % is noise:** few packets, mostly broadcast/management. Use loose levels (25/50 %, 15 min average) or monitor the per-SSID `wlan<R>00` interfaces for real client traffic.
17. **`iptables-persistent` on a K3s/Docker/Tailscale host is a trap.** "Save current rules?" (asked on package upgrade) snapshots rules those services rebuild themselves; the restore then fails at boot, and a manual `netfilter-persistent reload` would **flush** the live `filter`/`nat` tables. Keep only hand-made rules, in an idempotent systemd unit.
18. **Interface grouping membership comes from the rule's *Conditions for this rule to apply*,** not a per-group regex. One rule per group; **Add pattern** adds another group with the same members. Clone the single-interface settings exactly, or other interfaces change names.
19. **Disabled-services patterns are regex prefix matches.** Anchor with `$` where needed (`Interface eth1$` vs `eth1.111`); a group name with a space (`Interface wifi 2.4G`) doesn't match `Interface wifi0`.
20. **`apt remove` leaves SysV init scripts behind**, which systemd turns into "LSB: …" units that fail at boot. `apt purge` the package (state `rc` in `dpkg -l`).
21. **Flapping: read the event history before touching flap detection.** *Monitor → host → Events of hosts & services* shows the output of each non-OK state. Here it was a threshold sitting 1 s above chrony's poll interval, not a real fault. `Current check attempt 1/1` means one bad result = hard state change; *Maximum number of check attempts* (e.g. 3) damps short blips.

## Useful commands
```bash
# CPU throttling of the Checkmk container (run twice, 30 s apart; compare nr_throttled vs nr_periods)
docker exec checkmk cat /sys/fs/cgroup/cpu.stat

# Discovery state counts: OK;WARN;CRIT
docker exec -u cmk checkmk bash -lc 'printf "GET services\nFilter: description = Check_MK Discovery\nStats: state = 0\nStats: state = 1\nStats: state = 2\n" | lq'

# Re-run all CRIT Discovery checks, one every 10 s (spreads them out for good)
docker exec -u cmk checkmk bash -lc '
now=$(date +%s); i=0
printf "GET services\nColumns: host_name\nFilter: description = Check_MK Discovery\nFilter: state = 2\n" | lq |
while read -r h; do
  printf "COMMAND [%s] SCHEDULE_FORCED_SVC_CHECK;%s;Check_MK Discovery;%s\n" "$now" "$h" $((now + i*10)) | lq
  i=$((i+1))
done'

# Timeout alerts per hour over 3 days (epoch hour; lq lists newest first)
docker exec -u cmk checkmk bash -lc 'printf "GET log\nColumns: time\nFilter: time >= %s\nFilter: plugin_output ~ Timed Out\n" $(( $(date +%s) - 3*86400 )) | lq | awk "{h[int(\$1/3600)]++} END{for(k in h) print k*3600, h[k]}" | sort -n'
```

## Manual site backup / restore
Quick, no downtime. Run on optiplex-two:
```bash
TS=$(date +%Y%m%d-%H%M)
docker exec checkmk omd version cmk                                   # record it: restore needs the same version
docker exec checkmk omd backup --no-past cmk /tmp/cmk-$TS.tar.gz      # --no-past = config only, no graph/log history; drop it for a full backup
docker cp checkmk:/tmp/cmk-$TS.tar.gz ~/ && docker exec checkmk rm /tmp/cmk-$TS.tar.gz
ls -lh ~/cmk-$TS.tar.gz                                               # then copy it off the host (e.g. to the NAS)
```
Restore (same Checkmk version):
```bash
docker cp ~/cmk-<TS>.tar.gz checkmk:/tmp/
docker exec checkmk omd stop cmk
docker exec checkmk omd restore --reuse /tmp/cmk-<TS>.tar.gz
docker exec checkmk omd start cmk
```

## LibreNMS — removed 2026-10-13
Removed from K3s early (it had 22 alert rules but **no alert transports** — it notified no one). The devices were re-created in Checkmk afterwards (Completed 2026-10-14 → 20, item 4).

**Final backup** on the NAS, via optiplex-docker's `/mnt/backups/librenms-final/`:
- `librenms-db-2026-10-13.sql.gz` — full `mysqldump`, verified `-- Dump completed`.
- `librenms-retire/` — `librenms-values.yaml` (may contain secrets — never commit) and `devices-and-alerts.txt`. Original still in `~/librenms-retire/` on optiplex-docker.
- `opt-k3-librenms-tooling.tgz` — the old install scripts/manifests/values from `/opt/k3/librenms`.
- RRD graph history was not kept.

**What was removed:** `helm uninstall librenms` (ns `default`); its PVCs/PVs and data; `/opt/k3/librenms`; by hand `svc/librenms-frontend` (frees its MetalLB IP) and `secret/librenms-env`.

**Still to do outside K3s:** remove the LibreNMS tile from Dashy and any AdGuard rewrite for it.

## Open items
- **optiplex-docker — after the next reboot,** confirm the Tailscale rules came back: `sudo iptables -S FORWARD | grep -c '100\.64'` = 2 and `sudo iptables -t nat -S POSTROUTING | grep -c '100\.64.*MASQUERADE'` = 1. If 0: `journalctl -u tailscale-lan-forward -b` (likely ran before `tailscale0` existed). Also confirm no NFS mounts return (`findmnt -t nfs,nfs4`), then delete `/etc/fstab.bak.2026-10-13`.
- **Router:**
  - Create the 9 interface-group rules for `eth0/1/3/4`, `lbr0/2/3/4`, `gbr0` (names under "Router interfaces"), add the Disabled-services patterns, run discovery, activate. Check `Interface LAN lbr0` and `Interface WAN eth0` show up.
  - Create the Wi-Fi error-level rule (25/50 %, 15 min, service `Interface wifi`) if not done.
  - Identify what's on trunk ports eth3/eth4 (unplug test or SRM Wi-Fi Points page) and rename those groups.
  - VLAN 30 (`lbr4`) looks orphaned — decide whether to delete it in SRM.
  - Optional: monitor `wlan000/100/200` (primary SSID per band) for client traffic by narrowing the `Interface wlan` disabled pattern (e.g. to `Interface wlan\d0[1-4]$`).
- **`Optical-Network-Terminal` PING UNKN** (`check_icmp: No hosts to check`): the host has no resolvable IP. Set its IPv4 address in the host properties.
- **`RT2600AC-Loft` Check_MK Discovery CRIT** (`requires a datasource but none configured`): set agent to *No API integrations, no Checkmk agent* and SNMP v2c (or ping only). See gotcha 4.
- **optiplex-three:**
  - **NTP rule:** create/confirm the *State of NTP time synchronization* rule (Diagnosed 2026-10-25), activate, then check the `NTP Time` summary reads `warn/crit at 1 hour 0 minutes/2 hours 0 minutes` and no new FLAPPINGSTART appears. Optional: add more chrony sources (e.g. `pool 2.ubuntu.pool.ntp.org iburst` or a local NAS/router).
  - **Temperature Zone 1** levels 50/50 °C → ~70/80 °C (Diagnosed 2026-10-25).
  - `smartmontools`: run the disable fix above (or let the NVMe migration solve it).
  - **Migrate off the eMMC.** Earlier plan: install an NVMe and clone the eMMC to it; then smartd starts on its own and `smart_posix` can be installed. Check the free M.2 slot first (needs M-key; if only the Wi-Fi slot is free, the A+E-key Ethernet adapter in it must come out). Until migrated, an eMMC wear local check (`mmc extcsd read /dev/mmcblk0`: Life Time Estimation A/B, Pre-EOL) is worth adding.
  - **Cordoned** (`Ready,SchedulingDisabled`) — predates these sessions. Confirm intentional, else `kubectl uncordon optiplex-three`.
- **Discovery cleanup from 2026-10-13** (may already be done — verify): optiplex-docker vanished `NFS mount` services; smiddleware `NFS mount /mnt/backups`; bulk discovery on the container folder; `Memory` OK on `smiddleware_adguardhome` / `smiddleware_traefik`.
- **optiplex-docker:** confirm `smart_posix` in `plugins/300/` and `docker.cfg` = `combined`.
- **Statping decommission (host side):** on optiplex-two, remove its orphaned volumes, the Portainer stack if listed, and `/data/compose/14`.
- **Backups:** check whether PRs #22 / #24 are still open or superseded by borg-backup 3.0.0 (#28). optiplex-docker had no Borg prep script (Manyfold Postgres, Komga, Portainer EE) — see `borg-backup/HANDOFF.md`. Do one Checkmk restore test.
- **Home Assistant:** SNMP credentials rule and HTTP rule for `:8123` if not done; see [`homeassistant.md`](homeassistant.md).

## Next steps
1. Open items above, router interface groups first (quick, and they make the router readable).
2. Traefik dynamic route on smiddleware: `checkmk.shome` → optiplex-two:8081, preserve `/cmk/`, redirect `/` → `/cmk/`, Step-CA leaf cert.
3. External watchdog for the Checkmk server itself (e.g. Home Assistant HTTP sensor on the web UI) — if optiplex-two dies, nothing alerts.
4. Notifications (none configured yet).
5. Synology NAS extras (all three on SNMP v2c already): UPS on the DS920+ (check built-in coverage first; a custom SNMP check is the fallback), HTTPS cert-expiry on each DSM UI, TCP checks for SMB 445 / NFS 2049. Replace the 2020 UPS battery.
6. Loft switch (TL-SG205E, no SNMP): ping + HTTP check on its web UI; keep its uplink port on the T2600G monitored.
7. Borg backup-age local check on each Borg source host (alert if the last good archive is > 26 h old) — the main monitoring gap.
8. Firewall review: TCP 6556 (server→agents), TCP 8000 (agents→server), UDP 161 (SNMP).
9. Kubernetes monitoring: Checkmk Kubernetes special agent + cluster collector (from optiplex-docker).
10. SNMPv3 on `sw-t2600g`.
11. Optional: SSH datasource for smiddleware to encrypt its agent traffic; "Checkmk Agent installation auditing" rule to silence the TLS WARN on smiddleware.
12. Optional: move optiplex-three's M.2 Wi-Fi-slot Ethernet adapter to optiplex-two as a dedicated NAS/storage link for Borg traffic (check the slot is free: `lspci -nn | grep -i -E 'network|ethernet|wireless'`).
