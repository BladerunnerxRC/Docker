# Borg-Backup Application

This README documents only the borg-backup application in this folder, including its Docker Compose stack and local snapshot-prep scripts used by Borg.

## Files

- `docker_compose.yml`: Runs `ainullcode/borg-ui` (plus a `redis` archive-cache sidecar) with required mounts, FUSE capabilities, and hardening (resource limits, healthchecks, log rotation).
- `BORG_UI-smiddleware-prep-appdata.sh`: Borg UI script-entity wrapper that triggers remote pre-backup app snapshot prep.
- `BORG_UI-borgui-config-export-snapshot.sh`: Borg UI script-entity wrapper that creates Borg UI local config export snapshots.
- `borg-prep-appdata-smiddleware.sh`: Builds a staged snapshot under `/var/backups/borg-apps/latest` for Borg to back up.
- `borg-backup-survey.sh`: Surveys an Ubuntu server (Docker, databases, non-Docker apps, Tailscale, Kubernetes, etc.), reports what Borg can back up, produces a `BORGUI-SETUP-<name>.md` sheet with every value needed to configure the server in Borg UI (repo, script entity, backup plan, excludes, retention), and optionally generates per-server versions of the two scripts above.

## Shell Script Reference

Scripts prefixed with `BORG_UI-` are referenced in Borg UI to create script entities. They are documented in this repo for versioning and auditing, then configured in the Borg UI Scripts section.

### `BORG_UI-smiddleware-prep-appdata.sh`

Purpose:

- Runs a remote pre-backup snapshot workflow on smiddleware before backup tasks continue.
- Calls `/usr/local/sbin/borg-prep-appdata-smiddleware.sh` over SSH on `root@192.168.200.52`.

Behavior:

- Uses non-interactive SSH (`BatchMode=yes`) and accepts new host keys automatically.
- Prints start/completion markers for job logs.

Borg UI script entity metadata (from header comments):

- Name: `smiddleware-prep-appdata`
- Description: Pre-backup app-data snapshot for smiddleware Docker services
- Run-on: Always (regardless of result)
- Time-out: 300 seconds (5 minutes)

Screenshot placeholder(s):

- `[Screenshot Placeholder: Borg UI script entity - smiddleware-prep-appdata configuration]`
- `[Screenshot Placeholder: Borg UI run history/output - smiddleware-prep-appdata]`

### `BORG_UI-borgui-config-export-snapshot.sh`

Purpose:

