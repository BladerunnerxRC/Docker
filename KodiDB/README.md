# Kodi Shared Library — MariaDB Backend

A Docker Compose stack that runs **MariaDB** as a central database backend for a
shared [Kodi](https://kodi.tv) library, plus an automatic nightly backup service
that dumps to a NAS over NFS.

Pointing multiple Kodi clients at one database gives you a **single shared library**:
watched status, resume points, and play counts stay in sync across every device,
and you only scrape/maintain metadata once.

---

## Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Environment Variables](#environment-variables)
- [Deploying in Portainer](#deploying-in-portainer)
- [Database Setup](#database-setup)
- [Kodi Configuration (`advancedsettings.xml`)](#kodi-configuration-advancedsettingsxml)
- [Backups & Restore](#backups--restore)
- [Maintenance & Upgrades](#maintenance--upgrades)
- [Troubleshooting](#troubleshooting)

---

## Architecture

| Service | Image | Purpose |
|---|---|---|
| `mariadb-kodi` | `mariadb:11` | The database engine Kodi clients connect to. |
| `mariadb-kodi-backup` | `mariadb:11` | Sidecar that runs `mariadb-dump` nightly and prunes old dumps. |

**Storage**

| Volume | Location | Notes |
|---|---|---|
| `kodi-db-data` | Docker host local disk | DB data dir (`/var/lib/mysql`). Local disk is used deliberately — InnoDB over NFS risks corruption. |
| `kodi-db-backups` | NAS via NFS | Compressed nightly dumps land here for durable, off-host storage. |

---

## Requirements

- A Docker host (separate from the NAS) with **Portainer** installed.
- A **Synology NAS** (or any NFS server) with an NFS export for backups.
- Kodi clients on the **same Kodi major version** (the DB schema is tied to it).
- All clients must reference media via **identical network paths** (`nfs://`, `smb://`) —
  not local drive paths — or watched states won't match across devices.

---

## Environment Variables

Set these in Portainer's **Stack → Environment variables** section, or copy
[`.env.example`](.env.example) to `.env` if you deploy with `docker compose` directly.

| Name | Example | Description |
|---|---|---|
| `MARIADB_ROOT_PASSWORD` | *strong password* | Root/admin account password. |
| `MARIADB_USER` | `kodi` | The DB user Kodi connects as. |
| `MARIADB_PASSWORD` | *strong password* | Must match the password in `advancedsettings.xml`. |
| `TZ` | `America/New_York` | Timezone (affects backup timestamps). |
| `MARIADB_PORT` | `3306` | Host port exposed for Kodi clients. |
| `INNODB_BUFFER_POOL_SIZE` | `512M` | InnoDB cache size. Raise if RAM allows. |
| `BACKUP_RETENTION_DAYS` | `14` | Days of nightly dumps to keep. |
| `NAS_HOST` | `192.168.1.10` | IP/hostname of the NFS server (NAS). |
| `NAS_EXPORT` | `/volume1/docker/kodi-db` | NFS export path; must contain a `backups` subfolder. |

---

## Deploying in Portainer

1. **On the NAS (one-time NFS setup):**
   - Enable **NFS** in *Control Panel → File Services → NFS*.
   - Create the backup folder, e.g. `/volume1/docker/kodi-db/backups`.
   - On the shared folder, add an **NFS permission rule** for the Docker host's IP
     (or subnet), with **Read/Write**, squash set to *Map all users to admin*, and
     *Allow connections from non-privileged ports* enabled.

2. **In Portainer:**
   - **Stacks → Add stack**, name it `kodi-db`.
   - Paste the contents of [`docker-compose.yml`](docker-compose.yml) into the web editor.
   - Add the [environment variables](#environment-variables) above.
   - **Deploy the stack.**

3. Watch the `mariadb-kodi` logs for `ready for connections`, then continue to
   [Database Setup](#database-setup).

> If `nfsvers=4` fails, your NAS may only export NFSv3 — change `nfsvers=4` to
> `nfsvers=3` in the `kodi-db-backups` volume options.

---

## Database Setup

Kodi manages its **own versioned databases** (`MyVideos121`, `MyMusic82`, …) and
creates/drops them automatically, so the `kodi` user needs **global privileges**
(`*.*`) — not access to a single named database.

The `MARIADB_USER`/`MARIADB_PASSWORD` env vars create the user, but only grant it
rights to one default DB. After the stack's first start, run the global grant once:

**Via Portainer** → `mariadb-kodi` container → **Console** (`/bin/bash`), or from the Docker host:

```bash
docker exec -it mariadb-kodi \
  mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" \
  -e "GRANT ALL PRIVILEGES ON *.* TO 'kodi'@'%'; FLUSH PRIVILEGES;"
```

Verify the user can connect:

```bash
docker exec -it mariadb-kodi \
  mariadb -ukodi -p"$MARIADB_PASSWORD" -e "SELECT 1;"
```

You do **not** need to manually create any `MyVideos*` / `MyMusic*` databases —
Kodi builds them on first connection from a client.

---

## Kodi Configuration (`advancedsettings.xml`)

On **each** Kodi client, edit (or create) `advancedsettings.xml` in the Kodi
`userdata` folder:

| Platform | Path |
|---|---|
| Windows | `%APPDATA%\Kodi\userdata\advancedsettings.xml` |
| Linux | `~/.kodi/userdata/advancedsettings.xml` |
| Android | `Android/data/org.xbmc.kodi/files/.kodi/userdata/advancedsettings.xml` |
| LibreELEC / CoreELEC | `/storage/.kodi/userdata/advancedsettings.xml` |
| macOS | `~/Library/Application Support/Kodi/userdata/advancedsettings.xml` |

Contents:

```xml
<advancedsettings>
  <videodatabase>
    <type>mysql</type>
    <host>192.168.1.20</host>   <!-- Docker host IP running MariaDB -->
    <port>3306</port>
    <user>kodi</user>
    <pass>your_kodi_password</pass>
  </videodatabase>

  <musicdatabase>
    <type>mysql</type>
    <host>192.168.1.20</host>
    <port>3306</port>
    <user>kodi</user>
    <pass>your_kodi_password</pass>
  </musicdatabase>

  <videolibrary>
    <importwatchedstate>true</importwatchedstate>
    <importresumepoint>true</importresumepoint>
  </videolibrary>
</advancedsettings>
```

**Important notes**

- `<type>mysql</type>` is correct for **both** MySQL and MariaDB — there is no
  separate `mariadb` type.
- `<host>` is the **Docker host** IP (the machine running this stack), **not** the NAS.
- `<user>`/`<pass>` must match `MARIADB_USER`/`MARIADB_PASSWORD`.
- After editing, **fully restart Kodi**. The first client to connect builds the library;
  point the others at the same DB and add media via the **same network source paths**.
- Artwork/thumbnail caches remain **local per client** — only metadata is shared.

---

## Backups & Restore

The `mariadb-kodi-backup` service runs `mariadb-dump --all-databases` once every
24h, gzips the output to the NAS, and deletes dumps older than
`BACKUP_RETENTION_DAYS`. Files are named `kodi-YYYYMMDD-HHMMSS.sql.gz`.

**Manual backup on demand:**

```bash
docker exec mariadb-kodi \
  mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --all-databases \
  --single-transaction --events | gzip > kodi-manual.sql.gz
```

**Restore from a dump:**

```bash
gunzip < kodi-YYYYMMDD-HHMMSS.sql.gz | \
  docker exec -i mariadb-kodi mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"
```

> Always take a fresh dump **before** a major Kodi upgrade — a bad schema
> migration can wipe watched history.

---

## Maintenance & Upgrades

- **Keep Kodi versions in sync.** The DB name encodes the schema version
  (`MyVideos121` = a specific Kodi release). Mixing Kodi versions against one DB
  causes conflicts — upgrade all clients together.
- **Updating the MariaDB image:** pull the new image and recreate; the
  `kodi-db-data` volume persists your data.
- **Buffer pool:** if the library is large and the host has RAM, raise
  `INNODB_BUFFER_POOL_SIZE` for faster browsing.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Kodi shows an empty/local library | `advancedsettings.xml` not loaded — check path and restart Kodi fully. |
| `Access denied for user 'kodi'` | Global grant not applied — re-run the [grant command](#database-setup). |
| Watched state differs per device | Media added via different source paths — use identical `nfs://`/`smb://` paths everywhere. |
| Backup container restarts / no dumps | NFS mount failing — verify `NAS_HOST`, `NAS_EXPORT`, the `backups` subfolder, and NAS NFS permissions. |
| Container won't start after edit | A named volume failed to mount (usually NFS) — check `nfsvers` and NAS export rules. |
| Can't connect from a client | Confirm `MARIADB_PORT` is reachable on the Docker host and not blocked by a firewall/VLAN. |
