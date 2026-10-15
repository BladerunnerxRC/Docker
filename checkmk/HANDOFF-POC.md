# Checkmk Deployment — Session Handoff

> Context carried over from a claude.ai chat (2026-10-12), updated 2026-10-15. Read this first, then continue from "Next steps".
> Host addresses, hardware specs, and other environment details live in the gitignored
> `HANDOFF-POC.local.md` next to this file (local only — not in the public repo).

## Working style
- Professional, clear, concise. When asked for clarification, answer at an 11th-grade reading level.
- Direct and technical; no sugar-coating. Check work before delivering.
- Scripts: ask for diagnostics/logs before proposing fixes; iterate run → logs → fix.
- "mod and print" = modify the file in progress and print the ENTIRE file.
- Infra/config: stack-ready YAML, commented.
- Suggest continued improvements to code.

## Goal
Deploy Checkmk Community (formerly Raw) to monitor the home lab, fronted by Traefik at `https://checkmk.shome`.

## Environment
See `HANDOFF-POC.local.md` for IPs, OS, CPU/RAM/disk per host.

| Host | K3s role | Checkmk role |
|---|---|---|
| optiplex-two | worker | **Checkmk server (Docker)** |
| optiplex-docker | **control plane** | agent only |
| optiplex-three | worker | agent only |
| smiddleware | n/a | agent only — Traefik/Step-CA/AdGuard host |

- K3s with MetalLB and Traefik. `kubectl` works only on optiplex-docker (workers have no kubeconfig).
- Internal domain pattern: `https://appname.shome`. Internal PKI: Step-CA.
- Portainer GitOps from public repo `BladerunnerxRC/Docker`, ref `refs/heads/main`, Compose path `checkmk/docker_compose.yml`. Public repo — no Git authentication needed. Secrets go in Portainer stack env vars only.
- Backups: Borg to Synology NAS.
- LibreNMS/SNMP already running — decide later whether to retire it to avoid double SNMP polling.

## Decisions made
- **Server host:** optiplex-two, Docker (not K3s, not native .deb).
  - smiddleware rejected: ARM64 (Checkmk server/image is amd64 only) and it hosts critical infra.
  - optiplex-three rejected: too little RAM, eMMC storage.
  - optiplex-docker: backup option only (busiest node, weaker CPU).
- **Version:** Checkmk 2.5.x, must be **≥ 2.5.0p9** (CVE-2026-8593). Ubuntu 26.04 supported since 2.5.0p1.
- **Image:** `checkmk/check-mk-community`.
- **Web UI port:** host `8081` → container `5000` (decided 2026-10-12). Not 8080: `kubectl` on optiplex-two defaults to `localhost:8080`, so stray kubectl runs would hit Checkmk. 8081 and 8000 verified free on the host.

## Completed
1. Added kubelet reservations on optiplex-two in `/etc/rancher/k3s/config.yaml`:
   ```yaml
   kubelet-arg:
     - "system-reserved=cpu=1500m,memory=5Gi"   # Checkmk (4Gi cap) + Docker containers + OS
     - "kube-reserved=cpu=250m,memory=512Mi"    # K3s/kubelet itself
   ```
2. Restarted `k3s-agent`; verified from optiplex-docker:
   - Node Ready; Allocatable `cpu: 2250m`, `memory: 9961212Ki` (~9.5 GiB); `NodeAllocatableEnforced` present.
3. Stack committed to `main` at `checkmk/docker_compose.yml` (2026-10-12).

## Open item — memory eviction disabled
Kubelet log showed `HardEvictionThresholds` with only `imagefs.available` / `nodefs.available` (no `memory.available`). Recommended adding to the same `kubelet-arg` list on optiplex-two (then restart `k3s-agent`), and later on optiplex-docker and optiplex-three:
```yaml
  - "eviction-hard=memory.available<256Mi,nodefs.available<5%,imagefs.available<5%"
```
**Status unknown** — confirm with (on optiplex-docker):
```bash
# capacity − allocatable ≈ 5.75Gi if applied, 5.5Gi if not
kubectl get node optiplex-two -o jsonpath='{.status.capacity.memory}{"\n"}{.status.allocatable.memory}{"\n"}'
```

## Stack
Source of truth: [`docker_compose.yml`](docker_compose.yml) in this folder.

