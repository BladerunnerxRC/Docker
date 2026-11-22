#!/usr/bin/env bash
#
# sync-portainer-agent.sh — pull the compose file from GitHub and redeploy
#
# Usage:
#   ./sync-portainer-agent.sh             # fetch, show diff, apply, verify
#   ./sync-portainer-agent.sh --dry-run   # fetch and show diff only
#   ./sync-portainer-agent.sh --force     # use the template's tag if the server is
#                                         # unreachable; recreate even if unchanged
#   ./sync-portainer-agent.sh --no-self-update   # don't replace this script
#   ./sync-portainer-agent.sh --log       # append output to sync.log (for cron)
#
# Run it after upgrading the Portainer server; the agent follows the server.
#
# Behavior:
#   0. Replaces itself with the copy on GitHub if that one differs, then reruns
#   1. Downloads portainer-agent/docker-compose.yml from GitHub
#   2. Keeps this host's LAN-IP port binding from the current compose file
#   3. Sets the image tag to the Portainer server's version (/api/status)
#   4. Backs up the current file, pulls the image named in the new file,
#      recreates, waits for /ping
#   5. Restores the backup and recreates on failure
#   6. Prunes dangling images only after a verified-good result
#
# A host still set up in the old ~/docker-compose-scripts/portainer_agent is
# moved over on the first run: its compose file and .env are copied here.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
COMPOSE_DIR="${COMPOSE_DIR:-${HOME}/portainer-agent}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
CONTAINER="portainer_agent"
AGENT_PORT="9001"
AGENT_HOST="${AGENT_HOST:-}"

# Where hosts kept the agent before ~/portainer-agent.
LEGACY_DIR="${LEGACY_DIR:-${HOME}/docker-compose-scripts/portainer_agent}"

# Source on GitHub. REF can be a branch, tag or commit SHA. raw.githubusercontent
# caches for a few minutes, so pass a commit SHA to get a just-pushed change.
REPO="${REPO:-BladerunnerxRC/Docker}"
REF="${REF:-main}"
SRC_PATH="${SRC_PATH:-portainer-agent/docker-compose.yml}"
SRC_URL="https://raw.githubusercontent.com/${REPO}/${REF}/${SRC_PATH}"
SCRIPT_SRC_PATH="${SCRIPT_SRC_PATH:-portainer-agent/sync-portainer-agent.sh}"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${REF}/${SCRIPT_SRC_PATH}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# Portainer server — the agent is deployed at its version. Set it in the
# environment or in ${COMPOSE_DIR}/.env (gitignored), e.g.
#   PORTAINER_SERVER=https://<server-ip>:9443
if [[ -f "${COMPOSE_DIR}/.env" ]]; then
    . "${COMPOSE_DIR}/.env"
elif [[ ! -f "$COMPOSE_FILE" && -f "${LEGACY_DIR}/.env" ]]; then
    . "${LEGACY_DIR}/.env"    # not moved yet
fi
PORTAINER_SERVER="${PORTAINER_SERVER:-}"

VERIFY_RETRIES=15      # attempts
VERIFY_INTERVAL=2      # seconds between attempts

DRY_RUN=0
FORCE=0
SELF_UPDATE=1
LOG=0
LOG_FILE="${LOG_FILE:-${COMPOSE_DIR}/sync.log}"
LOG_MAX_KB="${LOG_MAX_KB:-512}"   # past this, sync.log moves to sync.log.1 (one old copy kept)
NEW_FILE=""           # downloaded compose; global so the EXIT trap can clean it up
TARGET=""             # version to deploy; set by resolve_target
FIRST_INSTALL=0
MIGRATE=0
CURRENT_FILE="$COMPOSE_FILE"   # the host's compose file as it is now; the legacy one in a dry-run move

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then        # no colour codes in cron logs
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'
    C_YEL=$'\033[0;33m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_RST=""
fi