- Creates a local Borg UI configuration export snapshot before Borg UI self-backup.
- Captures key Borg UI state from `/data` and exports it to `/local/borgui-config-export` (mounted from the host at `/srv/borg-ui-config-export`, see [Host Path Mounts](#host-path-mounts)).

Behavior:

- Creates timestamped snapshots (`snapshot-YYYYmmdd-HHMMSS`) plus a refreshed `latest` copy.
- Uses SQLite backup API (via Python) to produce a consistent `borg.db` snapshot.
- Copies `.secret_key`, optional SSH keys, recent logs, and a lightweight file inventory.
- Retains the latest 14 snapshots and removes older ones.

Borg UI script entity metadata (from header comments):

- Name: `borgui-config-export-snapshot`
- Description: Creates regular Borg UI config export snapshot before Borg UI self-backup
- Run-on: Always (regardless of result)
- Time-out: 300 seconds (5 minutes)

Screenshot placeholder(s):

- `[Screenshot Placeholder: Borg UI script entity - borgui-config-export-snapshot configuration]`
- `[Screenshot Placeholder: Borg UI run history/output - borgui-config-export-snapshot]`

### `borg-prep-appdata-smiddleware.sh`

Purpose:

- Creates an app-consistent snapshot for Borg to back up from `/var/backups/borg-apps/latest`.

Behavior:

- Collects system metadata, package list, and Docker inventory.
- Collects config/data snapshots from AdGuard, Traefik, Portracker, and Dashy.
- Performs SQLite-safe backup for Portracker DB when present.
- Publishes the snapshot atomically by staging to a temp directory, then moving into `latest`.

Run context:

- Usually executed on the target host as `/usr/local/sbin/borg-prep-appdata-smiddleware.sh`.
- Can be run manually before backup: `sudo ./borg-prep-appdata-smiddleware.sh`

### `borg-backup-survey.sh`

Purpose:

- Surveys a new Ubuntu server and reports what can be backed up by Borg, writes a Borg UI setup sheet (`BORGUI-SETUP-<name>.md`) with everything needed to configure the server in the GUI, then optionally generates that server's custom `borg-prep-appdata-<name>.sh` and `BORG_UI-<name>-prep-appdata.sh`.

What it inspects:

- System identity, disks, packages, cron jobs
- Docker: containers (Compose-managed and standalone `docker run` containers), images, volumes, networks, Compose projects, bind-mounted app data dirs (with sizes)
- Databases in containers (Postgres, MySQL/MariaDB, MongoDB, Redis, InfluxDB, Elasticsearch, ...) and SQLite files in app dirs
- Applications outside Docker via systemd (web servers, databases, media servers, monitoring, DNS/DHCP, VPN, ...)
- Tailscale state, Kubernetes (k3s / microk8s / kubeadm), LXD, libvirt/KVM, ZFS

Usage (run on the target server):

```bash
sudo ./borg-backup-survey.sh                 # survey + report, then prompt to generate scripts
sudo ./borg-backup-survey.sh --report-only   # report only
sudo ./borg-backup-survey.sh --generate --name myserver --address 192.168.200.60
sudo ./borg-backup-survey.sh --from ./borg-survey-myserver-20260703-110322   # regenerate scripts from a previous survey's raw data (no re-survey)
```

Each survey saves its collected state to `raw/survey-state.sh`. On the next interactive run, if a previous survey directory for the host is found, the script asks whether to re-run the survey or reuse the existing raw data to generate the scripts (`--from DIR` does the same non-interactively).

Output (in `./borg-survey-<name>-<timestamp>/`):

- `REPORT.md` — what was found, what Borg should back up, consistency caveats, suggested excludes
- `BORGUI-SETUP-<name>.md` — Borg UI setup sheet (see below); produced on every run, including `--report-only` and `--from`
- `raw/` — raw inventory data backing the report
- `borg-prep-appdata-<name>.sh` — generated prep script following the same staged/atomic-publish pattern as the smiddleware one, with DB-safe dumps (pg_dumpall, mysqldump, mongodump, SQLite `.backup`, k3s etcd-snapshot) for everything detected
- `BORG_UI-<name>-prep-appdata.sh` — generated Borg UI script-entity wrapper (SSH trigger)

The generated scripts are starting points reflecting what was detected at survey time — review rsync sources, database credentials, and any commented-out large directories before deploying to `/usr/local/sbin/`.

#### The Borg UI setup sheet (`BORGUI-SETUP-<name>.md`)

A fill-in sheet built from the survey data; each section maps to a screen in the Borg UI GUI:

1. **Prerequisites** — exact `scp`/`chmod` commands to deploy the prep script and the SSH-key check from inside the `borg-backup` container
2. **Repository** — name, in-container path (`/local/<name>`), `repokey-blake2` encryption, passphrase generation, the volume line to add to `docker_compose.yml`, and the `borg key export` command
3. **Script entity** — name, description, run-on, and timeout matching the generated `BORG_UI-<name>-prep-appdata.sh` wrapper
4. **Backup plan** — archive name template, compression, schedule, source paths with sizes at survey time, and exclude patterns in borg `--exclude` syntax with reasons
5. **Retention/prune** — suggested keep-daily/weekly/monthly/yearly values plus compact
6. **Consistency notes** — databases dumped by the prep script, SQLite files safe-copied, non-Docker services, standalone containers, and Tailscale/Kubernetes secret warnings (only sections that apply to the surveyed server appear)
7. **First-run verification** — checklist covering the prep script, first backup, key export, and a test restore

Typical onboarding flow for a new server:

1. Run `sudo ./borg-backup-survey.sh --generate` on the server.
2. Review `REPORT.md` and the generated prep script; deploy it per section 1 of the setup sheet.
3. Add the repo volume line from section 2 to `docker_compose.yml` and recreate the stack.
4. Walk through sections 2–5 in the Borg UI GUI, copying values from the sheet.
5. Run the section 7 verification checklist.

## What This Stack Does

- Provides a web UI (`borg-ui`) for running and managing Borg backups.
- Uses a `redis` sidecar as an archive cache so Borg UI can browse large repositories' archive lists/contents faster.
- Mounts one or more Borg repositories into the container under `/local/*`, plus a dedicated restore-staging path.
- Exposes a config export path so Borg UI's own database/secrets/SSH keys can be snapshotted and picked up by Borg like any other app data.
- Mounts backup source data as read-only paths.
- Separately prepares a consistent app-data snapshot (metadata, Docker inventory, app config/data) before backup runs.
- Is watched by `wud` (What's Up Docker) for new image versions/digests via container labels.

## Service Details

- Service name: `borg-ui`
- Container name: `borg-backup`
- Image: `ainullcode/borg-ui:latest`
- Host port: `8888`
- Container port: `8081`

Open the UI at:

- `http://<host-ip>:8888`

### Redis sidecar

- Service name: `redis`
- Container name: `borg-redis`
- Image: `redis:7-alpine`
- Purpose: archive cache for `borg-ui` (faster archive browsing), not exposed on a host port.
- Persistence: AOF enabled (`--appendonly yes`), capped at `512mb` with `allkeys-lru` eviction, backed by the `borgui_redis` named volume.
- `borg-ui` has `depends_on: redis (condition: service_healthy)`, so it won't start until Redis passes its `redis-cli ping` healthcheck.

## Environment Variables

- `TZ`: Container timezone (`America/New_York`).
- `PORT`: Internal port Borg UI listens on (`8081`).
- `PUID` / `PGID`: User/group ID Borg UI runs as (`1024` / `100`).
- `LOCAL_MOUNT_POINTS`: Comma-separated list of in-container paths Borg UI treats as local repo/restore locations (`/local,/restore`).
- `REDIS_HOST` / `REDIS_PORT`: Connection info for the `redis` archive-cache sidecar (`redis` / `6379`).

## Host Path Mounts

The compose file currently uses these host paths:

| Host path | Container path | Mode | Purpose |
| --- | --- | --- | --- |
| `/srv/borg-source` | `/source/data` | `ro` | Backup source data |
| `/opt/borg-ui-empty` | `/source/empty` | `ro` | Empty placeholder source |
| `/mnt/backups/borgrepo` | `/local/shared` | `rw` | Optiplex Borg repo |
| `/mnt/borg_smiddleware` | `/local/smiddleware` | `rw` | Smiddleware Borg repo |
| `/srv/borg-restore` | `/restore` | `rw` | Restore staging area |
| `/var/log/borg` | `/logs` | `ro` | Borg job logs |
| `/srv/borg-ui-config-export` | `/local/borgui-config-export` | `rw` | Borg UI config export snapshots (see `BORG_UI-borgui-config-export-snapshot.sh`) |

Named volumes:

- `borgui_data:/data` — Borg UI application state/database (also bind-mounted read-only into the container itself at `/local/borgui-data`, e.g. for inspection/export workflows).
- `borgui_cache:/home/borg/.cache/borg` — Borg's own archive/chunk cache.
- `borgui_redis:/data` (on the `redis` service) — Redis AOF persistence for the archive cache.

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

## Reliability and Operations Notes

- `borg-ui` has a 120s `stop_grace_period` so in-flight `borg create`/`compact`/`prune` operations get a chance to finish cleanly on stop/restart instead of being killed mid-operation.
- `borg-ui` and `redis` both set `mem_limit`/`pids_limit` (and `borg-ui` also sets `cpus`) to protect the host from runaway compaction/extraction jobs.
- Both services use a `json-file` logging driver capped at 10MB × 3 files to avoid unbounded log growth.
- `borg-ui` has a lightweight healthcheck (TCP connect to its own port via Python) so `restart: unless-stopped` and external monitoring can detect a wedged UI.
- `wud` labels on `borg-ui` opt it into image-update tracking (tag + digest) without auto-updating it.

## Security Notes

- This container uses elevated settings (`/dev/fuse`, `SYS_ADMIN`, AppArmor unconfined). Restrict host access accordingly. `SYS_ADMIN` is required for FUSE-based repo mounting/browsing; the container's entrypoint also needs full default capabilities at startup (running as root) to `chown`/prepare `/home/borg` before dropping to the `PUID`/`PGID` user, so capabilities are not further restricted with `cap_drop`.
- Borg repositories contain sensitive data. Protect `/mnt/backups/borgrepo` and `/mnt/borg_smiddleware` with strict filesystem permissions.
- The config export path (`/srv/borg-ui-config-export`) contains Borg UI's database, secret key, and SSH keys — treat it with the same care as the repos themselves.
- Keep backup logs and snapshot output directories readable only by trusted users.

## Troubleshooting

- UI not reachable:
  - Confirm port mapping with `docker compose -f docker_compose.yml ps`.
  - Check host firewall for port `8888`.
  - Check the `borg-ui` healthcheck status (`docker compose -f docker_compose.yml ps` shows `healthy`/`unhealthy`).
- `borg-ui` won't start / stuck waiting:
  - It depends on `redis` being healthy first — check `docker compose -f docker_compose.yml logs redis`.
- `mkdir: cannot create directory '/home/borg': Permission denied` on startup:
  - The entrypoint needs its full default capability set (running as root) to prepare `/home/borg` before dropping to the configured `PUID`/`PGID`. Don't add `cap_drop: ALL` to this service.
- Backup source or repo path errors:
  - Validate host directories exist and are mounted as expected.
- Snapshot script failures:
  - Run as root.
  - Ensure `docker`, `rsync`, and `sqlite3` are installed.
  - Check permissions on `/var/backups/borg-apps` and source paths.
