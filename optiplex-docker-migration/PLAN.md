# optiplex-docker → OptiPlex 3000 Micro — Migration Plan

> Drafted 2026-11-13. Status: **planned, not started.** Nothing below has been run yet.
> Tick the boxes as you go and record anything surprising under "Log".

## Goal
Move everything that runs on optiplex-docker (Celeron N5105, 4C/4T, 14 GiB) onto a
Dell OptiPlex 3000 Micro (i5-12500T, 6C/12T, 16 GB DDR4, 512 GB SSD) with as little
change to the rest of the lab as possible.

## Governing rule: keep the identity
The new box takes over hostname **`optiplex-docker`** and IP **`192.168.200.98`**. That address
and name are wired into:

- ~11 Traefik backends in [`traefik/dynamic/30-services.yml`](../traefik/dynamic/30-services.yml) and Dashy links
- every K3s agent's `K3S_URL` (`https://192.168.200.98:6443`) and the K3s server certificate SANs
- Checkmk piggyback host names (`optiplex-docker_<container>`)
- Synology NFS exports (likely IP-restricted), Portainer endpoints, Tailscale subnet router / exit node

Keeping both means none of those need editing.

## Method: whole-disk clone, not a rebuild
optiplex-docker carries the most hand-built state in the lab and has no full inventory or
Borg prep script, so a rebuild would mean rediscovering everything. A clone carries over
unchanged:

- K3s server: CA/TLS, token, datastore, `/etc/rancher/k3s/config.yaml`, `/etc/rancher/node/password`
- Portainer EE server data (stacks deployed from the web editor live there, not in Git)
- Borg UI + Redis, its SSH keys / `known_hosts`, `/srv/borg-restore`
- `/etc/fstab` NFS mounts (Borg repos with rslave propagation, `Software_Backup`, Manyfold `/srv/manyfold/library_nas`)
- Tailscale node identity, `tailscale-lan-forward` unit and its iptables setup
- Checkmk agent TLS registration, `smart_posix` plugin, `/etc/check_mk/docker.cfg`
- Docker data (Grafana, Komga, Manyfold + Postgres, NocoDB, Dockhand, Portracker, whoami), Webmin, cron, 8 GB `/swapfile`, SSH host keys

A fresh install is the fallback only if Phase 0 says the clone can't boot.

---

## Phase 0 — Pre-checks on optiplex-docker (decide clone vs rebuild)

- [ ] Boot mode — must print `UEFI` for the clone to boot on the 12th-gen OptiPlex:
  ```bash
  [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS
  ```
- [ ] Network config — note static vs DHCP, and whether netplan matches by NIC name or MAC:
  ```bash
  cat /etc/netplan/*.yaml; ip -br link
  ```
- [ ] K3s datastore — `state.db` = SQLite, `etcd/` = embedded etcd (matters for the fallback only):
  ```bash
  sudo ls /var/lib/rancher/k3s/server/db/
  ```
- [ ] Disk usage, to size the image: `sudo vgs; df -h /`

If boot mode is `BIOS`: stop and write a rebuild plan instead.

## Phase 1 — Prepare the new box (while Windows is still on it)