info() { printf '%s[*]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
err()  { printf '%s[!]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Inspection
# ---------------------------------------------------------------------------

# Image tag of the container as it is running right now.
running_version() {
    docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null \
        | awk -F: '{print $NF}' || echo "not-running"
}

# Image tag written in a compose file.
file_version() {
    local v name
    v=$(grep -oP 'image:\s*portainer/agent:\K\S+' "$1" | head -n1 || true)
    # Older host files use ${AGENT_VERSION:?...}; show what .env sets it to.
    if [[ "$v" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*) ]]; then
        name="${BASH_REMATCH[1]}"
        v="${!name:-unset} (from \$${name})"
    fi
    echo "$v"
}

# LAN IP in a "<ip>:9001:9001" binding, or empty for a bare "9001:9001".
file_bind_ip() {
    grep -oP '^\s*-\s*"?\K[0-9.]+(?=:'"${AGENT_PORT}"':'"${AGENT_PORT}"')' "$1" | head -n1 || true
}

# Portainer server version. Empty if unreachable.
server_version() {
    curl -sk --max-time 5 "${PORTAINER_SERVER}/api/status" 2>/dev/null \
        | grep -oP '"Version"\s*:\s*"\K[^"]+' || echo ""
}

# ---------------------------------------------------------------------------
# Health verification
#
# The agent serves TLS on 9001 with a self-signed cert and returns 204 on
# /ping. -k is required. The container's own health status is unusable (no
# shell in the image).
# ---------------------------------------------------------------------------
verify_agent() {
    local i code
    for ((i = 1; i <= VERIFY_RETRIES; i++)); do
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 \
               "https://${AGENT_HOST}:${AGENT_PORT}/ping" 2>/dev/null || echo "000")
        if [[ "$code" == "204" || "$code" == "200" ]]; then
            ok "Agent responding on /ping (HTTP ${code}) after ${i} attempt(s)"
            return 0
        fi
        printf '    attempt %2d/%d — HTTP %s\n' "$i" "$VERIFY_RETRIES" "$code"
        sleep "$VERIFY_INTERVAL"
    done
    return 1
}

