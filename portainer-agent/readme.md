# Portainer Agent

The Portainer agent runs on each Docker host so the Portainer server can manage it. It listens
on port 9001 with TLS and a self-signed certificate.

## Deployment on each host

Each host keeps its compose file and these scripts in `~/docker-compose-scripts/portainer_agent/`.
The list of hosts and their IPs is in `HOSTS.local.md`. That file is gitignored and exists only
on your own machine, because this repo is public.

The `docker-compose.yaml` in this folder is a generic template. The compose file deployed on a
host should differ from it in these ways:

- **Pin the image tag** (`portainer/agent:2.45.2`, never `latest`). The agent must run the same
  version as the server, or the handshake fails and the endpoint goes offline in Portainer.
- **Bind the port to the host's LAN IP** (`"<lan-ip>:9001:9001"`). The agent can control
  Docker on the whole host, so it should not listen on every interface.
- **Leave out the healthcheck.** `portainer/agent` is a scratch image with no shell, `wget` or
  `curl`, so any probe fails and the container reports unhealthy forever. Monitor
  `https://<host>:9001/ping` from outside instead. It returns HTTP 204, and the check has to
  skip certificate validation.
- **Leave out Watchtower labels.** If Watchtower updates the agent ahead of the server, the
  endpoint goes offline. Update it on purpose with the script below.

## Scripts

Copy the scripts to `~/docker-compose-scripts/portainer_agent/` on the host and make them
executable with `chmod +x *.sh`. The scripts are the same on every host. `.gitattributes` keeps
them in LF line endings, because CRLF line endings break them on Linux.

The scripts need the Portainer server URL to compare versions. Put it in a `.env` file in the
same directory. `.env` files are gitignored, and Docker Compose ignores variables it doesn't use.

```bash
PORTAINER_SERVER=https://<server-ip>:9443
```

### update-portainer-agent.sh

This script changes the agent version. It runs these steps:

1. Backs up `docker-compose.yml` to `docker-compose.yml.bak.<timestamp>`.
2. Rewrites the image tag.
3. Pulls the image and recreates the container.
4. Checks that the agent answers on `/ping`.
5. Prunes dangling images, but only after the check passes.

If the pull fails, the script restores the compose file and leaves the container untouched. If
`docker compose up` fails or the agent doesn't answer within 30 seconds, it rolls back to the
previous version.

```bash
./update-portainer-agent.sh --check     # running agent vs compose file vs Portainer server
./update-portainer-agent.sh --current   # running and compose-file versions only
./update-portainer-agent.sh 2.45.2      # update to that version (X.Y.Z only, no "latest")
```

Run `--check` first, and update to the version it reports for the server.

The script reads the agent's IP from the port binding in the compose file. A bare `9001:9001`
binding makes it use `127.0.0.1`. These environment variables override the defaults:

| Variable           | Default                                     |
|--------------------|---------------------------------------------|
| `COMPOSE_DIR`      | `~/docker-compose-scripts/portainer_agent`  |
| `AGENT_HOST`       | the IP from the compose file's port binding |
| `PORTAINER_SERVER` | read from `.env` in `COMPOSE_DIR`           |

**Containers from other projects:** Docker Compose won't take over a container from another
compose project that has the same name. In that case `up` fails with
`Conflict. The container name "/portainer_agent" is already in use`. The other container might
have been started with `docker run`, from a different directory, or as a Portainer stack. Before
recreating, the script removes any `portainer_agent` container that isn't part of its own
compose project, and prints the project and directory the container came from. Retire that
project afterwards, or a later `up` from there will cause the same conflict.

### portainer_agent_check.sh

This script prints a one-screen status: image, state, restart count, owning compose project,
docker socket mount, published port and the `/ping` result. It exits 0 when the agent answers
`/ping`, so other scripts can use it as a check.

```bash
./portainer_agent_check.sh
```

### diagnose_portainer.sh

This script runs a full diagnostic when an endpoint goes offline or the agent misbehaves:

- container state and the compose project that owns it
- every `portainer/agent` container on the host, which shows duplicates from other projects
- the healthcheck, with a warning if one is defined
- the mounts, and whether `/var/run/docker.sock` exists on the host
- the `/ping` result
- the agent version against the server version from `/api/status`
- disk space and memory
- the last 20 lines of the log

Everything runs from the host, because the image has no shell for `docker exec`.

```bash
./diagnose_portainer.sh
PORTAINER_SERVER=https://<server-ip>:9443 ./diagnose_portainer.sh   # without .env
```
