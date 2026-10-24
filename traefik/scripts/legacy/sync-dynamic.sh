#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# RETIRED - kept for reference only. Do not install or run.
#
# Copied 2026-10-24 from smiddleware:/opt/netlab-stack/traefik/sync-dynamic.sh.
# It deploys from the pre-flatten path stacks/edge-stack/traefik/dynamic,
# rsyncs straight into the folder Traefik watches and only validates YAML
# afterwards. Replaced by traefik/scripts/edge-sync-traefik-dynamic.
# The two lines below are the only change from the server copy.
# -----------------------------------------------------------------------------
echo "sync-dynamic.sh is retired; use: sudo edge-sync-traefik-dynamic" >&2
exit 1

REPO_DIR="/opt/git/Docker"
SRC="$REPO_DIR/stacks/edge-stack/traefik/dynamic"
DST="/opt/netlab-stack/traefik/dynamic"
BK="/opt/netlab-stack/traefik/backups"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source folder not found: $SRC" >&2
  exit 1
fi

sudo mkdir -p "$BK"

echo "[1/4] Backup current live dynamic config..."
sudo tar -C /opt/netlab-stack/traefik -czf "$BK/dynamic-$(date +%F-%H%M%S).tgz" dynamic

echo "[2/4] Sync repo -> live (rsync)..."
sudo rsync -a --delete "$SRC/" "$DST/"

echo "[3/4] Validate Traefik dynamic config (best-effort)..."
# Traefik doesn't always provide a perfect "validate config" CLI for dynamic,
# but we can at least ensure YAML files parse.
python3 - <<'PY'
import glob, sys, yaml
files = glob.glob("/opt/netlab-stack/traefik/dynamic/**/*.yml", recursive=True) + glob.glob("/opt/netlab-stack/traefik/dynamic/**/*.yaml", recursive=True)
bad = []
for f in files:
    try:
        with open(f, "r", encoding="utf-8") as fp:
            yaml.safe_load(fp)
    except Exception as e:
        bad.append((f, str(e)))
if bad:
    print("YAML parse errors:")
    for f,e in bad:
        print(f" - {f}: {e}")
    sys.exit(2)
print(f"OK: parsed {len(files)} YAML files")
PY

echo "[4/4] Reload Traefik (container restart for simplicity)..."
docker restart traefik >/dev/null

echo "Done."