# ---------------------------------------------------------------------------
# Orphan handling
#
# A container holding the name that this compose project does not own — made
# by `docker run`, or by compose from another directory / a Portainer stack —
# is never adopted. Compose collides on the name instead. Detect and clear.
# ---------------------------------------------------------------------------
remove_orphan_if_unmanaged() {
    local id ours project workdir
    id=$(docker inspect "$CONTAINER" --format '{{.Id}}' 2>/dev/null) || return 0

    # Owned by this project? `compose ps -q` may print short IDs; prefix match.
    for ours in $(docker compose ps -a -q 2>/dev/null); do
        [[ "$id" == "$ours"* ]] && return 0
    done

    project=$(docker inspect "$CONTAINER" \
        --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
    workdir=$(docker inspect "$CONTAINER" \
        --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)

    if [[ -z "$project" || "$project" == "<no value>" ]]; then
        info "Existing container is not compose-managed — removing so compose can adopt the name"
    else
        info "Existing container belongs to compose project '${project}' (${workdir}), not this one — removing"
        info "That project still exists; retire it so it does not recreate the container"
    fi
    docker rm -f "$CONTAINER" >/dev/null
    ok "Orphan container removed"
}

# ---------------------------------------------------------------------------
# Fetch and prepare
# ---------------------------------------------------------------------------

# Downloads the template to $1 and applies this host's port binding.
fetch_compose() {
    local out="$1" bind_ip=""

    info "Fetching ${SRC_URL}"
    curl -fsSL --max-time 15 "$SRC_URL" -o "$out" \
        || die "Download failed — check REPO/REF/SRC_PATH and network"

    # Strip CRLF in case the file was committed from Windows.
    sed -i 's/\r$//' "$out"

    # The template publishes on every interface; keep this host's LAN IP.
    ((FIRST_INSTALL)) || bind_ip=$(file_bind_ip "$CURRENT_FILE")
    if [[ -n "$bind_ip" ]]; then
        sed -i -E "s|^(\s*-\s*\"?)${AGENT_PORT}:${AGENT_PORT}|\1${bind_ip}:${AGENT_PORT}:${AGENT_PORT}|" "$out"
        info "Kept port binding ${bind_ip}:${AGENT_PORT}"
    fi

    docker compose -f "$out" --project-directory "$COMPOSE_DIR" config -q \
        || die "Downloaded compose file is invalid — not applied"
}

# Sets TARGET to the server's version and writes it into the image tag of $1.
# Falls back to the template's own tag only with --force.
resolve_target() {
    local file="$1" tmpl srv
    tmpl=$(file_version "$file")

    if [[ -z "$PORTAINER_SERVER" ]]; then
        ((FORCE)) || die "PORTAINER_SERVER not set — add it to ${COMPOSE_DIR}/.env, or use --force to deploy the template's ${tmpl}"
        info "PORTAINER_SERVER not set — using the template's ${tmpl} (--force)"
        TARGET="$tmpl"
    else
        srv=$(server_version)
        if [[ -n "$srv" ]]; then
            TARGET="$srv"
        else
            ((FORCE)) || die "Could not reach ${PORTAINER_SERVER} — fix it, or use --force to deploy the template's ${tmpl}"
            info "Server unreachable — using the template's ${tmpl} (--force)"
            TARGET="$tmpl"
        fi
    fi

    [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Version '${TARGET}' is not X.Y.Z — nothing applied"
    sed -i -E "s|(image:[[:space:]]*portainer/agent:)[^[:space:]]+|\1${TARGET}|" "$file"
}

# ---------------------------------------------------------------------------
# Logging (--log)
#
# Sends all output to LOG_FILE, rotating it first once it passes LOG_MAX_KB,
# so a nightly cron job can't grow it without limit.
# ---------------------------------------------------------------------------
start_log() {
    local size_kb
    mkdir -p "$(dirname "$LOG_FILE")"
    if [[ -f "$LOG_FILE" ]]; then
        size_kb=$(( $(stat -c %s "$LOG_FILE") / 1024 ))
        ((size_kb < LOG_MAX_KB)) || mv -f "$LOG_FILE" "${LOG_FILE}.1"
    fi
    exec >>"$LOG_FILE" 2>&1
    C_RED=""; C_GRN=""; C_YEL=""; C_RST=""
    [[ -n "${SYNC_SELF_UPDATED:-}" ]] || printf '=== %s ===\n' "$(date '+%F %T')"
}

# ---------------------------------------------------------------------------
# Self-update
#
# Hosts keep a copy of this script, so fixes on GitHub would otherwise never
# reach them. A failed or invalid download keeps the running copy.
# ---------------------------------------------------------------------------
self_update() {
    local tmp
    ((SELF_UPDATE)) || return 0
    [[ -z "${SYNC_SELF_UPDATED:-}" ]] || return 0    # already restarted once

    tmp=$(mktemp "${SCRIPT_PATH}.new.XXXXXX" 2>/dev/null) \
        || { info "Can't write next to ${SCRIPT_PATH} — skipping script update"; return 0; }
    if ! curl -fsSL --max-time 15 "$SCRIPT_URL" -o "$tmp"; then
        rm -f "$tmp"
        info "Could not check GitHub for a newer script — using this copy"
        return 0
    fi
    sed -i 's/\r$//' "$tmp"

    if cmp -s "$tmp" "$SCRIPT_PATH"; then
        rm -f "$tmp"
        return 0
    fi
    if [[ ! -s "$tmp" ]] || ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        err "Script on GitHub is empty or has a syntax error — using this copy"
        return 0
    fi
    if ((DRY_RUN)); then
        rm -f "$tmp"
        info "A newer script is on GitHub — a run without --dry-run installs it first"
        return 0
    fi

    chmod 755 "$tmp"
    mv -f "$tmp" "$SCRIPT_PATH"
    ok "Updated $(basename "$SCRIPT_PATH") from GitHub — restarting it"
    SYNC_SELF_UPDATED=1 exec "$SCRIPT_PATH" "$@"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--force]

  Deploys the agent at the Portainer server's version. Pulls ${SRC_PATH}
  from github.com/${REPO} (${REF}), keeps this host's port binding, sets the
  image tag to the server's version, pulls it and recreates.

  --dry-run          Show the diff and target version, change nothing
  --force            Use the template's tag if the server is unreachable;
                     recreate even if unchanged
  --no-self-update   Don't replace this script with the copy on GitHub
  --log              Append all output to LOG_FILE (default sync.log here);
                     rotated to .1 past LOG_MAX_KB (default 512)

Environment: COMPOSE_DIR, LEGACY_DIR, REPO, REF, SRC_PATH, SCRIPT_SRC_PATH,
             AGENT_HOST, PORTAINER_SERVER, LOG_FILE, LOG_MAX_KB
EOF
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            --force)   FORCE=1 ;;
            --no-self-update) SELF_UPDATE=0 ;;
            --log)     LOG=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $arg (see --help)" ;;
        esac
    done

    ((LOG)) && start_log
    command -v curl >/dev/null || die "curl is required"
    self_update "$@"
    if [[ ! -f "$COMPOSE_FILE" && -f "${LEGACY_DIR}/docker-compose.yml" \
          && ! "$LEGACY_DIR" -ef "$COMPOSE_DIR" ]]; then
        MIGRATE=1
        info "Found the old deployment in ${LEGACY_DIR} — moving it to ${COMPOSE_DIR}"
        mkdir -p "$COMPOSE_DIR"
        if ((DRY_RUN)); then
            CURRENT_FILE="${LEGACY_DIR}/docker-compose.yml"
        else
            cp -p "${LEGACY_DIR}/docker-compose.yml" "$COMPOSE_FILE"
            ok "Copied docker-compose.yml"
            if [[ -f "${LEGACY_DIR}/.env" && ! -f "${COMPOSE_DIR}/.env" ]]; then
                cp -p "${LEGACY_DIR}/.env" "${COMPOSE_DIR}/.env"
                chmod 600 "${COMPOSE_DIR}/.env"    # may hold AGENT_SECRET
                ok "Copied .env"
            fi
        fi
    elif [[ ! -f "$COMPOSE_FILE" ]]; then
        FIRST_INSTALL=1
        info "No compose file at ${COMPOSE_FILE} — first install"
        mkdir -p "$COMPOSE_DIR"
    fi
    cd "$COMPOSE_DIR"

    local new prev target bak=""
    NEW_FILE=$(mktemp "${COMPOSE_DIR}/.docker-compose.yml.new.XXXXXX")
    trap 'rm -f "$NEW_FILE"' EXIT
    new="$NEW_FILE"

    fetch_compose "$new"
    resolve_target "$new"
    prev=$(running_version)
    target="$TARGET"

    # Probe the IP the new file publishes on (AGENT_HOST overrides).
    if [[ -z "$AGENT_HOST" ]]; then
        AGENT_HOST=$(file_bind_ip "$new")
        [[ -z "$AGENT_HOST" || "$AGENT_HOST" == "0.0.0.0" ]] && AGENT_HOST="127.0.0.1"
    fi

    printf 'Running agent:  %s\n' "$prev"
    if ((FIRST_INSTALL)); then
        printf 'Local compose:  none\n'
    else
        printf 'Local compose:  %s\n' "$(file_version "$CURRENT_FILE")"
    fi
    printf 'Target version: %s\n' "$target"
    echo

    if ((FIRST_INSTALL)); then
        info "Bare ${AGENT_PORT}:${AGENT_PORT} listens on every interface — change it to <lan-ip>:${AGENT_PORT}:${AGENT_PORT} afterwards; later syncs keep it"
    elif cmp -s "$new" "$CURRENT_FILE"; then
        # A move always recreates, so the container joins this directory's project.
        if [[ "$prev" == "$target" ]] && ! ((FORCE || MIGRATE)); then
            ok "Compose file unchanged and agent already on ${target} — nothing to change"
            VERIFY_RETRIES=3
            verify_agent && exit 0
            die "Agent is not answering on https://${AGENT_HOST}:${AGENT_PORT}/ping — run with --force to recreate it"
        fi
        info "Compose file unchanged"
    else
        info "Changes to apply:"
        diff -u --label current --label new "$CURRENT_FILE" "$new" || true
        echo
    fi

    if ((DRY_RUN)); then
        info "Dry run — nothing applied"
        exit 0
    fi

    if ! ((FIRST_INSTALL)); then
        bak="${COMPOSE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$COMPOSE_FILE" "$bak"
        ok "Compose backed up to $(basename "$bak")"
    fi
    cp "$new" "$COMPOSE_FILE"

    info "Pulling portainer/agent:${target}"
    if ! docker compose pull; then
        if [[ -n "$bak" ]]; then cp "$bak" "$COMPOSE_FILE"; else rm -f "$COMPOSE_FILE"; fi
        die "Pull failed — compose file restored, container untouched"
    fi

    remove_orphan_if_unmanaged

    info "Recreating container"
    # Not bare: under set -e a failed `up` would exit before the rollback below.
    local up_ok=1
    docker compose up -d --force-recreate || up_ok=0

    info "Verifying agent is serving"
    if ((up_ok)) && verify_agent; then
        ok "Sync complete — agent running ${target}"
        docker compose ps
        echo
        info "Pruning dangling images"
        docker image prune -f
        echo
        info "Confirm the endpoint is green in the Portainer UI before walking away."
        if ((MIGRATE)); then
            info "Moved from ${LEGACY_DIR}. Once the endpoint is green, delete it so it can't"
            info "recreate the old container:  rm -rf ${LEGACY_DIR}"
        fi
    else
        if ((up_ok)); then
            err "Agent did not respond after $((VERIFY_RETRIES * VERIFY_INTERVAL))s — rolling back to ${prev}"
        else
            err "docker compose up failed — rolling back to ${prev}"
        fi
        echo "--- container logs -------------------------------------------"
        docker logs --tail 40 "$CONTAINER" 2>&1 || true
        echo "--------------------------------------------------------------"

        if [[ -z "$bak" ]]; then
            err "First install — nothing to roll back to. Compose file left in place for debugging."
            exit 1
        fi
        cp "$bak" "$COMPOSE_FILE"
        docker compose up -d --force-recreate || true   # /ping below is the real verdict

        if verify_agent; then
            ok "Rolled back to ${prev} — agent healthy"
        else
            err "ROLLBACK ALSO FAILED. Agent is down. Investigate manually:"
            err "  docker logs ${CONTAINER}"
            err "  docker compose -f ${COMPOSE_FILE} ps"
        fi
        # No prune on failure — the old image is the rollback path.
        exit 1
    fi
}

main "$@"
