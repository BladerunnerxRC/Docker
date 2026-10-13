# Checkmk Deployment — Session Handoff

> Last updated 2026-10-13 (alert cleanup session). Read this first, then continue from "Next steps".
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
- LibreNMS (K3s) was **removed 2026-10-13; Checkmk replaces it** — see "LibreNMS — removed" below.

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

## Completed (2026-10-13) — alert cleanup
1. **optiplex-docker stale NFS mounts removed** (`/mnt/docker_grafana_data`, `/mnt/docker_postgres_main_data`, `/mnt/docker_postgres_main_dumps` from the NAS). They were CRIT `NFS mount … State: Hanging`. No container used them. The fstab lines were still present with `x-systemd.automount`: lazily unmounted, automount units stopped, fstab lines commented out (backup `/etc/fstab.bak.2026-10-13`), `daemon-reload` + `reset-failed`, empty mountpoint dirs deleted. See gotcha 10.
2. **smiddleware memory cgroup enabled** (Pi 5). Container `Memory` services were UNKN ("Reported total memory is 0 B"). Appended `cgroup_enable=memory cgroup_memory=1` to `/boot/firmware/cmdline.txt` (backup `cmdline.txt.bak.2026-10-13`), rebooted. Verified: `memory` in `/sys/fs/cgroup/cgroup.controllers`; `docker stats` shows a 7.87 GiB limit. See gotcha 9.
3. **smiddleware `/mnt/backups` (Borg NFS share) now mounts at boot.** It had `x-systemd.automount,x-systemd.idle-timeout=600`, so it only mounted on first access and dropped after 10 idle minutes, which makes the Checkmk NFS service come and go. Removed both options (kept `_netdev,nofail`; backup `/etc/fstab.bak.2026-10-13`), stopped the automount unit, `daemon-reload`, remounted. Verified single `nfs4` mount, no `autofs`.
4. **NFS usage levels:** rule in Main folder, no conditions, ruleset "Network file system - overall status and usage (e.g. NFS)" (Service Monitoring Rules, not Enforced Services): warn 85% / crit 90%. Every NFS mount points at NAS volume1 (82–83% used on 2026-10-13), so all of them WARN together. Once smithvault is on SNMP, monitor volume1 there and drop the usage levels from this rule.
5. **optiplex-docker `/mnt` strays removed:** `borg_optiplex-threels` (mkdir typo) and `SYSBAK_borgrepos_optiplex-two` (pre-rename mountpoint) — empty, unmounted, not in fstab, not used by `borg-backup`. Verified all four Borg repo bind mounts (`/mnt/borg_optiplex-{two,three}`, `/mnt/borg_smiddleware`, `/mnt/backups/borgrepo`) are NFS-backed — no Borg data lands on local disk.
   Then removed `x-systemd.automount,x-systemd.idle-timeout=600` from those four fstab lines (backup `/etc/fstab.bak.2026-10-13-borg`) for consistency with smiddleware: stopped `borg-backup`, umount + stop each `.automount` (`systemd-escape -p --suffix=automount`), `daemon-reload`, remounted, started `borg-backup`; container sees the repos (`#recycle` = Synology share). **Left alone:** `Software_Backup` (fstab line 29) and the Manyfold bind mount `/srv/manyfold/library_nas` (line 30) — no idle timeout, and the bind depends on that automount.
6. **optiplex-three `systemd-networkd-wait-online` fixed.** `enp1s0` (no cable) was in netplan, so every boot timed out after 2 min and the unit failed. `sudo netplan set ethernets.enp1s0.optional=true` (writes `70-netplan-set.yaml`, safe from cloud-init), `netplan generate`, `networkctl reload` (no interface bounce), restarted the unit, `reset-failed`. Verified `active (exited)`. `enp1s0` still shows `configuring` in `networkctl` — expected with no carrier; it's just no longer required for online. `enp2s0` is the live NIC. Real test is the next reboot.
7. **optiplex-two `logrotate.service` fixed** (Systemd Service Summary CRIT). Failing nightly since at least Oct 7: `/etc/logrotate.d/cloud-init` (pkg `cloud-init`) and `cloud-init-base` (pkg `cloud-init-base`) are identical and both rotate `/var/log/cloud-init.log` → "duplicate log entry". Moved the old one to `/root/logrotate.d-cloud-init.old` (outside `logrotate.d`, which would still read a `.bak`); manual run clean. dpkg won't restore an admin-deleted conffile. Same fix applied proactively on optiplex-docker (identical files, not yet failed). optiplex-three only has `cloud-init-base` — clean. See gotcha 12.
8. **Diagnosed Check_MK Discovery WARN** on `optiplex-docker_portainer-ee`: 5 unmonitored services + 5 new host labels never accepted (the container hosts were created but not fully discovered). Fix is in open items. See gotcha 11.

