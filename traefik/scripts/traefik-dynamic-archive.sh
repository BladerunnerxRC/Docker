#!/usr/bin/env bash
# traefik-dynamic-archive.sh
# Tar + gzip all *.yml in /opt/netlab-stack/traefik/dynamic
# Output archive in /opt/netlab-stack/traefik/dynamic-archive with timestamp suffix.

set -euo pipefail

SRC_DIR="/opt/netlab-stack/traefik/dynamic"
DST_DIR="/opt/netlab-stack/traefik/dynamic-archive"
PREFIX="dynamic-pre-restore"
TS="$(date +'%Y-%m-%d-%H%M%S')"
OUT_FILE="${DST_DIR}/${PREFIX}-${TS}.tgz"

# Safety checks
if [[ ! -d "$SRC_DIR" ]]; then
  echo "ERROR: Source directory not found: $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$DST_DIR"

# Ensure there is at least one matching file
shopt -s nullglob
yml_files=("$SRC_DIR"/*.yml)
shopt -u nullglob

if (( ${#yml_files[@]} == 0 )); then
  echo "ERROR: No .yml files found in $SRC_DIR" >&2
  exit 1
fi

# Create archive (store relative paths, not full absolute paths)
tar -C "$SRC_DIR" -czf "$OUT_FILE" ./*.yml

echo "OK: Created archive:"
echo "  $OUT_FILE"
echo "Contents:"
tar -tzf "$OUT_FILE"
