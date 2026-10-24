#!/usr/bin/env bash
# mkcert-refresh.sh (Debian-safe)
#
# Usage:
#   sudo ./mkcert-refresh.sh                  # uses DEFAULT list below
#   sudo ./mkcert-refresh.sh komga.shome ...  # overrides with args
#
# Does (all in BASE_DIR):
# - timestamp backups of shome.pem + shome-key.pem
# - mkcert reissue
# - restart traefik
# - running log

set -euo pipefail

### --- CONFIG YOU MAY EDIT ANY TIME ---
BASE_DIR="/opt/netlab-stack/traefik/certs"
CERT_PEM="${BASE_DIR}/shome.pem"
KEY_PEM="${BASE_DIR}/shome-key.pem"
TRAEFIK_CONTAINER_NAME="traefik"
LOG_FILE="${BASE_DIR}/mkcert-refresh.log"

# Default names (edit anytime). One per line. Blank lines and # comments ignored.
DEFAULT_MKCERT_NAMES="$(cat <<'EOF'
# base / wildcard
shome
*.shome

# services
traefik.shome
dns.shome
test.shome
haos.shome
porttracker.shome
komga.shome

# add more like:
# somedamnname.shome
EOF
)"
### --- END CONFIG ---

timestamp() { date +"%Y%m%d-%H%M%S"; }

log() {
  local msg="$1"
  mkdir -p "$BASE_DIR"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $msg" | tee -a "$LOG_FILE"
}

die() { log "ERROR: $1"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need_cmd mkcert
need_cmd docker
need_cmd openssl

mkdir -p "$BASE_DIR"

# Build NAMES array either from args or from DEFAULT_MKCERT_NAMES
NAMES=()
if [[ $# -gt 0 ]]; then
  NAMES=("$@")
else
  while IFS= read -r line; do
    # trim whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    NAMES+=("$line")
  done <<< "$DEFAULT_MKCERT_NAMES"
fi

log "=== mkcert refresh starting ==="
log "Host: $(hostname) | User: $(id -un) | Shell: ${BASH_VERSION:-unknown}"
log "Cert : $CERT_PEM"
log "Key  : $KEY_PEM"
log "Names: ${NAMES[*]}"

TS="$(timestamp)"

# Backups
if [[ -f "$CERT_PEM" ]]; then
  cp -a "$CERT_PEM" "${CERT_PEM}.${TS}.bak"
  log "Backed up cert -> ${CERT_PEM}.${TS}.bak"
else
  log "No existing cert at $CERT_PEM (first run?)"
fi

if [[ -f "$KEY_PEM" ]]; then
  cp -a "$KEY_PEM" "${KEY_PEM}.${TS}.bak"
  log "Backed up key  -> ${KEY_PEM}.${TS}.bak"
else
  log "No existing key at $KEY_PEM (first run?)"
fi

log "Ensuring mkcert CA installed for current user..."
mkcert -install >>"$LOG_FILE" 2>&1 || die "mkcert -install failed (see log)"

log "Running mkcert (reissue leaf cert + key)..."
mkcert -cert-file "$CERT_PEM" -key-file "$KEY_PEM" "${NAMES[@]}" >>"$LOG_FILE" 2>&1 \
  || die "mkcert issuance failed (see log)"

log "Verifying SANs..."
SAN_OUT="$(openssl x509 -in "$CERT_PEM" -noout -text | sed -n '/Subject Alternative Name/,+2p' || true)"
echo "$SAN_OUT" | tee -a "$LOG_FILE"

# Tight perms
chmod 0644 "$CERT_PEM" || true
chmod 0600 "$KEY_PEM"  || true

log "Restarting Traefik container: $TRAEFIK_CONTAINER_NAME"
docker restart "$TRAEFIK_CONTAINER_NAME" >>"$LOG_FILE" 2>&1 \
  || die "Failed to restart Traefik container '$TRAEFIK_CONTAINER_NAME' (see log)"

log "=== mkcert refresh complete ==="