## Gotchas learned
1. **TZ with `_` crash-loops the container.** Checkmk 2.5.0 `docker-entrypoint.sh` runs `sed -i -E "s_^TZ=.*_TZ=\"${TZ}\"_"` on every start after the first; the `_` in `America/New_York` breaks the expression (`char 26: unknown option to 's'`), `set -e` exits, `restart: unless-stopped` loops. First boot works (it appends instead), so it only shows on redeploy. Upstream bug — could be reported.
2. **`CMK_PASSWORD` is read once**, at site creation. Changing it later does nothing; use `docker exec -it checkmk su - cmk -c "cmk-passwd cmkadmin"`.
3. **ARM hosts:** the agent `.deb` installs in legacy mode (no `cmk-agent-ctl`). **Never click "Provide TLS connection"** on them — it pre-registers the host on the server, after which plaintext data is refused (`A TLS connection is registered on the monitoring server but the agent is not providing it`). Fix: host properties → **Host → Remove TLS registration**.
4. **Piggyback-only hosts** must use **No API integrations, no Checkmk agent**. "Configured API integrations, no Checkmk agent" raises `host configuration requires a datasource but none configured`.
5. **Server monitoring its own host:** traffic to the host's agent comes from the Checkmk container's Docker bridge subnet, not the LAN IP — firewall rules on optiplex-two must allow that subnet.
6. **Ubuntu 26.04 uses Rust coreutils/sudo-rs**: errors look like `(os error 2)`; `tee` cannot create a missing directory (`/etc/check_mk` only exists after the agent package is installed).
7. **Heredocs pasted into a terminal** often arrive incomplete (shell sits at `>`). Prefer single-line `printf ... | sudo tee`.
8. `mk_docker.py ... | head` ends in `BrokenPipeError` — harmless, caused by `head`.
9. **Pi 5 container Memory UNKN** ("Reported total memory is 0 B"): Pi firmware injects `cgroup_disable=memory`, so Docker reports a 0 B limit. Fixed on smiddleware by appending `cgroup_enable=memory cgroup_memory=1` to the single line in `/boot/firmware/cmdline.txt` (later arg wins) and rebooting. Redo after any reimage.
10. **Removing an fstab line doesn't unmount.** With `x-systemd.automount`, systemd re-mounts on any access. Comment out the line, `systemctl stop <unit>.automount`, `daemon-reload`, `reset-failed`. The Checkmk agent reads `/proc/mounts`, not fstab; stale NFS mounts show as `NFS mount … State: Hanging` (CRIT).
11. **Check_MK Discovery WARN on container hosts** = unaccepted services/labels. Run bulk discovery on the `Docker containers` folder; the `cmk/docker_object:container` label must be accepted for the host-state rule to apply.
12. **Ubuntu `cloud-init` + `cloud-init-base` logrotate overlap:** both packages ship the same rotation for `/var/log/cloud-init.log`, so `logrotate.service` fails nightly ("duplicate log entry") and Checkmk's Systemd Service Summary goes CRIT. Fix: `sudo mv /etc/logrotate.d/cloud-init /root/logrotate.d-cloud-init.old && sudo systemctl start logrotate`.

## Open items
- **LibreNMS leftovers outside K3s:** remove the Dashy tile and any AdGuard rewrite.
- **Activate pending changes** in Checkmk if the Changes badge is non-zero (folder agent-setting fix).
- **Discovery cleanup (from 2026-10-13):**
  - optiplex-docker: run service discovery, remove the 3 vanished `NFS mount` services, activate.
  - smiddleware: run service discovery to add `NFS mount /mnt/backups`, activate.
  - `Docker containers` folder: bulk discovery, mode "Add unmonitored services and new host labels", activate. Clears the Check_MK Discovery WARNs and applies the `cmk/docker_object:container` label the host-state rule needs.
  - Add a **Periodic service discovery** rule on that folder that automatically adds unmonitored services and new host labels (optionally removes vanished ones) so container churn doesn't raise WARNs.
  - Confirm `Memory` is OK on `smiddleware_adguardhome` and `smiddleware_traefik`; if still UNKN, rediscover both.
