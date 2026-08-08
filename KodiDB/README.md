# Kodi Shared Library — MariaDB Backend

A Docker Compose stack that runs **MariaDB** as a central database backend for a
shared [Kodi](https://kodi.tv) library. Backups are handled externally by
**Borg**, which calls a pre-backup hook to stage a consistent dump.

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
| `mariadb-kodi` | `mariadb:11` | The database engine Kodi clients connect to. The stack's only service. |

**Storage**

| Volume | Location | Notes |
|---|---|---|
| `kodi-db-data` | Docker host local disk | DB data dir (`/var/lib/mysql`). Local disk is used deliberately — InnoDB over NFS risks corruption. |

**Backups** are out of scope for this stack — see [Backups & Restore](#backups--restore).
Borg runs [`borg-prep-kodidb.sh`](borg-prep-kodidb.sh) on the Docker host before each
run, which stages SQL dumps at `/var/backups/borg-kodidb/latest` for Borg to archive.

---

## Requirements

- A Docker host with **Portainer** installed.
- **Borg** already backing up this host, with the ability to run a pre-backup script.
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
| `TZ` | `America/New_York` | Timezone (affects log timestamps). |
| `MARIADB_PORT` | `3306` | Host port exposed for Kodi clients. |
| `INNODB_BUFFER_POOL_SIZE` | `512M` | InnoDB cache size. Raise if RAM allows. |

The backup script reads the root password from the running container's own
environment, so it needs no credentials of its own. It accepts optional overrides
as environment variables — `KODI_DB_CONTAINER` (default `mariadb-kodi`),
`KODI_BACKUP_BASE` (default `/var/backups/borg-kodidb`), and `MIN_DUMP_BYTES`
(default `1024`).

---

## Deploying in Portainer

1. **In Portainer:**
   - **Stacks → Add stack**, name it `kodi-db`.
   - Paste the contents of [`docker-compose.yml`](docker-compose.yml) into the web editor.
   - Add the [environment variables](#environment-variables) above.
   - **Deploy the stack.**

2. Watch the `mariadb-kodi` logs for `ready for connections`, then continue to
   [Database Setup](#database-setup).

3. Wire up backups — see [Backups & Restore](#backups--restore). The stack itself
   has no backup service; nothing protects this database until the Borg hook is
   installed.

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

**This stack does not back itself up.** Copying `/var/lib/docker/volumes/` while
MariaDB is running captures a torn InnoDB data dir, so Borg gets a logical dump
instead, staged by a pre-backup hook.

[`borg-prep-kodidb.sh`](borg-prep-kodidb.sh) runs on the Docker host before each
Borg run and:

1. Refuses to continue unless `mariadb-kodi` is running and root can authenticate —
   it never publishes an empty snapshot over a good one.
2. Dumps **each Kodi database to its own file** with `--single-transaction`, plus
   users and grants to `_users-and-grants.sql`. Per-database files matter for
   dedup: `MyVideos*` churns constantly (watched status, resume points) while
   `MyMusic*` barely changes, so Borg only re-stores what actually moved.
3. Verifies every dump ends with mariadb-dump's `Dump completed` marker and clears
   `MIN_DUMP_BYTES`. A truncated dump aborts the run **before** it is published.
4. Writes `metadata/snapshot-info.txt` (server version, image, database list) and
   `sha256sums.txt`.
5. Atomically `mv`s the staging dir into place, so Borg can never read a
   half-written dump no matter when it starts.

Dumps are left **uncompressed on purpose** — a gzipped dump changes wholesale
every run and defeats deduplication. Let Borg compress (`borg create -C zstd`).

Retention is **Borg's** job now: the script keeps exactly one current snapshot and
your Borg prune policy provides the point-in-time history.

### Installing the hook

1. Copy the script to the Docker host running this stack:

   ```bash
   sudo install -m 0700 -o root -g root \
     borg-prep-kodidb.sh /usr/local/sbin/borg-prep-kodidb.sh
   ```

2. Add `/var/backups/borg-kodidb/latest` to Borg's **backup paths**. Without this
   the dump is produced every night and never archived.

3. Register the pre-backup script in the Borg UI using
   [`BORG_UI-kodidb-prep-dbdump.sh`](BORG_UI-kodidb-prep-dbdump.sh) as the script
   body — edit the target IP to match the Docker host. This mirrors the pattern
   used by `borg-backup/BORG_UI-smiddleware-prep-appdata.sh`.

4. Verify by hand before trusting it:

   ```bash
   sudo /usr/local/sbin/borg-prep-kodidb.sh
   ls -la /var/backups/borg-kodidb/latest/databases/
   ```

> If this host already runs a `borg-prep-appdata-*.sh` script, the two are
> independent — this one uses its own `/var/backups/borg-kodidb` base so neither
> can clobber the other's atomic publish. You can call it from the existing prep
> script instead of registering a second Borg UI entry.

**Manual dump on demand (outside Borg):**

```bash
docker exec mariadb-kodi \
  mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --all-databases \
  --single-transaction --events | gzip > kodi-manual.sql.gz
```

**Restore from a Borg archive:**

```bash
# Extract the snapshot from whichever archive you want
borg extract ::ARCHIVE var/backups/borg-kodidb/latest

# Restore one database (or loop over the directory for all of them)
docker exec -i mariadb-kodi mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" \
  < var/backups/borg-kodidb/latest/databases/MyVideos121.sql
```

Each file carries its own `CREATE DATABASE IF NOT EXISTS` / `USE` header, so
databases can be restored individually. Replay `_users-and-grants.sql` if the
`kodi` account or its global grant is missing. Check
`metadata/snapshot-info.txt` first — the database name encodes the Kodi schema
version, and restoring into a different Kodi release will not end well.

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
| `container mariadb-kodi is not running` from the hook | The stack is down, or renamed — set `KODI_DB_CONTAINER` if you changed `container_name`. |
| `cannot authenticate as root` from the hook | The container's `MARIADB_ROOT_PASSWORD` no longer matches the initialized data dir. The env var only applies on **first** init; changing it later does nothing. |
| Dumps exist but aren't in Borg archives | `/var/backups/borg-kodidb/latest` was never added to Borg's backup paths. |
| `bash\r: no such file or directory` | `borg-prep-kodidb.sh` was checked out with CRLF endings. Ensure [`.gitattributes`](.gitattributes) is present, then `git rm --cached borg-prep-kodidb.sh && git checkout borg-prep-kodidb.sh`. |
| `missing its completion marker` | The dump was truncated — usually the container was stopped mid-run or the host filled up. Check free space on `/var/backups`. |
| Can't connect from a client | Confirm `MARIADB_PORT` is reachable on the Docker host and not blocked by a firewall/VLAN. |
