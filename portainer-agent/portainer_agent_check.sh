#!/usr/bin/env bash
#
# portainer_agent_check.sh — one-screen status of the local Portainer agent
#
# Usage:
#   ./portainer_agent_check.sh
#
# Exits 0 if the agent answers on /ping, 1 otherwise, so it can gate other
# scripts. For a deeper look use diagnose_portainer.sh.

set -uo pipefail

CONTAINER="${CONTAINER:-portainer_agent}"
AGENT_PORT="9001"

fmt() { docker inspect "$CONTAINER" --format "$1" 2>/dev/null; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "Container ${CONTAINER} not found"
    exit 1
fi

# Published address, e.g. "<lan-ip>:9001". 0.0.0.0 means every
# interface, so loopback answers.
addr=$(docker port "$CONTAINER" "${AGENT_PORT}/tcp" 2>/dev/null | head -n1)
addr="${addr/0.0.0.0/127.0.0.1}"

echo "Image:    $(fmt '{{.Config.Image}}')"
echo "State:    $(fmt '{{.State.Status}} since {{.State.StartedAt}}, {{.RestartCount}} restart(s)')"
echo "Project:  $(fmt '{{index .Config.Labels "com.docker.compose.project"}} ({{index .Config.Labels "com.docker.compose.project.working_dir"}})')"
echo "Socket:   $(fmt '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}{{.Source}}{{end}}{{end}}')"
echo "Port:     ${addr:-not published}"

[[ -n "$addr" ]] || exit 1

# The agent serves TLS with a self-signed cert and returns 204 on /ping.
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://${addr}/ping" 2>/dev/null)
echo "Ping:     HTTP ${code:-000}"
[[ "$code" == "204" || "$code" == "200" ]]
