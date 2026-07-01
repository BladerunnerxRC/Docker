# Script body below only used to create the script entity in the Borg UI that prepares app-consistent data for backup. 
# The actual content of the script is in borg-prep-appdata-smiddleware.sh, which is the one that gets executed by the Borg backup process.
# This script is essentially a placeholder that can be used to trigger the preparation of app-consistent data before the Borg backup runs,
# ensuring that all necessary information and data from the applications are captured in a consistent state for backup.

# NAme: borgui-config-export-snapshot
# Description: Creates regular Borg UI config export snapshot before Borg UI self-backup
# Run-on: Always - Reguardless of result
# Time-out: 300 seconds (5 minutes)
# Script Content:


#!/bin/bash
set -Eeuo pipefail
umask 077

export_root="/local/borgui-config-export"
latest_dir="$export_root/latest"
stamp="$(date +%Y%m%d-%H%M%S)"
snapshot_dir="$export_root/snapshot-$stamp"

echo "Creating Borg UI configuration export snapshot..."

mkdir -p "$snapshot_dir"

{
  echo "Export timestamp: $(date -Is)"
  echo "Container hostname: $(hostname)"
  echo "Export root: $export_root"
} > "$snapshot_dir/export-info.txt"

# SQLite-consistent copy of Borg UI database.
python3 - <<'PY'
import sqlite3
from pathlib import Path

src = Path("/data/borg.db")
dst = Path("/local/borgui-config-export/latest-db.tmp")

if src.exists():
    src_conn = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    dst_conn = sqlite3.connect(dst)
    with dst_conn:
        src_conn.backup(dst_conn)
    src_conn.close()
    dst_conn.close()
PY

if [ -f "$export_root/latest-db.tmp" ]; then
  mv "$export_root/latest-db.tmp" "$snapshot_dir/borg.db.sqlite-backup"
fi

# Copy critical Borg UI state files.
cp -a /data/.secret_key "$snapshot_dir/.secret_key" 2>/dev/null || true

if [ -d /data/ssh_keys ]; then
  mkdir -p "$snapshot_dir/ssh_keys"
  cp -a /data/ssh_keys/. "$snapshot_dir/ssh_keys/"
fi

if [ -d /data/logs ]; then
  mkdir -p "$snapshot_dir/logs"
  find /data/logs -type f -mtime -14 -exec cp -a {} "$snapshot_dir/logs/" \; 2>/dev/null || true
fi

# Lightweight inventory of /data.
find /data -maxdepth 3 -printf '%M %u %g %s %TY-%Tm-%Td %TH:%TM %p\n' \
  > "$snapshot_dir/data-file-inventory.txt" 2>/dev/null || true

# Refresh latest copy.
rm -rf "$latest_dir"
mkdir -p "$latest_dir"
cp -a "$snapshot_dir"/. "$latest_dir"/

# Keep last 14 local export snapshots.
find "$export_root" -maxdepth 1 -type d -name 'snapshot-*' | sort | head -n -14 | xargs -r rm -rf

echo "Borg UI configuration export snapshot ready at $latest_dir"