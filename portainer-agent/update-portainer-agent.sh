#!/usr/bin/env bash
#
# update-portainer-agent.sh — versioned, verified, rollback-safe agent update
#
# Usage:
#   ./update-portainer-agent.sh 2.39.1     # update to a specific version
#   ./update-portainer-agent.sh --check    # report current vs. server version
#   ./update-portainer-agent.sh --current  # show running version only
#
# Behavior:
#   1. Backs up the compose file
#   2. Rewrites the image tag
#   3. Pulls, recreates, waits for the agent to answer on /ping
#   4. Rolls back to the previous version automatically on failure
#   5. Prunes dangling images only after a verified-good result

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
COMPOSE_DIR="${COMPOSE_DIR:-${HOME}/docker-compose-scripts/portainer_agent}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
CONTAINER="portainer_agent"
AGENT_PORT="9001"
# AGENT_HOST is read from the compose file's port binding in main(), so the
# same script works on every host. Set it in the environment to override.
AGENT_HOST="${AGENT_HOST:-}"

# Portainer server — used by --check to compare versions. Set it in the
# environment or in ${COMPOSE_DIR}/.env (gitignored), e.g.
#   PORTAINER_SERVER=https://<server-ip>:9443
[[ -f "${COMPOSE_DIR}/.env" ]] && . "${COMPOSE_DIR}/.env"
PORTAINER_SERVER="${PORTAINER_SERVER:-}"

VERIFY_RETRIES=15      # attempts
VERIFY_INTERVAL=2      # seconds between attempts

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'
C_YEL=$'\033[0;33m'; C_RST=$'\033[0m'

info() { printf '%s[*]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
err()  { printf '%s[!]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Version inspection
# ---------------------------------------------------------------------------

# Image tag of the container as it is running right now.
running_version() {
    docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null \
        | awk -F: '{print $NF}' || echo "not-running"
}

# Image tag currently written in the compose file.
compose_version() {
    grep -oP 'image:\s*portainer/agent:\K\S+' "$COMPOSE_FILE"
}

# Host IP the agent port is published on, e.g. "<lan-ip>:9001:9001".
# A bare "9001:9001" binds every interface, so loopback answers.
compose_agent_host() {
    local ip
    ip=$(grep -oP '^\s*-\s*"?\K[0-9.]+(?=:'"${AGENT_PORT}"':'"${AGENT_PORT}"')' "$COMPOSE_FILE" | head -n1 || true)
    [[ -z "$ip" || "$ip" == "0.0.0.0" ]] && ip="127.0.0.1"
    echo "$ip"
}

# Portainer server version, for match verification. Empty if unreachable.
server_version() {
    curl -sk --max-time 5 "${PORTAINER_SERVER}/api/status" 2>/dev/null \
        | grep -oP '"Version"\s*:\s*"\K[^"]+' || echo ""
}

# ---------------------------------------------------------------------------
# Health verification
#
# The agent serves TLS on 9001 with a self-signed cert and returns 204 on
# /ping. -k is required. This is the only meaningful liveness signal — the
# container's own health status is unusable (no shell in the image).
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
# Compose file mutation
# ---------------------------------------------------------------------------
set_compose_version() {
    local ver="$1"
    sed -i -E "s|(image:[[:space:]]*portainer/agent:)\S+|\1${ver}|" "$COMPOSE_FILE"
}

backup_compose() {
    local bak="${COMPOSE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$COMPOSE_FILE" "$bak"
    echo "$bak"
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
# Modes
# ---------------------------------------------------------------------------
mode_current() {
    printf 'Running:  %s\n' "$(running_version)"
    printf 'Compose:  %s\n' "$(compose_version)"
}

mode_check() {
    local run cmp srv
    run=$(running_version); cmp=$(compose_version); srv=$(server_version)

    printf 'Running agent:    %s\n' "$run"
    printf 'Compose file:     %s\n' "$cmp"
    printf 'Portainer server: %s\n' "${srv:-unreachable}"
    echo

    [[ -n "$PORTAINER_SERVER" ]] || { err "PORTAINER_SERVER not set — add it to ${COMPOSE_DIR}/.env"; return 1; }
    [[ -z "$srv" ]] && { err "Could not reach ${PORTAINER_SERVER} — check PORTAINER_SERVER"; return 1; }

    if [[ "$run" == "$srv" ]]; then
        ok "Versions match. No action needed."
    else
        err "MISMATCH — agent ${run} vs server ${srv}"
        printf '    Run: %s %s\n' "$0" "$srv"
    fi
}

mode_update() {
    local target="$1" prev bak

    prev=$(running_version)
    [[ "$prev" == "$target" ]] && info "Already running ${target} — recreating anyway to pick up compose changes"

    info "Updating agent: ${prev} -> ${target}"

    bak=$(backup_compose)
    ok "Compose backed up to $(basename "$bak")"

    set_compose_version "$target"

    info "Pulling portainer/agent:${target}"
    if ! docker compose pull; then
        cp "$bak" "$COMPOSE_FILE"
        die "Pull failed — compose file restored, container untouched"
    fi

    remove_orphan_if_unmanaged

    info "Recreating container"
    # Not bare: under set -e a failed `up` would exit before the rollback below.
    local up_ok=1
    docker compose up -d || up_ok=0

    info "Verifying agent is serving"
    if ((up_ok)) && verify_agent; then
        ok "Update complete — agent running ${target}"
        docker compose ps
        echo
        info "Pruning dangling images"
        docker image prune -f
        echo
        info "Confirm the endpoint is green in the Portainer UI before walking away."
    else
        if ((up_ok)); then
            err "Agent did not respond after $((VERIFY_RETRIES * VERIFY_INTERVAL))s — rolling back to ${prev}"
        else
            err "docker compose up failed — rolling back to ${prev}"
        fi
        echo "--- container logs -------------------------------------------"
        docker logs --tail 40 "$CONTAINER" 2>&1 || true
        echo "--------------------------------------------------------------"

        cp "$bak" "$COMPOSE_FILE"
        set_compose_version "$prev"
        docker compose up -d || true   # /ping below is the real verdict

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

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
main() {
    [[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: ${COMPOSE_FILE}"
    command -v curl >/dev/null || die "curl is required"
    cd "$COMPOSE_DIR"
    [[ -n "$AGENT_HOST" ]] || AGENT_HOST=$(compose_agent_host)

    case "${1:-}" in
        --current) mode_current ;;
        --check)   mode_check ;;
        "" | -h | --help)
            cat <<EOF
Usage: $(basename "$0") <version|--check|--current>

  <version>   Update the agent to that version (e.g. 2.39.1), verify, or roll back
  --check     Compare running agent against the Portainer server version
  --current   Show running and compose-file versions

The agent version must match the Portainer server. Run --check first.
EOF
            ;;
        -*) die "Unknown option: $1" ;;
        *)
            [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
                || die "Version must look like 2.39.1 (no 'latest' — see version policy in compose file)"
            mode_update "$1"
            ;;
    esac
}

main "$@"
