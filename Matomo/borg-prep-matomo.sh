#!/usr/bin/env bash

# This script prepares an app-consistent snapshot of the Matomo stack for backup by Borg.
#
# It dumps the Matomo database plus the server's user/grant definitions, archives the
# Matomo web root (config.ini.php, installed plugins, custom logos — everything except
# tmp/ and the re-downloadable GeoIP database), verifies each piece, and atomically moves the result to the "latest" location
# for Borg to pick up. Run as root; output is protected with umask 077 because both the
# dump and config.ini.php contain credentials.
#
# The web root is backed up whole rather than just config/ because the Matomo code in
# the volume must match the DB schema on restore, and Matomo upgrades itself in place
# (the image tag does not determine the version — see README.md -> Upgrades).
#
# Retention is Borg's job — this script keeps exactly one current snapshot and lets
# Borg's own archive history and prune policy provide point-in-time recovery.
#
# Output is written UNCOMPRESSED on purpose. Borg deduplicates and compresses far
# better against plain SQL and plain tar; a gzipped file changes wholesale every run
# and forces Borg to store a full copy each time. Let Borg compress (`borg create -C zstd`).
#
# Usage:
#   sudo ./borg-prep-matomo.sh
# Deploy to /usr/local/sbin/borg-prep-matomo.sh on the Docker host running the Matomo
# stack, and ensure Borg includes "${BASE}/latest" in its backup paths. Run before each
# Borg backup.
#
# Licensed under the MIT License. Provided "as is" without warranty.

set -Eeuo pipefail
umask 077

DB_CONTAINER="${MATOMO_DB_CONTAINER:-matomo-db}"
APP_CONTAINER="${MATOMO_APP_CONTAINER:-matomo}"
BASE="${MATOMO_BACKUP_BASE:-/var/backups/borg-matomo}"
LATEST="${BASE}/latest"
MIN_DUMP_BYTES="${MIN_DUMP_BYTES:-1024}"

mkdir -p "$BASE"
TMP="$(mktemp -d "${BASE}/.tmp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP"/{database,webroot,metadata}

echo "Preparing Matomo snapshot from containers ${DB_CONTAINER} and ${APP_CONTAINER}..."

# -----------------------------
# Preconditions
# -----------------------------
# Bail loudly rather than publishing an empty snapshot that Borg would happily
# archive over a good one.
for c in "$DB_CONTAINER" "$APP_CONTAINER"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    echo "ERROR: container ${c} is not running — refusing to publish an incomplete snapshot" >&2
    exit 1
  fi
done

# Run a client command inside the DB container. MYSQL_PWD is exported from the
# container's own environment, so the password never reaches either host's
# process table or this script.
db_client() {
  local prog="$1"; shift
  docker exec -i "$DB_CONTAINER" sh -c '
    prog="$1"; shift
    export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
    exec "$prog" -uroot "$@"
  ' sh "$prog" "$@"
}

if ! db_client mariadb -N -B -e "SELECT 1" >/dev/null 2>&1; then
  echo "ERROR: cannot authenticate to ${DB_CONTAINER} as root" >&2
  exit 1
fi

DB_NAME="$(docker exec "$DB_CONTAINER" sh -c 'printf %s "$MARIADB_DATABASE"')"
if [ -z "$DB_NAME" ]; then
  echo "ERROR: MARIADB_DATABASE is not set in ${DB_CONTAINER}" >&2
  exit 1
fi

# -----------------------------
# Database dump
# -----------------------------
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

echo "  dumping ${DB_NAME}"
db_client mariadb-dump \
  --single-transaction --quick --routines --events \
  --databases "$DB_NAME" > "$TMP/database/${DB_NAME}.sql"
verify_dump "$TMP/database/${DB_NAME}.sql" "$DB_NAME"

# Users and grants live in the mysql schema, which is skipped above.
# Non-fatal: the matomo user is re-created by the image on a fresh volume anyway,
# whereas losing the analytics data is not recoverable.
echo "  dumping users/grants"
if ! db_client mariadb-dump --system=users > "$TMP/database/_users-and-grants.sql" 2>/dev/null \
   || [ ! -s "$TMP/database/_users-and-grants.sql" ]; then
  rm -f "$TMP/database/_users-and-grants.sql"
  echo "WARN: could not dump users/grants — re-create the matomo user by hand on restore" >&2
fi

# -----------------------------
# Web root archive
# -----------------------------
# tmp/ holds caches, sessions and generated assets — all rebuilt on demand.
# misc/*.mmdb is the GeoIP database (~130MB): Matomo re-downloads it monthly, so
# backing it up would make Borg store a fresh 130MB blob every month for data that
# is one download away. See README.md -> Restore for re-fetching it.
echo "  archiving web root"
docker exec "$APP_CONTAINER" tar -C /var/www/html \
  --exclude=./tmp --exclude='./misc/*.mmdb' -cf - . \
  > "$TMP/webroot/matomo-html.tar"

if ! tar -tf "$TMP/webroot/matomo-html.tar" >/dev/null 2>&1; then
  echo "ERROR: web root archive is unreadable (truncated tar)" >&2
  exit 1
fi
# Before the web installer runs there is no config.ini.php — still back up, but say so.
if ! tar -tf "$TMP/webroot/matomo-html.tar" ./config/config.ini.php >/dev/null 2>&1; then
  echo "WARN: config/config.ini.php not found — has the Matomo installer been completed?" >&2
fi

# -----------------------------
# Restore metadata
# -----------------------------
# The Matomo version must match the DB schema on restore, so record it.
{
  date -Is
  echo "db container: ${DB_CONTAINER}"
  echo "db image: $(docker inspect -f '{{.Config.Image}}' "$DB_CONTAINER" 2>/dev/null || echo unknown)"
  echo "db server version: $(db_client mariadb -N -B -e 'SELECT VERSION()' 2>/dev/null | tr -d '\r' || echo unknown)"
  echo "database: ${DB_NAME}"
  echo "app container: ${APP_CONTAINER}"
  echo "app image: $(docker inspect -f '{{.Config.Image}}' "$APP_CONTAINER" 2>/dev/null || echo unknown)"
  echo "matomo version: $(docker exec "$APP_CONTAINER" sh -c \
    "grep -o \"VERSION = '[^']*'\" /var/www/html/core/Version.php | cut -d\"'\" -f2" 2>/dev/null || echo unknown)"
} > "$TMP/metadata/snapshot-info.txt"

( cd "$TMP" && sha256sum database/*.sql webroot/*.tar ) > "$TMP/metadata/sha256sums.txt"

# -----------------------------
# Atomic publish of latest snapshot
# -----------------------------
# Borg may start at any moment; never let it see a half-written snapshot.
rm -rf "${BASE}/previous"
if [ -d "$LATEST" ]; then
  mv "$LATEST" "${BASE}/previous"
fi

mv "$TMP" "$LATEST"
trap - EXIT
rm -rf "${BASE}/previous"

echo "Matomo snapshot ready at ${LATEST}"
