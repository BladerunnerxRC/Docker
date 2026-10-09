# Docker

![Docker Compose](https://img.shields.io/badge/deploy-docker%20compose-2496ED?logo=docker&logoColor=white)
![Portainer](https://img.shields.io/badge/managed%20by-portainer-13BEF9?logo=portainer&logoColor=white)
![Traefik](https://img.shields.io/badge/proxy-traefik-24A1C1?logo=traefikproxy&logoColor=white)
![Backups](https://img.shields.io/badge/backups-borg-4C8B2B)
![Homelab](https://img.shields.io/badge/homelab-self--hosted-6D28D9)

Docker templates and misc self-hosted stack configs.

## Apps & services

| App | Description |
| --- | --- |
| [3dprintforge](3dprintforge/) | 3DPrintForge — self-hosted 3D printing project/model manager (`skynett81/3dprintforge`). |
| [bambuddy](bambuddy/) | Management dashboard for Bambu Lab 3D printers (SSDP discovery, virtual printers), with an optional PostgreSQL backend. |
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
| [traefik](traefik/) | Edge reverse-proxy stack — Traefik with split dynamic config (transports, middlewares, routers, services), TLS via the `stepca` resolver, plus AdGuard Home DNS and a whoami test service on a shared `edge` network. |
| [TraefikAdmin](TraefikAdmin/) | Web UI for building Traefik routes without editing YAML, backed by PostgreSQL. Sits beside the `traefik` stack and feeds it over the HTTP provider — it does not run or replace Traefik. |
| [AdGuard](AdGuard/) | AdGuard Home network-wide DNS ad/tracker blocker, deployed on a dedicated macvlan interface for DHCP support. |
| [step-ca](step-ca/) | Smallstep `step-ca` internal certificate authority for issuing LAN TLS certs — [Docker server install](step-ca/Docker_Server_Install/) and [NAS install](step-ca/NAS_Install/) variants. |

## Backup & sync

| App | Description |
| --- | --- |
| [borg-backup](borg-backup/) | Borg-UI web frontend (with Redis) plus helper scripts for BorgBackup snapshot/appdata management. |
| [Syncthing](Syncthing/) | Continuous file synchronization with a backup sidecar — [Docker server](Syncthing/Docker_Server/) and [NAS](Syncthing/NAS/) variants. |
| [KodiDB](KodiDB/) | MariaDB backend for a shared Kodi media library, plus a sidecar that takes daily gzip dumps to NFS storage. |

## Scripts

| Directory | Description |
| --- | --- |
| [scripts](scripts/) | Host helper scripts for the edge stack — bootstrap directories, sync and roll back Traefik dynamic config (see [scripts/sbin](scripts/sbin/)). |