## Scripts in this folder
| Script | Purpose | Docs |
|---|---|---|
| [`snmp-preflight.sh`](snmp-preflight.sh) | Test SNMP from inside the Checkmk container before adding a device | header comment |
| [`create-piggyback-hosts.sh`](create-piggyback-hosts.sh) | Create container hosts from piggyback data and place them in stack folders | [`create-piggyback-hosts.md`](create-piggyback-hosts.md) |

## Checkmk host layout
Established 2026-10-14/15. Site `cmk` runs **2.5.0p15**. IPs and SNMP credentials are in `HANDOFF-POC.local.md` or Checkmk only. Never put them in this public file.

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
- `skip_sections: docker_container_agent` (no agents inside containers).
- Bulk-create with [`create-piggyback-hosts.sh`](create-piggyback-hosts.sh): usage, scope and limits are in [`create-piggyback-hosts.md`](create-piggyback-hosts.md) (dry run by default, `--apply` to change). New hosts get no attributes and go into their Compose project's stack folder. The script creates the folder and the stack host when a project has ≥ 2 containers. It never touches existing hosts.
- `Docker container health` service = the container's own `HEALTHCHECK` (Dockerfile or compose `healthcheck:`); Checkmk only reads Docker's status. Containers without one get no health service, so add healthchecks to stacks that lack them.
- "No rate available (time anomaly)" / "Initializing counters" on a new container is normal for 1–2 check cycles. If it persists, check that the piggyback files refresh every minute and that node clocks agree.

### Rules (Setup → search for the rule name)
| Rule | Value | Condition |
|---|---|---|
| Host check command | Always assume host to be up | host label `role:stack` |
| Enable/disable notifications for hosts | Disable | host label `role:stack` |
| Network interface and switch port discovery | Appearance: **Use alias**; port states up + down | host label `cmk/device_type:switch` |
| Network interfaces and switch ports | Ignore speed; states 1/2/7 → OK (desktop/room ports keep graphs, never alert) | host `sw-t2600g`, explicit services **negated** = infrastructure ports |

### Switch (SNMP)
- **TP-Link T2600G-18TS v2** (JetStream), host `sw-t2600g`, SNMP **v2c**, read-only community, `viewDefault` (whole tree). Credentials are in the Checkmk host properties only.
- Verified with [`snmp-preflight.sh`](snmp-preflight.sh): sysDescr, ifTable, ifAlias, **64-bit counters** all pass.
- Port names come from switch port descriptions (ifAlias). Set them in the switch UI under *L2 Features → Port Config*.
- Parents: `sw-t2600g` has none (root). Every host cabled to it has Parents = `sw-t2600g`.
- Expected quirks: CPU reads 75–85 % on this model (raise *CPU utilization for simple devices* to 90/95 if it alerts); PCs that are off report 10 Mbit/s (Wake-on-LAN), which is why desktop ports ignore speed.
- TODO: move from the v2c community to a dedicated SNMPv3 `authPriv` user. Decide whether to retire LibreNMS (both currently poll the switch).

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

## Next steps
1. Confirm eviction-hard status (above).
2. ~~Pre-flight port check on optiplex-two~~ — done, 8081/8000 free. Optionally extend the LV on optiplex-two (commands in local file).
3. Deploy stack via Portainer to optiplex-two (Repository build method, no auth); set `CMK_PASSWORD` env var.
4. Verify: `docker logs checkmk 2>&1 | grep -iE 'created new site|version'` (expect ≥ 2.5.0p9); `docker stats --no-stream checkmk`.
5. First login: `http://<optiplex-two>:8081/cmk/` as `cmkadmin`.
6. Write Traefik dynamic route on smiddleware: `checkmk.shome` → `http://<optiplex-two>:8081`, preserve `/cmk/`, redirect `/` → `/cmk/`, Step-CA leaf cert.
7. Agent rollout script for all four hosts + register with `cmk-agent-ctl register` (port 8000, TLS).
8. Firewall: TCP 6556 (server→agents), TCP 8000 (agents→server), UDP 161 (SNMP). IoT network is HA-only — needs a narrow SRM rule or monitor via HA.
9. Kubernetes monitoring via Checkmk Kubernetes special agent + cluster collector.
10. Add `checkmk-sites` volume to Borg backup set.
