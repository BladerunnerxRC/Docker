# Checkmk Deployment — Session Handoff

> Context carried over from a claude.ai chat (2026-10-12). Read this first, then continue from "Next steps".

## Working style
- Professional, clear, concise. When asked for clarification, answer at an 11th-grade reading level.
- Direct and technical; no sugar-coating. Check work before delivering.
- Scripts: ask for diagnostics/logs before proposing fixes; iterate run → logs → fix.
- "mod and print" = modify the file in progress and print the ENTIRE file.
- Infra/config: stack-ready YAML, commented.
- Suggest continued improvements to code.

## Goal
Deploy Checkmk Community (formerly Raw) to monitor the home lab, fronted by Traefik at `https://checkmk.shome`.

## Environment (verified 2026-10-12)

| Host | IP | OS | CPU | RAM | Disk | K3s role | Checkmk role |
|---|---|---|---|---|---|---|---|
| optiplex-two | 192.168.200.14 | Ubuntu 26.04.1 LTS | i5-6500T, 4C | ~15 GiB (12 free) | NVMe 238.5G, LV only 98G (67G free) | worker | **Checkmk server (Docker)** |
| optiplex-docker | 192.168.200.98 | Ubuntu 26.04.1 LTS | Celeron N5105, 4C | 14 GiB (10 free) | NVMe, LV 232G (126G free) | **control plane** (K3S_URL https://192.168.200.98:6443) | agent only |
| optiplex-three | ? | Ubuntu 26.04.1 LTS | Celeron N5105, 4C | 3.3 GiB | eMMC 29G | worker | agent only |
| smiddleware | 192.168.200.52 | Debian 13 (trixie) | Cortex-A76 (ARM64) | 7.9 GiB | NVMe 476G | n/a | agent only — Traefik/Step-CA/AdGuard host |

- K3s v1.34.5+k3s1, MetalLB, Traefik. `kubectl` works only on optiplex-docker (workers have no kubeconfig).
- Internal domain pattern: `https://appname.shome`. Internal PKI: Step-CA "SHOME LAN CA".
- Portainer GitOps from repo `BladerunnerxRC/Docker` (Basic auth + PAT; Compose path targets subdirectory).
- Backups: Borg to Synology NAS (SMITHVAULT).
- LibreNMS/SNMP already running — decide later whether to retire it to avoid double SNMP polling.

## Decisions made
- **Server host:** optiplex-two, Docker (not K3s, not native .deb).
  - smiddleware rejected: ARM64 (Checkmk server/image is amd64 only) and it hosts critical infra.
  - optiplex-three rejected: 3.3 GiB RAM, eMMC.
  - optiplex-docker: backup option only (busiest node, weaker CPU).
- **Version:** Checkmk 2.5.x, must be **≥ 2.5.0p9** (CVE-2026-8593). Ubuntu 26.04 supported since 2.5.0p1.
- **Image:** `checkmk/check-mk-community`.

## Completed
1. Added kubelet reservations on optiplex-two in `/etc/rancher/k3s/config.yaml`:
   ```yaml
   kubelet-arg:
     - "system-reserved=cpu=1500m,memory=5Gi"   # Checkmk (4Gi cap) + Docker containers + OS
     - "kube-reserved=cpu=250m,memory=512Mi"    # K3s/kubelet itself
   ```
2. Restarted `k3s-agent`; verified from optiplex-docker:
   - Node Ready; Allocatable `cpu: 2250m`, `memory: 9961212Ki` (~9.5 GiB); `NodeAllocatableEnforced` present.

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

## Stack to deploy (not yet deployed)
Path: `checkmk/docker_compose.yml` in `BladerunnerxRC/Docker`.
```yaml
services:
  checkmk:
    # Pin to a specific patch (e.g. 2.5.0pNN, >= p9) after first pull for reproducible GitOps
    image: checkmk/check-mk-community:2.5.0-latest
    container_name: checkmk
    restart: unless-stopped
    environment:
      CMK_SITE_ID: cmk                     # URL becomes /cmk/
      CMK_PASSWORD: ${CMK_PASSWORD}        # set in Portainer stack env, not in Git
      TZ: America/New_York
    ports:
      - "8081:5000"                        # Web UI
      - "8000:8000"                        # Agent Receiver (TLS registration); agents connect directly
    volumes:
      - checkmk-sites:/omd/sites           # all site data; include in Borg backups
    tmpfs:
      - /opt/omd/sites/cmk/tmp:uid=1000,gid=1000
    ulimits:
      nofile: 1024
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 4g

volumes:
  checkmk-sites:
```
Note: `kubectl` on optiplex-two defaults to `localhost:8080`; publishing Checkmk on 8080 makes stray kubectl runs there hit Checkmk. **Decided 2026-10-12: 8081** (LAN probe showed 8000/8080/8081 free).

## Next steps
1. Confirm eviction-hard status (above).
2. Pre-flight on optiplex-two: `sudo ss -tlnp | grep -E ':(8080|8081|8000)\b'`; optionally `sudo vgs ubuntu-vg` and extend LV (`sudo lvextend -r -L +60G /dev/ubuntu-vg/ubuntu-lv`).
3. Deploy stack via Portainer to optiplex-two; set `CMK_PASSWORD`.
4. Verify: `docker logs checkmk 2>&1 | grep -iE 'created new site|version'` (expect ≥ 2.5.0p9); `docker stats --no-stream checkmk`.
5. First login: `http://192.168.200.14:8081/cmk/` as `cmkadmin`.
6. Write Traefik dynamic route on smiddleware: `checkmk.shome` → `http://192.168.200.14:8081`, preserve `/cmk/`, redirect `/` → `/cmk/`, Step-CA leaf cert.
7. Agent rollout script for all four hosts + register with `cmk-agent-ctl register` (port 8000, TLS).
8. Firewall: TCP 6556 (server→agents), TCP 8000 (agents→server), UDP 161 (SNMP). IoT `10.` network is HA-only — needs a narrow SRM rule or monitor via HA.
9. Kubernetes monitoring via Checkmk Kubernetes special agent + cluster collector.
10. Add `checkmk-sites` volume to Borg backup set.
