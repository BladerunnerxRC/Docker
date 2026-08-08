#!/usr/bin/env bash

# This script prepares an app-consistent snapshot of the Kodi MariaDB backend for backup by Borg.
#
# It dumps each Kodi database (MyVideos*, MyMusic*, ...) plus the server's user/grant
# definitions, verifies every dump completed, and atomically moves the result to the
# "latest" location for Borg to pick up. Run as root; dumps are protected with umask 077.
#
# Retention is Borg's job — this script keeps exactly one current snapshot and lets
# Borg's own archive history and prune policy provide point-in-time recovery.
#
# Dumps are written UNCOMPRESSED on purpose. Borg deduplicates and compresses far
# better against plain SQL; a gzipped dump changes wholesale every run and forces
# Borg to store a full copy each time. Let Borg compress (e.g. `borg create -C zstd`).
#
# Usage:
#   sudo ./borg-prep-kodidb.sh
# Deploy to /usr/local/sbin/borg-prep-kodidb.sh on the Docker host running the KodiDB
# stack, and ensure Borg includes "${BASE}/latest" in its backup paths. Run before each
# Borg backup.
#
# Licensed under the MIT License. Provided "as is" without warranty.

set -Eeuo pipefail
umask 077

CONTAINER="${KODI_DB_CONTAINER:-mariadb-kodi}"
BASE="${KODI_BACKUP_BASE:-/var/backups/borg-kodidb}"
LATEST="${BASE}/latest"
MIN_DUMP_BYTES="${MIN_DUMP_BYTES:-1024}"

mkdir -p "$BASE"
TMP="$(mktemp -d "${BASE}/.tmp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP"/{databases,metadata}

echo "Preparing Kodi database snapshot from container ${CONTAINER}..."

# -----------------------------
# Preconditions
# -----------------------------
# Bail loudly rather than publishing an empty snapshot that Borg would happily
# archive over a good one.
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: container ${CONTAINER} is not running — refusing to publish an empty snapshot" >&2
  exit 1
fi

# Run a client command inside the container. MYSQL_PWD is exported from the
# container's own environment, so the password never reaches either host's
# process table or this script.
db_client() {
  local prog="$1"; shift
  docker exec -i "$CONTAINER" sh -c '
    prog="$1"; shift
    export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
    exec "$prog" -uroot "$@"
  ' sh "$prog" "$@"
}

if ! db_client mariadb -N -B -e "SELECT 1" >/dev/null 2>&1; then
  echo "ERROR: cannot authenticate to ${CONTAINER} as root" >&2
  exit 1
fi

# -----------------------------
# Database dumps (one file per DB — Kodi's MyVideos churns, MyMusic rarely
# changes, so separate files let Borg re-store only what actually moved)
# -----------------------------
mapfile -t DBS < <(
  db_client mariadb -N -B -e "SHOW DATABASES" \
    | tr -d '\r' \
    | grep -Ev '^(information_schema|performance_schema|sys|mysql)$' \
    || true
)

if [ "${#DBS[@]}" -eq 0 ]; then
  echo "ERROR: no user databases found in ${CONTAINER}" >&2
  exit 1
fi

verify_dump() {
  local f="$1" label="$2" size
  # mariadb-dump writes a completion marker as its final line; its absence means
  # the dump was truncated even though the exit status may have looked clean.
  if ! tail -c 200 "$f" | grep -q 'Dump completed'; then
    echo "ERROR: ${label} is missing its completion marker (truncated dump)" >&2
    exit 1
  fi
  size=$(stat -c%s "$f")
  if [ "$size" -lt "$MIN_DUMP_BYTES" ]; then
    echo "ERROR: ${label} is implausibly small (${size}B < ${MIN_DUMP_BYTES}B)" >&2
    exit 1
  fi
}

for db in "${DBS[@]}"; do
  echo "  dumping ${db}"
  db_client mariadb-dump \
    --single-transaction --quick --routines --events \
    --databases "$db" > "$TMP/databases/${db}.sql"
  verify_dump "$TMP/databases/${db}.sql" "$db"
done

# Users and grants live in the mysql schema, which is skipped above. Kodi's
# global GRANT is easy to forget on a restore, so capture it explicitly.
# Non-fatal: --system requires MariaDB 10.7+, and losing grants is recoverable
# (they can be re-issued by hand) whereas losing the library data is not.
echo "  dumping users/grants"
if ! db_client mariadb-dump --system=users > "$TMP/databases/_users-and-grants.sql" 2>/dev/null \
   || [ ! -s "$TMP/databases/_users-and-grants.sql" ]; then
  rm -f "$TMP/databases/_users-and-grants.sql"
  echo "WARN: could not dump users/grants — re-create the kodi GRANT by hand on restore" >&2
fi

# -----------------------------
# Restore metadata
# -----------------------------
# The DB name encodes the Kodi schema version (MyVideos121 = a specific Kodi
# release), so record what produced this snapshot.
{
  date -Is
  echo "container: ${CONTAINER}"
  echo "image: $(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || echo unknown)"
  echo "server version: $(db_client mariadb -N -B -e 'SELECT VERSION()' 2>/dev/null | tr -d '\r' || echo unknown)"
  echo "databases:"
  printf '  %s\n' "${DBS[@]}"
} > "$TMP/metadata/snapshot-info.txt"

( cd "$TMP/databases" && sha256sum ./*.sql ) > "$TMP/metadata/sha256sums.txt"

# -----------------------------
# Atomic publish of latest snapshot
# -----------------------------
# Borg may start at any moment; never let it see a half-written dump.
rm -rf "${BASE}/previous"
if [ -d "$LATEST" ]; then
  mv "$LATEST" "${BASE}/previous"
fi

mv "$TMP" "$LATEST"
trap - EXIT
rm -rf "${BASE}/previous"

echo "Kodi database snapshot ready at ${LATEST}"
