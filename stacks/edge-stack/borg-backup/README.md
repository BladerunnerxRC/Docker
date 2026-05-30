# Borg-Backup Application

This README documents only the borg-backup application in this folder, including its Docker Compose service and local snapshot-prep script used by Borg.

## Files

- `docker_compose.yml`: Runs `ainullcode/borg-ui` with required mounts and FUSE capabilities.
- `borg-prep-appdata-smiddleware.sh`: Builds a staged snapshot under `/var/backups/borg-apps/latest` for Borg to back up.

## What This Stack Does

- Provides a web UI for running and managing Borg backups.
- Mounts one or more Borg repositories into the container.
- Mounts backup source data as read-only paths.
- Separately prepares a consistent app-data snapshot (metadata, Docker inventory, app config/data) before backup runs.

## Service Details

- Service name: `borg-ui`
- Container name: `borg-backup`
- Image: `ainullcode/borg-ui:latest`
- Host port: `8888`
- Container port: `8081`

Open the UI at:

- `http://<host-ip>:8888`

## Host Path Mounts

The compose file currently uses these host paths:

- `/srv/borg-source:/source/data:ro`
- `/opt/borg-ui-empty:/source/empty:ro`
- `/mnt/backups/borgrepo:/repo:rw`
- `/mnt/borg_smiddleware:/repo_smiddleware:rw`
- `/var/log/borg:/logs:ro`

Named volumes:

- `borgui_data:/data`
- `borgui_cache:/home/borg/.cache/borg`

If your host paths differ, edit `docker_compose.yml` before first start.

## Prerequisites

- Docker Engine with Compose plugin
- Host paths above created with proper ownership/permissions
- FUSE available on host (`/dev/fuse`)
- AppArmor policy allowing this container setup (`apparmor:unconfined` is configured)

## Start and Stop

Start in detached mode:

```bash
docker compose -f docker_compose.yml up -d
```

Check status:

```bash
docker compose -f docker_compose.yml ps
```

Follow logs:

```bash
docker compose -f docker_compose.yml logs -f borg-ui
```

Stop:

```bash
docker compose -f docker_compose.yml down
```

## App Snapshot Prep Script

Run before Borg backup jobs so Borg reads a stable snapshot:

```bash
sudo ./borg-prep-appdata-smiddleware.sh
```

Expected output location:

- `/var/backups/borg-apps/latest`

What the script collects:

- System metadata (`hostnamectl`, kernel, OS release, package list)
- Docker inventory (`docker ps`, images, networks, volumes, inspect)
- Stack config file inventory under `/opt/netlab-stack`
- AdGuard data (`/opt/netlab-stack/adguard`)
- Traefik data (`/opt/netlab-stack/traefik`)
- Portracker files and SQLite-safe backup
- Dashy user data volume

The script publishes snapshots atomically by staging in a temp directory, then moving into `latest`.

## Scheduling Example

Example cron flow:

1. Run `borg-prep-appdata-smiddleware.sh`
2. Run `borg create ... /var/backups/borg-apps/latest`
3. Run prune/compact policies

## Security Notes

- This container uses elevated settings (`/dev/fuse`, `SYS_ADMIN`, AppArmor unconfined). Restrict host access accordingly.
- Borg repositories contain sensitive data. Protect `/mnt/backups/borgrepo` and `/mnt/borg_smiddleware` with strict filesystem permissions.
- Keep backup logs and snapshot output directories readable only by trusted users.

## Troubleshooting

- UI not reachable:
  - Confirm port mapping with `docker compose -f docker_compose.yml ps`.
  - Check host firewall for port `8888`.
- Backup source or repo path errors:
  - Validate host directories exist and are mounted as expected.
- Snapshot script failures:
  - Run as root.
  - Ensure `docker`, `rsync`, and `sqlite3` are installed.
  - Check permissions on `/var/backups/borg-apps` and source paths.