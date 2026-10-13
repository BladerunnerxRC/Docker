# Checkmk Deployment — Session Handoff

> Last updated 2026-10-12 (end of first deployment session). Read this first, then continue from "Next steps".
> Host addresses, hardware specs, and other environment details live in the gitignored
> `HANDOFF-POC.local.md` next to this file (local only — not in the public repo).

## Working style
- Professional, clear, concise. When asked for clarification, answer at an 11th-grade reading level.
- Direct and technical; no sugar-coating. Check work before delivering.
- Scripts: ask for diagnostics/logs before proposing fixes; iterate run → logs → fix.
- "mod and print" = modify the file in progress and print the ENTIRE file.
- Infra/config: stack-ready YAML, commented.
- Suggest continued improvements to code.
- Changes to `main` go through a PR (branch protection); don't push to `main` directly.

## Goal
Deploy Checkmk Community (formerly Raw) to monitor the home lab, fronted by Traefik at `https://checkmk.shome`.

## Environment
See `HANDOFF-POC.local.md` for IPs, OS, CPU/RAM/disk per host.

| Host | K3s role | Checkmk role |
|---|---|---|
| optiplex-two | worker | **Checkmk server (Docker)** + agent |
| optiplex-docker | **control plane** | agent; also runs Borg UI |
| optiplex-three | worker (currently cordoned — see open items) | agent |
| smiddleware | n/a | agent — Traefik/Step-CA/AdGuard host (ARM64) |
| homeassistant | n/a | SNMP + HTTP (Home Assistant OS — no agent possible) |

- K3s with MetalLB and Traefik. `kubectl` works only on optiplex-docker (workers have no kubeconfig).
- Internal domain pattern: `https://appname.shome`. Internal PKI: Step-CA.
- Portainer (Business Edition 2.45) GitOps from public repo `BladerunnerxRC/Docker`, ref `refs/heads/main`, Compose path `checkmk/docker_compose.yml`, stack name `checkmk`. Public repo — no Git authentication. Secrets go in Portainer stack env vars only.
- Backups: Borg UI (on optiplex-docker) to Synology NAS.
- LibreNMS/SNMP already running — decide later whether to retire it to avoid double SNMP polling.

## Decisions made
- **Server host:** optiplex-two, Docker (not K3s, not native .deb).
  - smiddleware rejected: ARM64 (Checkmk server/image is amd64 only) and it hosts critical infra.
  - optiplex-three rejected: too little RAM, eMMC storage.
  - optiplex-docker: backup option only (busiest node, weaker CPU).
- **Version:** Checkmk 2.5.x, must be **≥ 2.5.0p9** (CVE-2026-8593). Running 2.5.0p15 agents.
- **Image:** `checkmk/check-mk-community:2.5.0-latest` (pin a patch later for reproducible GitOps).
- **Web UI port:** host `8081` → container `5000`. Not 8080: `kubectl` on optiplex-two defaults to `localhost:8080`.
- **TZ:** `America/Detroit` (Eastern, same DST as New_York). See gotcha 1.
- **Docker plugin naming:** `container_id: combined` on every Docker host → piggyback hosts named `<host>_<container>`. Names like `portracker` / `portainer` exist on several hosts and would collide otherwise.
- **SNMP for Home Assistant:** HA OS is read-only and add-ons are containers, so no agent; use the installed SNMPD add-on + an HTTP check on :8123.

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
   `smart_posix` (needs smartctl 7.x) goes in `/usr/lib/check_mk_agent/plugins/300/` (async, 5 min). Installed on optiplex-docker; smiddleware/optiplex-two status unverified.
4. **Container hosts:** folder `Docker containers` (IP family **No IP**, agent **No API integrations, no Checkmk agent**, piggyback **Always use and expect**). 8 hosts:
   `optiplex-two_checkmk`, `optiplex-two_portainer-2--ee`, `optiplex-two_mariadb-kodi`, `optiplex-docker_borg-backup`, `optiplex-docker_manyfold-postgres-manyfoldsvr-1`, `optiplex-docker_portainer-ee`, `smiddleware_traefik`, `smiddleware_adguardhome`.
   Host state follows the `Docker container status` service via Checkmk's built-in rule (label `cmk/docker_object:container`). A duplicate rule was also created in the folder — harmless, can be deleted.
5. **Kubelet reservations + memory eviction on all three nodes** (`/etc/rancher/k3s/config.yaml`, `kubelet-arg`; every node also has `eviction-hard=memory.available<256Mi,nodefs.available<5%,imagefs.available<5%`). Verified allocatable:

   | Node | system-reserved | kube-reserved | Allocatable mem | Allocatable CPU | Restart unit |
   |---|---|---|---|---|---|
   | optiplex-two | cpu=1500m, mem=5Gi | cpu=250m, mem=512Mi | 9699068Ki | 2250m | `k3s-agent` |
   | optiplex-docker | cpu=1000m, mem=4Gi | cpu=500m, mem=1Gi | 10157196Ki | 2500m | `k3s` |
   | optiplex-three | cpu=250m, mem=512Mi | cpu=250m, mem=256Mi | 2432200Ki | 3500m | `k3s-agent` |

   These budget scheduling only (K3s enforces `pods`), so Docker containers outside K3s are not capped.