- **optiplex-docker:** after the next clean reboot, confirm no NFS mounts return (`findmnt -t nfs,nfs4`), then delete `/etc/fstab.bak.2026-10-13`.
- **Home Assistant:** host `homeassistant` exists. Still needed: SNMP credentials rule (community from the SNMPD add-on config — keep out of Git/chat), HTTP rule for `:8123`, then discovery.
- **optiplex-three `Systemd Service Summary` CRIT (1 failed unit left) — deferred, acknowledge in Checkmk:**
  - `smartmontools`: smartd exits "No devices to monitor" because the only disk is eMMC (`mmcblk0`, no SMART). **Plan: install the new NVMe and clone the eMMC to it**; smartd should then start on its own (`sudo systemctl restart smartmontools`, then `reset-failed`). If the NVMe plan falls through: `sudo systemctl disable --now smartmontools && sudo systemctl reset-failed smartmontools`. After the NVMe goes in, also install `smart_posix` there. May also pull the unused second NIC (`enp1s0` — an M.2 A+E-key Wi-Fi-slot-to-Ethernet adapter, PCIe x1) at the same time for another OptiPlex; confirm first which slot the NVMe uses (needs M-key; if the Wi-Fi slot is the only free one, the NIC adapter must come out and the NVMe would need an E-key adapter at x1): afterwards `sudo netplan set ethernets.enp1s0=null && sudo netplan generate && sudo networkctl reload`. On the receiving host: needs a free M.2 A/E-key Wi-Fi slot (often occupied by the Wi-Fi card), add it to netplan (`optional: true` if unplugged), and if it's a K3s node confirm flannel stays on the existing interface.
  - ~~`systemd-networkd-wait-online`~~ — fixed 2026-10-13, see Completed.
- **optiplex-three is cordoned** (`Ready,SchedulingDisabled`) — predates this session. Confirm intentional, else `kubectl uncordon optiplex-three`.
- **optiplex-docker:** confirm `smart_posix` moved to `plugins/300/` and `docker.cfg` = `combined`; run discovery.
- **Statping decommission:** repo side in PR #24. Host side: on optiplex-two, `docker volume ls -f dangling=true` (2 orphaned volumes expected), archive if wanted, delete the Portainer stack if listed, remove volumes and `/data/compose/14`.
- **Backups:**
  - PR #22 (draft): `omd backup cmk -` block in the optiplex-two Borg prep script. **Tested OK 2026-10-13:** manual `docker exec checkmk omd backup cmk - | sudo tee /var/backups/checkmk/cmk-<date>.omd.tar.gz` → 15 MB gzip (~545 MB raw), 3,257 entries, includes `etc/check_mk/conf.d/wato/`. Online — no downtime. Ready to mark ready-for-review and merge. Manual copy `cmk-2026-10-13-1453.omd.tar.gz` (sha256 `85aa243d…a55509`): on optiplex-two in `/var/backups/checkmk/`, and on the NAS at optiplex-docker `/mnt/backups/checkmk-manual/` (checksums match; optiplex-two has no NAS mount, so it went via `scp`). Restore is `omd restore` inside the container (site must be stopped).
  - PR #24: statping removal + KodiDB Borg UI wrapper host fix. Also check the **live** Borg UI `kodidb-prep-dbdump` SSH target and that `/var/backups/borg-kodidb/latest` is fresh.
  - #22 and #24 touch the same lines — whichever merges second needs a rebase.
  - After merging, install the prep script on optiplex-two by hand (no deploy script for that host).
  - **optiplex-docker has no Borg prep script** — Manyfold Postgres, Komga, and Portainer EE there appear unprotected. Run the survey on optiplex-docker to generate one (separate PR).
  - After the first Borg run with the Checkmk block: `sudo du -sh /var/backups/borg-apps/*` on optiplex-two (98G root LV).

## Stack
Source of truth: [`docker_compose.yml`](docker_compose.yml) in this folder.

## LibreNMS — removed 2026-10-13
Removed from K3s early (plan was a 2-week hold; skipped since LibreNMS had 22 alert rules but **no alert transports** — it notified no one). **Step A was not done first: the network devices below are currently unmonitored** — see Next steps.

