# Docker

![Docker Compose](https://img.shields.io/badge/deploy-docker%20compose-2496ED?logo=docker&logoColor=white)
![Portainer](https://img.shields.io/badge/managed%20by-portainer-13BEF9?logo=portainer&logoColor=white)
![Traefik](https://img.shields.io/badge/proxy-traefik-24A1C1?logo=traefikproxy&logoColor=white)
![Backups](https://img.shields.io/badge/backups-borg-4C8B2B)
![Monitoring](https://img.shields.io/badge/monitoring-checkmk-15D1A0)
![Homelab](https://img.shields.io/badge/homelab-self--hosted-6D28D9)

Docker Compose stacks and helper scripts for a self-hosted homelab. Most stacks are deployed
from this public repo with Portainer GitOps; secrets live in Portainer stack environment
variables or gitignored `.env` files, never in Git.

## Apps & services

| App | Description |
| --- | --- |
| [3dprintforge](3dprintforge/) | 3DPrintForge — self-hosted 3D printing project/model manager (`skynett81/3dprintforge`). |
| [bambuddy](bambuddy/) | Management dashboard for Bambu Lab 3D printers (SSDP discovery, virtual printers), with its data in named volumes. |
| [Dashy](Dashy/) | Self-hosted homepage / dashboard for organizing links to your services, hardened with dropped capabilities and resource limits. |
| [Komga](Komga/) | Comics, manga, and ebook library server with a web reader and OPDS support. |
| [Manyfold3D](Manyfold3D/) | Self-hosted library/organizer for 3D-printable models, backed by PostgreSQL and Redis. |
| [Matomo](Matomo/) | Self-hosted web analytics (Google Analytics alternative) on MariaDB, with a cron sidecar for report archiving and a Borg pre-backup hook. |
| [nocodb](nocodb/) | NocoDB — no-code database / Airtable-style UI over a PostgreSQL backend. |
| [portracker](portracker/) | Network port tracker that discovers and maps exposed container/host ports. |
| [SearXNG](SearXNG/) | Privacy-respecting metasearch engine with a Valkey backend for rate limiting, packaged as a Portainer stack. |
| [Stirling-PDF](Stirling-PDF/) | Local PDF toolkit — merge, split, convert, compress, OCR, redact, and sign, with JVM heap and CPU capped so conversion jobs can't peg the host. |

## Networking & reverse proxy

| App | Description |
| --- | --- |
| [edge-stack](edge-stack/) | The deployed edge stack on smiddleware: Traefik (pinned), AdGuard Home (LAN DNS) and a whoami test service, captured from the live host. All state is bind-mounted from `/opt/netlab-stack/` on the host. |
| [traefik](traefik/) | Traefik dynamic config (transports, middlewares, routers, services; TLS via the `stepca` resolver) and the deploy-and-recover workflow that syncs it to the host. Also holds an older edge compose file; the deployed one is in `edge-stack`. |
| [TraefikAdmin](TraefikAdmin/) | Web UI for building Traefik routes without editing YAML, backed by PostgreSQL. Sits beside the edge stack and feeds Traefik over the HTTP provider — it does not run or replace Traefik. |
| [AdGuard](AdGuard/) | Standalone AdGuard Home network-wide DNS ad/tracker blocker, deployed on a dedicated macvlan interface for DHCP support. |
| [step-ca](step-ca/) | Smallstep `step-ca` internal certificate authority for issuing LAN TLS certs — [Docker server install](step-ca/Docker_Server_Install/) and [NAS install](step-ca/NAS_Install/) variants. |

## Monitoring & management

| App | Description |
| --- | --- |
| [checkmk](checkmk/) | Checkmk Community 2.5 monitoring server on optiplex-two (web UI on port 8081, agent receiver on 8000), deployed as a Portainer GitOps stack. Deployment state and next steps: [HANDOFF-POC.md](checkmk/HANDOFF-POC.md). |
| [portainer-agent](portainer-agent/) | Portainer agent compose template, pinned to the Portainer server's version, plus a sync script that redeploys it on each Docker host while keeping that host's LAN IP binding. |

## Backup & sync

| App | Description |
| --- | --- |
| [borg-backup](borg-backup/) | Borg UI (with a Redis archive cache) that pulls every host's backups over SSH into per-host repos on the Synology, plus per-host pre-backup prep scripts, a survey that generates them, and deploy/pull scripts. Current state: [HANDOFF.md](borg-backup/HANDOFF.md). |
| [Syncthing](Syncthing/) | Continuous file synchronization with a backup sidecar — [Docker server](Syncthing/Docker_Server/) and [NAS](Syncthing/NAS/) variants. |
| [KodiDB](KodiDB/) | MariaDB backend for a shared Kodi media library, backed up by Borg through a pre-backup hook that stages a consistent dump. Includes an [NVIDIA Shield client setup guide](KodiDB/NVIDIA-SHIELD-SETUP.md). |

## Scripts

| Directory | Description |
| --- | --- |
| [scripts](scripts/) | Host helper scripts for the edge stack — bootstrap directories, check certificates, and sync or roll back Traefik dynamic config (see [scripts/sbin](scripts/sbin/)). |

## Other

| Directory | Description |
| --- | --- |
| [PMP-Practice](PMP-Practice/) | Placeholder — contains only an empty readme. |

## Repo checks

GitHub Actions in [.github/workflows](.github/workflows/) check that every path is safe to check
out on Windows, and that the `borg-backup` scripts parse and their version numbers agree.
