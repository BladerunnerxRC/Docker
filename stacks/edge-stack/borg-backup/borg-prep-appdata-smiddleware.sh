#!/usr/bin/env bash

# This script prepares an app-consistent snapshot of relevant data for backup by Borg.
# It collects system information, Docker metadata, and application data from AdGuard Home, Traefik, and Portracker.
# The resulting snapshot is stored in a temporary directory and then atomically moved to the "latest" location for Borg to pick up.
# The script is designed to be run as root and ensures that the backup data is protected with strict permissions (umask 077).
# The actual backup of the data is performed by Borg, which will read from the "latest" directory created by this script.
# Usage:
#   sudo ./borg-prep-appdata-smiddleware.sh
# The script is run from the location /usr/local/sbin/borg-prep-appdata-smiddleware.sh on the Borg backup server or similar if Borg run locally
# Note: Ensure that Borg is configured to include the "${BASE}/latest" directory in its backup paths.
# This script should be run before each Borg backup to ensure that the latest application data is captured in a consistent state.
# The script handles potential errors gracefully and logs its progress to the console for monitoring purposes.
# The script also includes safeguards to prevent partial or inconsistent backups by using a temporary directory and atomic moves.
# The script is intended to be used in a Docker-based environment where applications are managed with Docker Compose and data is stored in specific directories.
# The script can be extended in the future to include additional applications or data sources as needed, following the same pattern of collecting relevant information and ensuring consistency.
# The script is part of a larger backup strategy that includes regular Borg backups and is designed to work seamlessly with the Borg backup process to ensure that all critical data is captured and protected.
# The script is licensed under the MIT License and is provided "as is" without any warranties or guarantees. Use it at your own risk and ensure that you have proper backups in place before running the script.


set -Eeuo pipefail
umask 077

BASE="/var/backups/borg-apps"
TMP="$(mktemp -d "${BASE}/.tmp.XXXXXX")"
LATEST="${BASE}/latest"

mkdir -p "$BASE"
mkdir -p "$TMP"/{metadata,docker,adguard,traefik,portracker,dashy}

echo "Preparing app-consistent backup data for smiddleware..."

# -----------------------------
# System and Docker inventory
# -----------------------------
{
  date -Is
  hostnamectl || true
  uname -a || true
  cat /etc/os-release || true
} > "$TMP/metadata/system-info.txt"

dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$TMP/metadata/dpkg-packages.tsv" 2>/dev/null || true

docker ps -a --no-trunc > "$TMP/docker/docker-ps-a.txt" 2>/dev/null || true
docker images --digests > "$TMP/docker/docker-images.txt" 2>/dev/null || true
docker volume ls > "$TMP/docker/docker-volumes.txt" 2>/dev/null || true
docker network ls > "$TMP/docker/docker-networks.txt" 2>/dev/null || true

docker inspect $(docker ps -aq) > "$TMP/docker/docker-inspect-all.json" 2>/dev/null || true

find /opt/netlab-stack \
  -maxdepth 6 \
  -type f \
  \( -name '*.yml' -o -name '*.yaml' -o -name '.env' -o -name '*.env' \) \
  -print > "$TMP/docker/netlab-stack-config-files.txt" 2>/dev/null || true

# -----------------------------
# AdGuard Home data snapshot
# -----------------------------
if [ -d /opt/netlab-stack/adguard ]; then
  rsync -a --delete /opt/netlab-stack/adguard/ "$TMP/adguard/netlab-stack-adguard/"
fi

# -----------------------------
# Traefik config, certs, ACME
# -----------------------------
if [ -d /opt/netlab-stack/traefik ]; then
  rsync -a --delete /opt/netlab-stack/traefik/ "$TMP/traefik/netlab-stack-traefik/"
fi

# -----------------------------
# Portracker data
# -----------------------------
if [ -d /volume1/docker/portracker ]; then
  rsync -a \
    --delete \
    --exclude='*.db-wal' \
    --exclude='*.db-shm' \
    /volume1/docker/portracker/ "$TMP/portracker/files/"
fi

# -----------------------------
# Dashy user data snapshot
# -----------------------------
if [[ -d /var/lib/docker/volumes/dashy_user_data/_data ]]; then
  echo "Snapshotting Dashy user data..."
  rsync -a --delete \
    /var/lib/docker/volumes/dashy_user_data/_data/ \
    "$TMP/dashy/user-data/"
fi

# SQLite-safe backup of Portracker DB if present.
if [ -f /volume1/docker/portracker/portracker.db ]; then
  sqlite3 /volume1/docker/portracker/portracker.db "PRAGMA wal_checkpoint(FULL);" >/dev/null 2>&1 || true
  sqlite3 /volume1/docker/portracker/portracker.db ".backup '$TMP/portracker/portracker.db.sqlite-backup'" || true
fi

# -----------------------------
# Docker volume metadata only
# The actual /var/lib/docker/volumes path is backed up by Borg directly.
# -----------------------------
if [ -d /var/lib/docker/volumes ]; then
  find /var/lib/docker/volumes -maxdepth 3 -mindepth 1 -print > "$TMP/docker/docker-volume-tree.txt" 2>/dev/null || true
fi

# -----------------------------
# Atomic publish of latest snapshot
# -----------------------------
rm -rf "${BASE}/previous"
if [ -d "$LATEST" ]; then
  mv "$LATEST" "${BASE}/previous"
fi

mv "$TMP" "$LATEST"
rm -rf "${BASE}/previous"

echo "App-data snapshot ready at ${LATEST}"
