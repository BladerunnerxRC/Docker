# Borg-Backup Application

![Version](https://img.shields.io/badge/version-3.0.0-blue)
![BorgBackup](https://img.shields.io/badge/backup-borg-4C8B2B)
![Borg UI](https://img.shields.io/badge/app-borg--ui-0F766E)
![Docker Compose](https://img.shields.io/badge/deploy-docker%20compose-2496ED?logo=docker&logoColor=white)
![Redis](https://img.shields.io/badge/cache-redis%207-DC382D?logo=redis&logoColor=white)
![Bash](https://img.shields.io/badge/scripts-bash-4EAA25?logo=gnubash&logoColor=white)

This README documents only the borg-backup application in this folder, including its Docker Compose stack and local snapshot-prep scripts used by Borg.

## Architecture

### Infrastructure

Borg UI runs on optiplex-docker and pulls each host's data over SSH. The repositories live on
the Synology, one NFS share per backed-up host, mounted on optiplex-docker at
`/mnt/borg_<host>` and inside the container at `/local/<host>`. Each host stages its snapshot
in `/var/backups/borg-apps/latest` with `/usr/local/sbin/borg-prep-appdata-<host>.sh`. The
container's other mounts are listed under [Host Path Mounts](#host-path-mounts).

```mermaid
%%{init: {"themeVariables": {"fontSize": "18px"}}}%%
flowchart TB
    ADMIN["Admin browser"]

    subgraph docker["🐳 optiplex-docker"]
        UI["borg-ui :8888<br/>+ redis cache"]
    end

    subgraph hosts["🖥️ Backed-up hosts"]
        direction LR
        SM["smiddleware<br/>.200.52"]
        O2["optiplex-two<br/>.200.14"]
        O3["optiplex-three<br/>.200.65 · k3s"]
    end

    subgraph nas["🗄️ Synology · .200.3"]
        direction LR
        REPOS[("Borg repos<br/>one share per host")]
        SCRIPTS[("Prep script<br/>backups")]
    end

    ADMIN -->|"http"| UI
    UI -->|"1. ssh: run prep script<br/>2. SSHFS: read files"| hosts
    UI ==>|"NFSv4: borg create"| REPOS
    hosts -.->|"deploy script"| SCRIPTS
```

### Backup flow

What one host's backup plan does. The prep script builds the new snapshot in a temp directory,
so a failed run leaves the previous `latest/` in place.

```mermaid
sequenceDiagram
    autonumber
    participant UI as Borg UI job
    participant W as Pre-backup script entity<br/>BORG_UI-{host}-prep-appdata
    participant H as Host · root
    participant S as /var/backups/borg-apps
    participant R as Repo /local/{host}/borg-repo-{host}

    UI->>W: run before the backup, time-out 300 s
    W->>H: ssh root@host borg-prep-appdata-{host}.sh
    H->>S: create .tmp.XXXXXX, umask 077
    loop each section
        H->>S: system and Docker inventory, app dirs, DB dumps, k3s config
    end
    H->>S: write metadata/prep-summary.txt
    H->>S: latest → previous, .tmp → latest, delete previous
    Note over H,S: On any error the trap deletes .tmp and latest/ is unchanged
    H-->>W: exit status, progress and summary table in the job log
    W-->>UI: done
    UI->>H: SSHFS mount the plan's source paths
    UI->>R: borg create latest/, /etc, /home and the plan's other paths
    UI->>R: prune and compact
```

### Prep script deploy and rollback

How a new or regenerated prep script reaches `/usr/local/sbin` on its host. All paths go through
`deploy-borg-prep-{host}.sh`, so the same checks apply to a survey deploy, a manual deploy and
a rollback.

```mermaid
flowchart TD
    SV["borg-backup-survey.sh<br/>survey and generate scripts"] --> Q{"Interactive root run<br/>on the target host?"}
    Q -- no --> LATER["Deploy later:<br/>sudo ./deploy-borg-prep-{host}.sh --test"]
    Q -- yes --> CH{"Choice 1 / 2 / N"}
    CH -- N --> LATER
    CH -- "1: back up only" --> BO["deploy --backup-only"]
    CH -- "2: deploy" --> CHK
    LATER --> CHK
    RB["deploy --rollback<br/>newest backup that differs<br/>from the installed script"] --> CHK

    BO --> BK1["Back up the installed script"] --> DONE1["Done, nothing installed"]

    CHK["Safety checks<br/>root and the right host<br/>no CRLF, not the BORG_UI wrapper<br/>shebang line, stages into borg-apps<br/>bash -n passes"]
    CHK -- fail --> FAIL["ERROR, exit 1<br/>nothing changed"]
    CHK -- pass --> SAME{"Same as the<br/>installed script?"}
    SAME -- yes --> TEST
    SAME -- no --> DIFF["Show diff"] --> ASK{"Install? y/N"}
    ASK -- N --> CANCEL["exit 3<br/>cancelled, nothing changed"]
    ASK -- y --> BK2["Back up the installed script to<br/>/var/backups/borg-script-backups/{host}/YYYYmmdd-HHMMSS/<br/>keep the newest 10"]
    BK2 --> INST["install -m 750 to /usr/local/sbin"] --> TEST{"--test?"}
    TEST -- yes --> RUN["Run the installed prep script"]
    TEST -- no --> DONE2["Done"]
```

The backups stay on the host. Every prep run copies them into the snapshot
(`metadata/script-backups/`, next to `metadata/prep-script.sh`, the script that made the run), so
each Borg archive carries them off the host. No backup share is mounted on the hosts.

### Restore flow

Restores go through the `/restore` staging area on optiplex-docker, never straight over live
data. Databases are restored from the dumps the prep script made, not from copied live files.

```mermaid
flowchart TD
    START{"Is Borg UI working?"}
    START -- yes --> PICK["Borg UI: open /local/{host}/borg-repo-{host}<br/>and pick an archive"]
    START -- "no, optiplex-docker is lost" --> DR["Rebuild Borg UI from docker_compose.yml<br/>on any Docker host, mount the Synology shares<br/>and re-add the repos with their passphrases"]
    DR --> PICK
    PICK --> SUM["Check metadata/prep-summary.txt<br/>for warnings in that run"]
    SUM --> EXT["Extract to /restore<br/>= /srv/borg-restore on optiplex-docker"]
    EXT --> COPY["rsync to the target host"]
    COPY --> WHAT{"What is being restored?"}

    WHAT -- "/etc, compose dirs, home" --> CFG["Copy back in place,<br/>fix owner and mode"]
    WHAT -- "Postgres" --> PG["Start an empty postgres container,<br/>psql -f databases/postgres-pg_dumpall.sql"]
    WHAT -- "Checkmk site" --> CMK["docker cp databases/checkmk-cmk.omd.tar checkmk:/tmp/<br/>and chown it to cmk; then as site user cmk:<br/>omd stop, omd restore /tmp/checkmk-cmk.omd.tar, omd start"]
    WHAT -- "SQLite" --> SQ["Stop the app, replace the .db with<br/>its *.sqlite-backup file,<br/>delete stale -wal and -shm files"]
    WHAT -- "Docker volume" --> VOL["Stop the stack, copy into<br/>/var/lib/docker/volumes/{volume}/_data"]
    WHAT -- "Tailscale state" --> TS{"Same machine?"}
    TS -- yes --> TSY["Restore /var/lib/tailscale"]
    TS -- no --> TSN["Do not restore it:<br/>it holds node keys.<br/>Log the new machine in again"]
    WHAT -- "k3s worker" --> K3["Restore /etc, including /etc/rancher/node/password,<br/>and rejoin. Cluster state is on the k3s server node"]
    WHAT -- "The prep script itself" --> PS["sudo ./deploy-borg-prep-{host}.sh --rollback"]

    CFG & PG & CMK & SQ & VOL & TSY & TSN & K3 --> CHECK["Start services, check health,<br/>then run a fresh backup"]
```

Without Borg UI, any Linux machine with `borg` installed can do the same: mount the host's
Synology share and run `borg list` / `borg extract` against `borg-repo-<host>`. The repos use
`repokey-blake2`, so the key is stored in the repo and only the passphrase is needed.

## Files

- `VERSION` and `CHANGELOG.md`: the current version of these scripts (3.0.0) and what changed in each version.
- `HANDOFF.md`: current state, open items and next steps.
- `docker_compose.yml`: Runs `ainullcode/borg-ui` (plus a `redis` archive-cache sidecar) with required mounts, FUSE capabilities, and hardening (resource limits, healthchecks, log rotation).
- `BORG_UI-smiddleware-prep-appdata.sh`: Borg UI script-entity wrapper that triggers remote pre-backup app snapshot prep.
- `BORG_UI-borgui-config-export-snapshot.sh`: Borg UI script-entity wrapper that creates Borg UI local config export snapshots.
- `borg-prep-appdata-smiddleware.sh`: Builds a staged snapshot under `/var/backups/borg-apps/latest` on **smiddleware** (192.168.200.52) for Borg to back up.
- `borg-prep-appdata-optiplex-two.sh`: The same, for **optiplex-two** (192.168.200.14). Generated by `borg-backup-survey.sh` 3.0.0 on 2026-10-19 and deployed.
- `BORG_UI-optiplex-two-prep-appdata.sh`: Borg UI script-entity wrapper that triggers the optiplex-two prep script over SSH.
- `borg-prep-appdata-optiplex-three.sh`: The same, for **optiplex-three** (192.168.200.65, k3s worker). Generated by `borg-backup-survey.sh` 2.0.0 from the 2026-10-11 survey, brought to 3.0.0 by hand.
- `BORG_UI-optiplex-three-prep-appdata.sh`: Borg UI script-entity wrapper that triggers the optiplex-three prep script over SSH.
- `deploy-borg-prep-<host>.sh` (one per host, generated by survey 3.0.0): Installs that host's prep script into `/usr/local/sbin` with a backup, diff and safety checks.
- `pull-borg-scripts.sh`: Downloads a host's prep and deploy scripts, the survey script and this README from GitHub into `/home/thomas/scripts/borgbackup`.
- `borg-backup-survey.sh`: Surveys an Ubuntu server (Docker, databases, non-Docker apps, Tailscale, Kubernetes, etc.), reports what Borg can back up, and optionally generates per-server versions of the two scripts above.

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

### `BORG_UI-optiplex-two-prep-appdata.sh`

Same pattern as the smiddleware wrapper: calls `/usr/local/sbin/borg-prep-appdata-optiplex-two.sh`
over SSH on `root@192.168.200.14`. Mirrors the Borg UI entity, which came from the
2026-07-03 survey run (the prep script in this repo is from the later 2026-08-01 run; the
wrapper body is identical between the two).

Borg UI script entity metadata:

- Name in Borg UI: `borg-prep-appdata-optiplex-two.sh` (the header comment suggests
  `optiplex-two-prep-appdata`; the entity was created under the prep script's filename instead)
- Description: Pre-backup app-data snapshot for optiplex-two services
- Run-on: Always (regardless of result)
- Time-out: 300 seconds (5 minutes)
- Used by: the optiplex-two backup plan (pre-backup)

### `BORG_UI-optiplex-three-prep-appdata.sh`

Same pattern as the smiddleware wrapper: calls `/usr/local/sbin/borg-prep-appdata-optiplex-three.sh`
over SSH on `root@192.168.200.65`, using Borg UI's System SSH Key.

Borg UI script entity metadata:

- Name: `optiplex-three-prep-appdata`
- Description: Pre-backup app-data snapshot for optiplex-three services
- Run-on: Always (regardless of result)
- Time-out: 300 seconds (5 minutes)
- Used by: the optiplex-three backup plan (pre-backup)

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

### Per-host prep scripts

There is one prep script per backed-up host. They share a structure — stage into a temp
directory, then atomically move it into `/var/backups/borg-apps/latest` — but each collects
a different set of apps, because each host runs different things.

> [!CAUTION]
> **The host name in the filename is load-bearing: deploying the wrong one silently backs up nothing.**

| Script | Host | Address | Deploy to |
| --- | --- | --- | --- |
| `borg-prep-appdata-smiddleware.sh` | smiddleware | 192.168.200.52 | `/usr/local/sbin/borg-prep-appdata-smiddleware.sh` |
| `borg-prep-appdata-optiplex-two.sh` | optiplex-two | 192.168.200.14 | `/usr/local/sbin/borg-prep-appdata-optiplex-two.sh` |
| `borg-prep-appdata-optiplex-three.sh` | optiplex-three | 192.168.200.65 | `/usr/local/sbin/borg-prep-appdata-optiplex-three.sh` |

#### `borg-prep-appdata-smiddleware.sh`

Behavior:

- Collects system metadata, package list, and Docker inventory.
- Collects config/data snapshots from AdGuard and Traefik under `/opt/netlab-stack`.
- Snapshots the Dashy user-data Docker volume.
- Performs SQLite-safe backup for the Portracker DB when present.
- Publishes the snapshot atomically by staging to a temp directory, then moving into `latest`.

Run manually with `sudo ./borg-prep-appdata-smiddleware.sh`.

#### `borg-prep-appdata-optiplex-two.sh`

Generated by `borg-backup-survey.sh` 3.0.0 from optiplex-two's 2026-10-19 survey and deployed
the same day (the checked-in file matches `/usr/local/sbin`). Behavior:

- Collects system metadata, package list, and Docker inventory; logs the named volumes Borg reads
  from `/var/lib/docker/volumes` (the plan includes it, so the warning is turned off on this host).
- Copies `/home/thomas` and `/home/openclaw` (without `~/.cache` and `borg-survey-*` folders),
  `/volume1/docker/portracker` and `/opt/multi-gmail/tokens` (OAuth tokens - secret).
- Checkmk: `omd backup --no-compression cmk` to `databases/checkmk-cmk.omd.tar` (about 1.7 GB,
  about 35 s). Restore from this, not from the live `checkmk_checkmk-sites` volume copy.
- Flushes Valkey/Redis persistence for `searxng-valkey`; SQLite-safe backup of `portracker.db`.
- Does not dump `mariadb-kodi`; that database has its own Borg job, [`KodiDB/borg-prep-kodidb.sh`](../KodiDB/borg-prep-kodidb.sh).
  The survey generates a `mysqldump` block for it, which was deleted by hand: **delete it again
  after regenerating.**
- Captures Tailscale state and k3s config; copies itself and its rollback copies into `metadata/`.
- Statping is gone (decommissioned 2026-10-12); `/data/compose/14` is a leftover folder and is
  not copied.
- Publishes the snapshot atomically by staging to a temp directory, then moving into `latest`.

> [!CAUTION]
> The Tailscale state **contains node keys — do not restore it onto a second machine.**

Run manually with `sudo ./borg-prep-appdata-optiplex-two.sh`.

#### `borg-prep-appdata-optiplex-three.sh`

Generated by `borg-backup-survey.sh` 2.0.0 from optiplex-three's 2026-10-11 survey and brought
to 3.0.0 by hand (the script-copy section and the `borg-survey-*` exclude below). The 2.0.0
version is what is deployed until it is redeployed with `deploy-borg-prep-optiplex-three.sh`.
optiplex-three is a **k3s worker node** on a 29 GB eMMC with little local state, so the prep
snapshot is small. Behavior:

- Collects system metadata, package list, and Docker inventory, and warns on every run if any
  Docker named volume is in use (see the named volume warning below).
- Copies `/home/thomas` (without `~/.cache` and `borg-survey-*` folders), which also covers the
  `portainer-agent` compose project in `/home/thomas/portainer-agent`.
- Copies **portracker**'s data (`/volume1/docker/portracker`) and takes a consistent SQLite copy
  of `portracker.db`. Restore the database from that copy, not from the raw file.
- Copies `/etc/rancher/k3s` and k3s manifests when present. The datastore snapshot steps are
  no-ops on a worker — cluster state lives on the k3s server node, which must be backed up separately.
- Copies itself to `metadata/prep-script.sh` and the deploy script's rollback copies to
  `metadata/script-backups/`.
- Publishes the snapshot atomically by staging to a temp directory, then moving into `latest`.

The Borg UI plan for this host backs up `/var/backups/borg-apps/latest`, `/etc` (includes the
k3s node identity, `/etc/rancher/node/password`), `/home/thomas`, and
`/var/lib/rancher/k3s/storage` (local-path PV data; empty today, included so future PVs
scheduled onto this node are caught).

Each run prints timestamped progress, sends warnings to stderr, and ends with a summary table
(files, size and time per section, plus a warning count). The same summary is saved in the
snapshot as `metadata/prep-summary.txt`, so every archive carries it.

Run manually with `sudo /usr/local/sbin/borg-prep-appdata-optiplex-three.sh`.

### `deploy-borg-prep-<host>.sh`

Every host has one, generated by the survey; all three are checked in. Run it on that host with
the prep script in the same folder (the pull script puts them together):

```bash
sudo ./deploy-borg-prep-<host>.sh --test   # checks, diff, backup, install, test run
sudo ./deploy-borg-prep-<host>.sh --list   # installed version + backups
sudo ./deploy-borg-prep-<host>.sh --rollback      # newest backup that differs from the installed script
sudo ./deploy-borg-prep-<host>.sh --backup-only   # back up the installed script, install nothing
```

It refuses the BORG_UI wrapper, CRLF line endings, syntax errors and the wrong host. Each backup
goes in its own date-time folder on the host, and the last 10 are kept:

```text
/var/backups/borg-script-backups/optiplex-three/20261020-143000/borg-prep-appdata-optiplex-three.sh
```

Prep scripts from 3.0.0 copy that folder into every snapshot (`metadata/script-backups/`), so
Borg keeps the history off the host without a backup share. A host whose prep script predates
3.0.0 (smiddleware until regenerated) still gets local rollback copies, but they
only reach Borg if the plan includes `/var/backups/borg-script-backups`.

> [!NOTE]
> Backups made by 2.0.0 deploy scripts on the Synology share
> (`/mnt/backups/borg-script-backups/<host>/`) and by 1.x in `/var/backups/borg-prep-scripts/`
> are shown by `--list` when they are reachable, but `--rollback` does not use them.

### `borg-backup-survey.sh`

Purpose:

- Surveys a new Ubuntu server and reports what can be backed up by Borg, then optionally generates that server's custom `borg-prep-appdata-<name>.sh` and `BORG_UI-<name>-prep-appdata.sh`.

What it inspects:

- System identity, disks, packages, cron jobs
- Docker: containers (Compose-managed and standalone `docker run` containers), images, volumes, networks, Compose projects, bind-mounted app data dirs (with sizes)
- Databases in containers (Postgres, MySQL/MariaDB, MongoDB, Redis, InfluxDB, Elasticsearch, ...) and SQLite files in app dirs
- Checkmk containers (`checkmk/check-mk-*` images): the site name comes from `CMK_SITE_ID` (default `cmk`)
- Applications outside Docker via systemd (web servers, databases, media servers, monitoring, DNS/DHCP, VPN, ...)
- Home directories of login users (UID 1000+ under `/home`)
- Tailscale state, Kubernetes (k3s / microk8s / kubeadm), LXD, libvirt/KVM, ZFS

Usage (run on the target server):

```bash
sudo ./borg-backup-survey.sh                 # survey + report, then prompt to generate scripts
sudo ./borg-backup-survey.sh --report-only   # report only
sudo ./borg-backup-survey.sh --generate --name myserver --address 192.168.200.60
sudo ./borg-backup-survey.sh --from ./borg-survey-myserver-20260703-110322   # regenerate scripts from a previous survey's raw data (no re-survey)
```

Each survey saves its collected state to `raw/survey-state.sh`. On the next interactive run, if a previous survey directory for the host is found, the script asks whether to re-run the survey or reuse the existing raw data to generate the scripts (`--from DIR` does the same non-interactively).

After generating scripts in an interactive root session on the target host, the survey asks what to do with the installed prep script:

```text
  1) Back up the installed script only
  2) Back up the installed script and deploy the new one (shows a diff and asks first)
  N) Nothing
```

Both options run the generated `deploy-borg-prep-<name>.sh`, so its safety checks and diff apply.
If the deploy script fails (a refused file, the wrong host), the survey exits with its error code;
answering N at the deploy script's own y/N prompt (exit 3) counts as a cancel, not a failure.

`--name` and `--address` must be plain hostnames or IP addresses, because they are written into the
generated scripts; anything else is refused before the survey starts.

Output (in `./borg-survey-<name>-<timestamp>/`). The folder is private (`700`) because `raw/` can
hold container environment variables; when run with `sudo` it belongs to the user who ran `sudo`.
Generated home copies leave out `borg-survey-*` folders, but delete old survey folders when you're
done with them anyway. Run the survey from the scripts folder (`~/scripts/borgbackup`), so its
output lands next to the scripts.

- `REPORT.md` — what was found, what Borg should back up, consistency caveats, suggested excludes
- `raw/` — raw inventory data backing the report
- `borg-prep-appdata-<name>.sh` — generated prep script following the same staged/atomic-publish pattern as the existing per-host scripts, with DB-safe dumps (pg_dumpall, mysqldump, mongodump, SQLite `.backup`, k3s etcd-snapshot, Checkmk `omd backup`) for everything detected. The Checkmk archive (`databases/<container>-<site>.omd.tar`) is written uncompressed so Borg can deduplicate it, and only renamed into place when `omd backup` succeeds. It prints the same progress lines and summary table as the optiplex-three script and saves the table as `metadata/prep-summary.txt`, plus a copy of itself and the deploy script's rollback copies. Home directories are copied without `~/.cache`, `borg-survey-*` folders and anything mounted inside them (`--one-file-system`). Nothing is copied twice: app dirs and compose projects inside a copied home are skipped, and so is a home inside a copied app dir or another home. A home or app dir of 10G or more, or whose size the survey couldn't measure in 20 seconds, is generated commented out (`SKIP` in the summary) so you decide whether to enable it
- `BORG_UI-<name>-prep-appdata.sh` — generated Borg UI script-entity wrapper (SSH trigger)
- `deploy-borg-prep-<name>.sh` — installs the prep script to `/usr/local/sbin`: backs up the old version, shows a diff, refuses the wrapper/CRLF/wrong host; `--test`, `--rollback`, `--list`, `--backup-only`

> [!IMPORTANT]
> The generated scripts are starting points reflecting what was detected at survey time — review rsync sources, database credentials, and any commented-out large directories before deploying to `/usr/local/sbin/`.

> [!WARNING]
> **Docker named volumes are not copied into the snapshot.** Bind-mounted folders are; named
> volumes (`volumes:` entries without a host path) are not, so the host's Borg plan must include
> Docker's volumes folder: `/var/lib/docker/volumes`, or `<data-root>/volumes` if Docker's
> data-root was moved. Database dumps still cover databases stored in a named volume.
> The survey lists named volumes in `REPORT.md`, and prep scripts generated by survey 2.0.0 or
> later (including the optiplex-two and optiplex-three scripts here) report a `WARN` on every run
> while any are in use, including volumes added after the survey. The smiddleware script predates
> 2.0.0 and doesn't check; regenerate it with the survey on that host. Once the Borg plan
> includes the path, turn the warning off on that host:
>
> ```bash
> sudo mkdir -p /etc/borg-backup && sudo touch /etc/borg-backup/docker-volumes-in-plan
> ```
>
> The file lives outside the prep script, so deploying or regenerating the script never resets it.

### `pull-borg-scripts.sh`

Gets the current scripts onto a host from GitHub, so they arrive with Linux line endings (copies
made on Windows have CRLF endings, which the deploy script refuses). It downloads these files from
`borg-backup/` and installs nothing:

- `borg-prep-appdata-<host>.sh` and `deploy-borg-prep-<host>.sh`
- `borg-backup-survey.sh` and `README.md`
- `pull-borg-scripts.sh` itself, so the next pull uses the new version
- `VERSION` and `CHANGELOG.md`, skipped on branches that don't have them

The Borg UI wrapper is not pulled: it belongs in the Borg UI script entity, not on the host.

Files from `main` go to `~/scripts/borgbackup`. Files from any other branch go to
`~/scripts/borgbackup-<branch>` (for example `~/scripts/borgbackup-borg-dev`), so testing a
branch never overwrites the files you normally deploy from. `--dest` overrides either.
It needs no `sudo` and no backup share.

First time, on the host:

```bash
mkdir -p ~/scripts/borgbackup && cd ~/scripts/borgbackup
curl -fsSLO https://raw.githubusercontent.com/BladerunnerxRC/Docker/main/borg-backup/pull-borg-scripts.sh
chmod 750 pull-borg-scripts.sh
./pull-borg-scripts.sh                      # this host's files from main
```

After that:

```bash
~/scripts/borgbackup/pull-borg-scripts.sh [--branch BRANCH] [--name HOST]
cd ~/scripts/borgbackup && sudo ./deploy-borg-prep-<host>.sh --test
```

To test a branch, fetch that branch's pull script into its own folder first, so the branch's
pull script is the one under test:

```bash
B=borg-dev
mkdir -p ~/scripts/borgbackup-$B && cd ~/scripts/borgbackup-$B
curl -fsSLO https://raw.githubusercontent.com/BladerunnerxRC/Docker/$B/borg-backup/pull-borg-scripts.sh
chmod 750 pull-borg-scripts.sh
./pull-borg-scripts.sh --branch $B          # lands in ~/scripts/borgbackup-borg-dev
sudo ./deploy-borg-prep-$(hostname -s).sh --test
```

Deploying from a branch folder installs that branch's prep script. To go back, deploy from
`~/scripts/borgbackup`, or run `--rollback`.

- All files are downloaded and checked (not empty, no CRLF, `#!` line, `bash -n`) before
  anything is written. A missing file stops it with nothing changed.
- `SOURCE.txt` in the folder records the branch and commit of the last pull. Git holds the
  history, so no dated copies are kept.
- Scripts are `750`, other files `640`. Run with `sudo`, files still belong to the folder's
  owner (thomas), not root. The deploy script installs to `/usr/local/sbin` as `root:root 750`.
- It prints each file as `new`, `updated` or `unchanged`.

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
| `/srv/borg-source` | `/source/data` | ![ro](https://img.shields.io/badge/ro-2563EB?style=flat-square) | Backup source data |
| `/opt/borg-ui-empty` | `/source/empty` | ![ro](https://img.shields.io/badge/ro-2563EB?style=flat-square) | Empty placeholder source |
| `/mnt/backups/borgrepo` | `/local/shared` | ![rw](https://img.shields.io/badge/rw-D97706?style=flat-square) | Optiplex Borg repo |
| `/mnt/borg_smiddleware` | `/local/smiddleware` | ![rw](https://img.shields.io/badge/rw-D97706?style=flat-square) | Smiddleware Borg repo |
| `/mnt/borg_optiplex-two` | `/local/optiplex-two` | ![rw](https://img.shields.io/badge/rw-D97706?style=flat-square) | optiplex-two Borg repo |
| `/mnt/borg_optiplex-three` | `/local/optiplex-three` | ![rw](https://img.shields.io/badge/rw-D97706?style=flat-square) | optiplex-three Borg repo |
| `/srv/borg-restore` | `/restore` | ![rw](https://img.shields.io/badge/rw-D97706?style=flat-square) | Restore staging area |
| `/var/log/borg` | `/logs` | ![ro](https://img.shields.io/badge/ro-2563EB?style=flat-square) | Borg job logs |
| `/srv/borg-ui-config-export` | `/local/borgui-config-export` | ![rw](https://img.shields.io/badge/rw-D97706?style=flat-square) | Borg UI config export snapshots (see `BORG_UI-borgui-config-export-snapshot.sh`) |

Named volumes:

- `borgui_data:/data` — Borg UI application state/database (also bind-mounted read-only into the container itself at `/local/borgui-data`, e.g. for inspection/export workflows).
- `borgui_cache:/home/borg/.cache/borg` — Borg's own archive/chunk cache.
- `borgui_redis:/data` (on the `redis` service) — Redis AOF persistence for the archive cache.

The `/mnt/backups` and `/mnt/borg_<host>` paths are NFSv4 shares from the Synology
(`192.168.200.3:/volume1/SYSBAK_borgrepos_<host>`), one per backed-up host, mounted via
`/etc/fstab` on the Borg UI host (optiplex-docker) with `x-systemd.automount`. The live stack
is deployed from Portainer, so mount changes go in the Portainer stack editor as well as here.

> [!TIP]
> If your host paths differ, edit `docker_compose.yml` before first start.

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

> [!IMPORTANT]
> Run the prep script **for that host** before its Borg backup job, so Borg reads a stable
> snapshot:

```bash
sudo ./borg-prep-appdata-smiddleware.sh    # on smiddleware
sudo ./borg-prep-appdata-optiplex-two.sh   # on optiplex-two
sudo ./borg-prep-appdata-optiplex-three.sh # on optiplex-three
```

Expected output location (every host):

- `/var/backups/borg-apps/latest`

See [Per-host prep scripts](#per-host-prep-scripts) for what each one collects. All publish
snapshots atomically by staging in a temp directory, then moving into `latest`.

## Scheduling Example

Example cron flow:

1. Run the host's `borg-prep-appdata-<host>.sh`
2. Run `borg create ... /var/backups/borg-apps/latest`
3. Run prune/compact policies

## Reliability and Operations Notes

- `borg-ui` has a 120s `stop_grace_period` so in-flight `borg create`/`compact`/`prune` operations get a chance to finish cleanly on stop/restart instead of being killed mid-operation.
- `borg-ui` and `redis` both set `mem_limit`/`pids_limit` (and `borg-ui` also sets `cpus`) to protect the host from runaway compaction/extraction jobs.
- Both services use a `json-file` logging driver capped at 10MB × 3 files to avoid unbounded log growth.
- `borg-ui` has a lightweight healthcheck (TCP connect to its own port via Python) so `restart: unless-stopped` and external monitoring can detect a wedged UI.
- `wud` labels on `borg-ui` opt it into image-update tracking (tag + digest) without auto-updating it.

## Security Notes

> [!CAUTION]
> This container uses elevated settings (`/dev/fuse`, `SYS_ADMIN`, AppArmor unconfined). Restrict host access accordingly.

- `SYS_ADMIN` is required for FUSE-based repo mounting/browsing; the container's entrypoint also needs full default capabilities at startup (running as root) to `chown`/prepare `/home/borg` before dropping to the `PUID`/`PGID` user, so capabilities are not further restricted with `cap_drop`.
- Borg repositories contain sensitive data. Protect `/mnt/backups/borgrepo` and the `/mnt/borg_<host>` shares with strict filesystem/NFS permissions.
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