6. **PRs merged:** #21 (host details → gitignored local file), #23 (TZ fix).

## Gotchas learned
1. **TZ with `_` crash-loops the container.** Checkmk 2.5.0 `docker-entrypoint.sh` runs `sed -i -E "s_^TZ=.*_TZ=\"${TZ}\"_"` on every start after the first; the `_` in `America/New_York` breaks the expression (`char 26: unknown option to 's'`), `set -e` exits, `restart: unless-stopped` loops. First boot works (it appends instead), so it only shows on redeploy. Upstream bug — could be reported.
2. **`CMK_PASSWORD` is read once**, at site creation. Changing it later does nothing; use `docker exec -it checkmk su - cmk -c "cmk-passwd cmkadmin"`.
3. **ARM hosts:** the agent `.deb` installs in legacy mode (no `cmk-agent-ctl`). **Never click "Provide TLS connection"** on them — it pre-registers the host on the server, after which plaintext data is refused (`A TLS connection is registered on the monitoring server but the agent is not providing it`). Fix: host properties → **Host → Remove TLS registration**.
4. **Piggyback-only hosts** must use **No API integrations, no Checkmk agent**. "Configured API integrations, no Checkmk agent" raises `host configuration requires a datasource but none configured`.
5. **Server monitoring its own host:** traffic to the host's agent comes from the Checkmk container's Docker bridge subnet, not the LAN IP — firewall rules on optiplex-two must allow that subnet.
6. **Ubuntu 26.04 uses Rust coreutils/sudo-rs**: errors look like `(os error 2)`; `tee` cannot create a missing directory (`/etc/check_mk` only exists after the agent package is installed).
7. **Heredocs pasted into a terminal** often arrive incomplete (shell sits at `>`). Prefer single-line `printf ... | sudo tee`.
8. `mk_docker.py ... | head` ends in `BrokenPipeError` — harmless, caused by `head`.

## Open items
- **Activate pending changes** in Checkmk if the Changes badge is non-zero (folder agent-setting fix).
- **Home Assistant:** host `homeassistant` exists. Still needed: SNMP credentials rule (community from the SNMPD add-on config — keep out of Git/chat), HTTP rule for `:8123`, then discovery.
- **optiplex-three is cordoned** (`Ready,SchedulingDisabled`) — predates this session. Confirm intentional, else `kubectl uncordon optiplex-three`.
- **optiplex-docker:** confirm `smart_posix` moved to `plugins/300/` and `docker.cfg` = `combined`; run discovery.
- **Statping decommission:** repo side in PR #24. Host side: on optiplex-two, `docker volume ls -f dangling=true` (2 orphaned volumes expected), archive if wanted, delete the Portainer stack if listed, remove volumes and `/data/compose/14`.
- **Backups:**
  - PR #22 (draft): `omd backup cmk -` block in the optiplex-two Borg prep script. Test first on optiplex-two: `docker exec checkmk omd backup cmk - > /tmp/cmk-test.tgz`, then `file`/`tar -tzf`/`ls -lh`.
  - PR #24: statping removal + KodiDB Borg UI wrapper host fix. Also check the **live** Borg UI `kodidb-prep-dbdump` SSH target and that `/var/backups/borg-kodidb/latest` is fresh.
  - #22 and #24 touch the same lines — whichever merges second needs a rebase.
  - After merging, install the prep script on optiplex-two by hand (no deploy script for that host).
  - **optiplex-docker has no Borg prep script** — Manyfold Postgres, Komga, and Portainer EE there appear unprotected. Run the survey on optiplex-docker to generate one (separate PR).
  - After the first Borg run with the Checkmk block: `sudo du -sh /var/backups/borg-apps/*` on optiplex-two (98G root LV).

## Stack
Source of truth: [`docker_compose.yml`](docker_compose.yml) in this folder.

## Next steps
1. Home Assistant SNMP + HTTP (open items above).
2. Traefik dynamic route on smiddleware: `checkmk.shome` → optiplex-two:8081, preserve `/cmk/`, redirect `/` → `/cmk/`, Step-CA leaf cert.
3. External watchdog for the Checkmk server itself (e.g. Home Assistant HTTP sensor on the web UI) — if optiplex-two dies, nothing alerts.
4. Firewall review: TCP 6556 (server→agents), TCP 8000 (agents→server), UDP 161 (SNMP). IoT network is HA-only — narrow SRM rule or monitor via HA.
5. Kubernetes monitoring: Checkmk Kubernetes special agent + cluster collector (from optiplex-docker, the control plane).
6. Optional: SSH datasource for smiddleware to encrypt its agent traffic; "Checkmk Agent installation auditing" rule to silence the TLS WARN on smiddleware.
7. Optional: notifications (none configured yet), host tags/folders, parents (router/switch).
8. Pin the image to a specific 2.5.0p patch.
