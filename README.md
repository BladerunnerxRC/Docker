# Docker

Docker templates and misc self-hosted stack configs.

## Container apps

| App | Description |
| --- | --- |
| [AdGuard](AdGuard/) | AdGuard Home network-wide DNS ad/tracker blocker, deployed on a dedicated macvlan interface for DHCP support. |
| [Bambuddy](Bambuddy/) | Management dashboard for Bambu Lab 3D printers (SSDP discovery, virtual printers), with an optional PostgreSQL backend. |
| [Dashy](Dashy/) | Self-hosted homepage / dashboard for organizing links to your services, hardened with dropped capabilities and resource limits. |
| [KodiDB](KodiDB/) | MariaDB backend for a shared Kodi media library, plus a sidecar that takes daily gzip dumps to NFS storage. |
| [stacks/edge-stack](stacks/edge-stack/) | Edge reverse-proxy stack: Traefik (TLS, dashboard auth/IP allowlist), AdGuard Home DNS, and a whoami test service on a shared `edge` network. |