- [ ] BIOS/firmware update via Dell Command Update. The Windows key is embedded in firmware, so Windows can be reinstalled later.
- [ ] BIOS: storage mode **AHCI/NVMe** (not "RAID On" — Linux won't see the SSD).
- [ ] BIOS: AC recovery **Power On**; Wake-on-LAN enabled.
- [ ] Memory test (Ubuntu ISO → memtest86+) before trusting it with the control plane.
- [ ] Note the new NIC's MAC address.
- [ ] Optional: add a second matching DDR4 SODIMM if it shipped with one 16 GB stick (dual channel, 32 GB).

## Phase 2 — Safety net (do this even if the migration slips)

- [ ] Run the Borg survey on optiplex-docker → inventory + generated prep script (see [`borg-backup/README.md`](../borg-backup/README.md)).
- [ ] Deploy the prep script and take a real Borg backup. Closes the borg-backup open item "optiplex-docker had no Borg prep script".
- [ ] Separate K3s datastore copy:
  - SQLite: `sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup '/root/k3s-state-$(date +%F).db'"`
  - etcd: `sudo k3s etcd-snapshot save`
  - plus `/var/lib/rancher/k3s/server/token` and `/var/lib/rancher/k3s/server/tls/`

## Phase 3 — Cutover (expect ~1–1.5 h downtime)

- [ ] Checkmk: schedule downtime for optiplex-docker and its `optiplex-docker_*` / `stack-*` hosts.
- [ ] Shut down optiplex-docker. While it is off: pods already on the workers keep running but nothing reschedules; Borg UI, Portainer EE, Tailscale exit node and the .98 Traefik backends are down.
- [ ] Copy the disk, one of:
  - **Clonezilla** `savedisk` to the Synology, then `restoredisk` on the new box (copies used blocks only).
  - Old NVMe in an M.2 USB enclosure, clone directly onto the new box's SSD.
- [ ] **Never power both boxes on at once** — same IP, Tailscale node key and K3s node identity.

## Phase 4 — First boot on the new box

- [ ] If it won't boot: Dell BIOS → Boot Sequence → Add Boot Option → `\EFI\ubuntu\shimx64.efi`.
- [ ] Network (most likely breakage): fix the netplan interface name / MAC match, `sudo netplan apply`. If .98 is a DHCP reservation, move it to the new MAC in SRM.
- [ ] Grow the disk to 512 GB:
  ```bash
  sudo growpart /dev/nvme0n1 3      # check the partition number with lsblk first
  sudo pvresize /dev/nvme0n1p3
  sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
  ```
- [ ] Re-tune kubelet reservations in `/etc/rancher/k3s/config.yaml` for 12 threads (Docker workloads aren't counted by K3s; consider `system-reserved cpu=2000m`), then `sudo systemctl restart k3s`.
- [ ] Don't install `iptables-persistent` (Checkmk HANDOFF gotcha 17).

## Phase 5 — Verify

- [ ] K3s: `kubectl get nodes -o wide` → all three Ready; `curl -s http://192.168.200.240` answers (MetalLB / k3s Traefik).
- [ ] Docker: `docker ps` shows every container up; every `*.shome` route via Traefik loads.
- [ ] Portainer: both servers show their endpoints as up.
- [ ] Borg: `findmnt -t nfs,nfs4` shows the `/mnt/borg_*` mounts; one Borg UI job completes. Optionally do the pending restore drill into `/restore`.
- [ ] Tailscale: `tailscale status`; exit node and subnet route work from a phone; FORWARD `100\.64` count = 2, NAT MASQUERADE count = 1 (commands in [`checkmk/HANDOFF-POC.md`](../checkmk/HANDOFF-POC.md)).
- [ ] Checkmk: `sudo cmk-agent-ctl status` registered; service discovery on optiplex-docker — remove old NIC/disk/CPU services, accept new; HW/SW inventory shows the new hardware.
- [ ] End the Checkmk downtime.

## Phase 6 — Rollback window, then reuse

- [ ] Keep the old box **powered off and untouched for ~1 week.** Rollback = power off new, power on old.
- [ ] Then wipe its disk before it touches the network again. **Do not run `tailscale logout` on it** — that revokes the node key the new box uses.
- [ ] Optional reuse as a K3s worker (N5105, 14 GiB): new hostname, new IP, fresh `k3s-agent` join, Checkmk agent registration, Borg prep script.

## Phase 7 — Docs to update afterwards

- [ ] Host table in `checkmk/HANDOFF-POC.local.md` (CPU, RAM, disk for optiplex-docker).
- [ ] [`checkmk/HANDOFF-POC.md`](../checkmk/HANDOFF-POC.md): "busiest node, weaker CPU" note and the kubelet reservation table.
- [ ] [`borg-backup/HANDOFF.md`](../borg-backup/HANDOFF.md): optiplex-docker now has a prep script.
- [ ] Mark this plan done.

## Log
_(record dates, surprises, and deviations here)_