**Final backup** on the NAS, via optiplex-docker's `/mnt/backups/librenms-final/` (share `SYSBAK_borgrepos_opti-docker`):
- `librenms-db-2026-10-13.sql.gz` — full `mysqldump` (Bitnami MySQL, root password read from `$MYSQL_ROOT_PASSWORD_FILE` inside the pod), verified `-- Dump completed`.
- `librenms-retire/` — `librenms-values.yaml` (may contain secrets — never commit) and `devices-and-alerts.txt` (device list for Step A). Original still in `~/librenms-retire/` on optiplex-docker.
- `opt-k3-librenms-tooling.tgz` — the old install scripts/manifests/values from `/opt/k3/librenms`.
- RRD graph history was not kept.

**What was removed:** `helm uninstall librenms` (chart 7.2.0, app 26.1.1, ns `default`); local-path PVCs (MySQL, Redis, rrdcached + journal) and their data; manual Retain PVs `librenms-app-pv`/`librenms-db-pv` and PVCs (never mounted by any pod); `/opt/k3/librenms` (hostPath dirs were empty; not present on the other nodes). **Not part of the Helm release** and deleted by hand: `svc/librenms-frontend` (LoadBalancer — frees its MetalLB IP) and `secret/librenms-env`. No cron/timer referenced the old scripts.

**Still to do outside K3s:** remove the LibreNMS tile from Dashy and any AdGuard rewrite for it.

**Step A — add the former LibreNMS devices to Checkmk** (device IPs in the local file):

| Folder | Settings | Hosts |
|---|---|---|
| `Network devices` | IPv4 only; agent **No API integrations, no Checkmk agent**; **SNMP v2 or v3**; one SNMP credentials rule on the folder (same community LibreNMS used — in the archived `librenms-values.yaml` or the device configs) | router (Synology RT6600ax/SRM), smithvault (DS920+), smithmountain (DS220+), smithvids (DS216j), t2600g-18ts (TP-Link JetStream switch), dell-h625cdw (printer); also move `homeassistant` here for SNMP |
| `Ping only` | agent **No API integrations, no Checkmk agent**; **No SNMP** | um-switch-loft, ISP upstream gateway, one unidentified device (see local file) |

Then bulk discovery → activate. The admin workstation (Windows) was also in LibreNMS — optional. Adding smithvault also gives one volume1 capacity service (see Completed 2026-10-13 item 4).

## Next steps
0. **Discovery cleanup** (open items) — quick, and it clears the remaining WARN/UNKN noise before adding more hosts.
1. **LibreNMS Step A — priority:** LibreNMS is gone, so the router, NAS units, switch and printer have no monitoring until they're added to Checkmk (see "LibreNMS — removed").
2. Home Assistant SNMP + HTTP (open items above).
3. Traefik dynamic route on smiddleware: `checkmk.shome` → optiplex-two:8081, preserve `/cmk/`, redirect `/` → `/cmk/`, Step-CA leaf cert.
4. External watchdog for the Checkmk server itself (e.g. Home Assistant HTTP sensor on the web UI) — if optiplex-two dies, nothing alerts.
5. Firewall review: TCP 6556 (server→agents), TCP 8000 (agents→server), UDP 161 (SNMP). IoT network is HA-only — narrow SRM rule or monitor via HA.
6. Kubernetes monitoring: Checkmk Kubernetes special agent + cluster collector (from optiplex-docker, the control plane).
7. Optional: SSH datasource for smiddleware to encrypt its agent traffic; "Checkmk Agent installation auditing" rule to silence the TLS WARN on smiddleware.
8. Optional: notifications (none configured yet), host tags/folders, parents (router/switch).
9. Pin the image to a specific 2.5.0p patch.
10. Optional: move optiplex-three's M.2 Wi-Fi-slot Ethernet adapter (see open items) to **optiplex-two** as a dedicated NAS/storage link, so Borg backups (and the Checkmk site backup) stay off its main interface. All OptiPlex boards are near-identical (smiddleware is the Pi), so the slot should fit. Check the slot is free first: `lspci -nn | grep -i -E 'network|ethernet|wireless'` (no Wi-Fi controller listed = likely empty; a BIOS-disabled card also hides). Then: static IP on the storage subnet in netplan (`optional: true` until cabled), point the NFS/Borg target at the NAS's IP on that link, and confirm K3s/flannel stays on the existing interface.
