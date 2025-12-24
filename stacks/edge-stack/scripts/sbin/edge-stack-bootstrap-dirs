sudo tee /usr/local/sbin/edge-stack-bootstrap-dirs.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Config (edit if needed)
# -------------------------
APP_USER="${APP_USER:-thomas}"
APP_GROUP="${APP_GROUP:-thomas}"     # usually same as user on Pi OS
DOCKER_GROUP="${DOCKER_GROUP:-docker}"

# Base paths
GIT_BASE="/opt/git"
NETLAB_BASE="/opt/netlab-stack"
TRAEFIK_BASE="${NETLAB_BASE}/traefik"
ADGUARD_BASE="${NETLAB_BASE}/adguard"

LOG_DIR="/var/log/edge-sync"

# -------------------------
# Helpers
# -------------------------
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root: sudo $0" >&2
    exit 1
  fi
}

have_user() { id -u "$1" >/dev/null 2>&1; }
have_group() { getent group "$1" >/dev/null 2>&1; }

mk() {
  local path="$1"
  mkdir -p "$path"
}

chown_mode() {
  local owner="$1" group="$2" mode="$3" path="$4"
  chown -R "${owner}:${group}" "$path"
  chmod -R "$mode" "$path"
}

# -------------------------
# Main
# -------------------------
need_root

if ! have_user "$APP_USER"; then
  echo "ERROR: user '$APP_USER' does not exist" >&2
  exit 2
fi

if ! have_group "$APP_GROUP"; then
  echo "ERROR: group '$APP_GROUP' does not exist" >&2
  exit 3
fi

if ! have_group "$DOCKER_GROUP"; then
  echo "WARN: group '$DOCKER_GROUP' not found; skipping docker-group membership check" >&2
else
  if ! id -nG "$APP_USER" | tr ' ' '\n' | grep -qx "$DOCKER_GROUP"; then
    echo "INFO: adding $APP_USER to $DOCKER_GROUP (logout/login required)" >&2
    usermod -aG "$DOCKER_GROUP" "$APP_USER"
  fi
fi

echo "== Creating directories =="

# Git working area (repo clones)
mk "$GIT_BASE"
chmod 0755 "$GIT_BASE"
chown "${APP_USER}:${APP_GROUP}" "$GIT_BASE"

# Netlab base + Traefik structure
mk "$NETLAB_BASE"
chmod 0755 "$NETLAB_BASE"
chown "${APP_USER}:${APP_GROUP}" "$NETLAB_BASE"

mk "$TRAEFIK_BASE"
chmod 0755 "$TRAEFIK_BASE"
chown "${APP_USER}:${APP_GROUP}" "$TRAEFIK_BASE"

# Traefik directories
mk "${TRAEFIK_BASE}/dynamic"
mk "${TRAEFIK_BASE}/acme"
mk "${TRAEFIK_BASE}/certs"
mk "${TRAEFIK_BASE}/stepca"
mk "${TRAEFIK_BASE}/backups"
mk "${TRAEFIK_BASE}/dynamic-archive"

# Permissions:
# - dynamic: editable by APP_USER
# - acme: contains cert material; keep tighter
# - certs/stepca: usually read-only inputs; keep tighter
# - backups/archive: readable by APP_USER; backups contain config history
chown_mode "$APP_USER" "$APP_GROUP" 0775 "${TRAEFIK_BASE}/dynamic"
chown_mode "$APP_USER" "$APP_GROUP" 0700 "${TRAEFIK_BASE}/acme"
chown_mode "$APP_USER" "$APP_GROUP" 0750 "${TRAEFIK_BASE}/certs"
chown_mode "$APP_USER" "$APP_GROUP" 0750 "${TRAEFIK_BASE}/stepca"
chown_mode "$APP_USER" "$APP_GROUP" 0750 "${TRAEFIK_BASE}/backups"
chown_mode "$APP_USER" "$APP_GROUP" 0750 "${TRAEFIK_BASE}/dynamic-archive"

# AdGuard (only if you’re storing bind mounts under /opt/netlab-stack)
mk "$ADGUARD_BASE"
mk "${ADGUARD_BASE}/conf"
mk "${ADGUARD_BASE}/work"
chown_mode "$APP_USER" "$APP_GROUP" 0770 "$ADGUARD_BASE"

# Logging
mk "$LOG_DIR"
chown root:root "$LOG_DIR"
chmod 0755 "$LOG_DIR"

# Optional: ensure main log files exist
touch "${LOG_DIR}/edge-sync-traefik-dynamic.log" "${LOG_DIR}/edge-rollback-traefik-dynamic.log"
chown root:root "${LOG_DIR}/edge-sync-traefik-dynamic.log" "${LOG_DIR}/edge-rollback-traefik-dynamic.log"
chmod 0644 "${LOG_DIR}/edge-sync-traefik-dynamic.log" "${LOG_DIR}/edge-rollback-traefik-dynamic.log"

echo "== Summary =="
echo "Git base:           $GIT_BASE   (owner: ${APP_USER}:${APP_GROUP}, 0755)"
echo "Traefik dynamic:    ${TRAEFIK_BASE}/dynamic (owner: ${APP_USER}:${APP_GROUP}, 0775)"
echo "Traefik acme:       ${TRAEFIK_BASE}/acme    (owner: ${APP_USER}:${APP_GROUP}, 0700)"
echo "Traefik certs:      ${TRAEFIK_BASE}/certs   (owner: ${APP_USER}:${APP_GROUP}, 0750)"
echo "Traefik stepca:     ${TRAEFIK_BASE}/stepca  (owner: ${APP_USER}:${APP_GROUP}, 0750)"
echo "Traefik backups:    ${TRAEFIK_BASE}/backups (owner: ${APP_USER}:${APP_GROUP}, 0750)"
echo "Traefik archive:    ${TRAEFIK_BASE}/dynamic-archive (owner: ${APP_USER}:${APP_GROUP}, 0750)"
echo "AdGuard bind dirs:  ${ADGUARD_BASE}/{conf,work} (owner: ${APP_USER}:${APP_GROUP}, 0770)"
echo "Logs:               $LOG_DIR (root:root, 0755; log files 0644)"
echo "DONE."
EOF

sudo chmod +x /usr/local/sbin/edge-stack-bootstrap-dirs.sh
