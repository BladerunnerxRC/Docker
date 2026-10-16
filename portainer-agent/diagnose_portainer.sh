#!/usr/bin/env bash
#
# diagnose_portainer.sh — full diagnostic for a misbehaving Portainer agent
#
# Usage:
#   ./diagnose_portainer.sh
#   PORTAINER_SERVER=https://<server-ip>:9443 ./diagnose_portainer.sh
#
# PORTAINER_SERVER can also live in .env next to this script (gitignored).
#
# Everything runs from the host. portainer/agent is a scratch image with no
# shell, ls or curl, so `docker exec` into it always fails.

set -uo pipefail

CONTAINER="${CONTAINER:-portainer_agent}"
AGENT_PORT="9001"
ENV_FILE="$(dirname "$(readlink -f "$0")")/.env"
[[ -f "$ENV_FILE" ]] && . "$ENV_FILE"
PORTAINER_SERVER="${PORTAINER_SERVER:-}"

fmt() { docker inspect "$CONTAINER" --format "$1" 2>/dev/null; }
section() { printf '\n=== %s ===\n' "$*"; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "Container ${CONTAINER} not found"
    exit 1
fi

section "Container"
echo "Image:    $(fmt '{{.Config.Image}}')"
echo "State:    $(fmt '{{.State.Status}} since {{.State.StartedAt}}, {{.RestartCount}} restart(s), exit code {{.State.ExitCode}}')"
echo "Project:  $(fmt '{{index .Config.Labels "com.docker.compose.project"}}')"
echo "Workdir:  $(fmt '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"

section "All agent containers on this host"
# More than one, or one under an unexpected project, means a second compose
# project or a Portainer stack is fighting for the name.
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}' \
    | grep 'portainer/agent' || echo "none"

section "Healthcheck"
hc=$(fmt '{{json .Config.Healthcheck}}')
if [[ -z "$hc" || "$hc" == "null" ]]; then
    echo "None defined (correct for this image)"
else
    echo "$hc"
    echo "WARNING: the image has no shell, so this probe can never pass and the"
    echo "         container will report unhealthy regardless. Remove it from compose."
fi

section "Mounts"
fmt '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{if .RW}}rw{{else}}ro{{end}}){{println}}{{end}}'
if [[ -S /var/run/docker.sock ]]; then
    echo "Host docker socket present"
else
    echo "Host docker socket MISSING at /var/run/docker.sock"
fi

section "Agent /ping"
addr=$(docker port "$CONTAINER" "${AGENT_PORT}/tcp" 2>/dev/null | head -n1)
addr="${addr/0.0.0.0/127.0.0.1}"
if [[ -z "$addr" ]]; then
    echo "Port ${AGENT_PORT} not published"
else
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://${addr}/ping" 2>/dev/null)
    echo "https://${addr}/ping -> HTTP ${code:-000} (expect 204)"
fi

section "Version match"
agent_ver=$(fmt '{{.Config.Image}}' | awk -F: '{print $NF}')
echo "Agent:    ${agent_ver}"
if [[ -z "$PORTAINER_SERVER" ]]; then
    server_ver=""
    echo "Server:   PORTAINER_SERVER not set (env or ${ENV_FILE})"
else
    server_ver=$(curl -sk --max-time 5 "${PORTAINER_SERVER}/api/status" 2>/dev/null \
        | grep -oP '"Version"\s*:\s*"\K[^"]+')
    echo "Server:   ${server_ver:-unreachable at ${PORTAINER_SERVER}}"
fi
if [[ -n "$server_ver" && "$agent_ver" != "$server_ver" ]]; then
    echo "MISMATCH — run ./update-portainer-agent.sh ${server_ver}"
fi

section "Host resources"
df -h / /var/lib/docker 2>/dev/null
echo
free -m

section "Container logs (last 20 lines)"
docker logs --tail 20 "$CONTAINER" 2>&1
