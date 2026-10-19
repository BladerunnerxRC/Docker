# Checkmk Deployment — Session Handoff

> Context carried over from a claude.ai chat (2026-10-12). Read this first, then continue from "Next steps".
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
- LibreNMS decommissioned (confirmed 2026-10-17). Checkmk is now the only SNMP poller; network devices must be re-created in Checkmk.

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

## Next steps
1. Confirm eviction-hard status (above).
2. ~~Pre-flight port check on optiplex-two~~ — done, 8081/8000 free. Optionally extend the LV on optiplex-two (commands in local file).
3. Deploy stack via Portainer to optiplex-two (Repository build method, no auth); set `CMK_PASSWORD` env var.
4. Verify: `docker logs checkmk 2>&1 | grep -iE 'created new site|version'` (expect ≥ 2.5.0p9); `docker stats --no-stream checkmk`.
5. First login: `http://<optiplex-two>:8081/cmk/` as `cmkadmin`.
6. Write Traefik dynamic route on smiddleware: `checkmk.shome` → `http://<optiplex-two>:8081`, preserve `/cmk/`, redirect `/` → `/cmk/`, Step-CA leaf cert.
7. Agent rollout script for all four hosts + register with `cmk-agent-ctl register` (port 8000, TLS).
8. Firewall: TCP 6556 (server→agents), TCP 8000 (agents→server), UDP 161 (SNMP). IoT network is HA-only — needs a narrow SRM rule or monitor via HA.
9. Synology NAS onboarding (SNMP only — no supported Checkmk agent for DSM). Hosts/IPs in local file.
   - DSM: Control Panel → Terminal & SNMP → SNMP, enable **v2c** (Synology MIB guide: v2c needed for the full `.1.3.6.1.4.1.6574` tree). Checkmk host: SNMP v2c, bulkwalk on.
   - DSM sends **no SNMP traps** — polling only; check interval = alert latency.
   - After discovery, list built-in coverage: `docker exec -u cmk checkmk bash -lc "cmk -L | grep -i synology"` (expect system/power status, fans, disk status/temp, RAID, info, update; volume/CPU/mem/IO via HOST-RESOURCES + UCD).
   - **Decision 2026-10-18: no custom drive-health plugin.** DSM's own notifications (email/push, working on all three NASes) already alert on drive health; Checkmk uses built-in checks only. Reasons: the plugin's only unique value was earlier warning from raw SMART counters, and SNMP gives no drive serials, so SMART rows can't be reliably matched to bays (the SMART table is not in bay order: on the DS920+, `/dev/sata1` = bay 3).
   - SNMP probe 2026-10-18: all three NASes run DSM 7.4 and return the full Disk/RAID/SMART tables (incl. diskHealthStatus `.2.1.1.13`). Community fixed to match on all three.
   - UPS: APC Back-UPS NS 675M1 on USB to the DS920+; the other NASes are DSM network-UPS clients (no UPS OIDs of their own). The Synology UPS MIB (`.4`) answers on the DS920+ only; RFC1628 UPS-MIB is absent. At discovery, check whether any built-in service picks it up. If none does, a small custom SNMP check is a candidate (alert on on-battery, charge <50%, runtime <5 min, battery age >4 y; graph runtime). Battery is original (mfr 2020-10-30) and was never self-tested as of 2026-10-18; replacement recommended.
   - Router (SRM) gets only the Port MIB (`.109`) beyond standard MIBs — nothing new there.
10. Kubernetes monitoring via Checkmk Kubernetes special agent + cluster collector.
11. Add `checkmk-sites` volume to Borg backup set.
