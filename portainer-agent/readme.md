# Portainer Agent

The Portainer agent runs on each Docker host so the Portainer server can manage it. It listens
on port 9001 with TLS and a self-signed certificate.

This folder has two files:

| File                      | Purpose                                                        |
|---------------------------|----------------------------------------------------------------|
| `docker-compose.yml`      | The compose template. Its image tag is the version every host should run. |
| `sync-portainer-agent.sh` | Downloads that template from GitHub and redeploys the agent on a host. |

The list of hosts and their IPs is in `HOSTS.local.md`. That file is gitignored and exists only
on your own machine, because this repo is public.

## Rules for the compose file

- **Pin the image tag** to the Portainer server's version (`portainer/agent:2.45.2`, never
  `latest`). If the agent and server versions differ, the handshake fails and the endpoint
  goes offline in Portainer.
- **Bind the port to the host's LAN IP** on each host (`"<lan-ip>:9001:9001"`). The agent can
  control Docker on the whole host, so it should not listen on every interface. The template
  uses a bare `9001:9001` because the IP is different on every host. The sync script keeps
  each host's own binding.
- **Leave out the healthcheck.** `portainer/agent` is a scratch image with no shell, `wget` or
  `curl`, so any probe fails and the container reports unhealthy forever. Monitor
  `https://<host>:9001/ping` from outside instead. It returns HTTP 204, and the check has to
  skip certificate validation.
- **Leave out Watchtower labels.** If Watchtower updates the agent ahead of the server, the
  endpoint goes offline. Update it on purpose with the sync script.
- **`AGENT_SECRET` is optional.** If you set it in the host's `.env`, the Portainer server
  needs the same secret, or it can't connect.

## Setting up a host

Each host keeps its files in `~/portainer-agent/`. Hosts set up before this used
`~/docker-compose-scripts/portainer_agent/`. To move one of those, see
[Moving a host from the old directory](#moving-a-host-from-the-old-directory).

```bash
mkdir -p ~/portainer-agent
cd ~/portainer-agent
curl -fsSLO https://raw.githubusercontent.com/BladerunnerxRC/Docker/main/portainer-agent/sync-portainer-agent.sh
chmod 755 sync-portainer-agent.sh
```

Create a `.env` file in the same directory. The script needs the server URL to check the
version. `.env` files are gitignored, and Docker Compose ignores variables it doesn't use.

```bash
PORTAINER_SERVER=https://<server-ip>:9443
# AGENT_SECRET=<shared-secret>   # only if the server uses one
```

Then run the script. If there's no compose file yet, it does a first install:

```bash
./sync-portainer-agent.sh
```

After a first install, change the port line in `docker-compose.yml` to
`"<lan-ip>:9001:9001"` and run the script again with `--force` to apply it. Later syncs keep
that binding.

## Owner and permissions

Everything in `~/portainer-agent/` belongs to your own user, not root. Run the script as that
user, without `sudo`.

| Path                      | Owner         | Mode  | Why                                                    |
|---------------------------|---------------|-------|--------------------------------------------------------|
| `~/portainer-agent/`      | `$USER:$USER` | `755` | The script writes the compose file and backups here.   |
| `sync-portainer-agent.sh` | `$USER:$USER` | `755` | Executable. It has no secrets in it.                   |
| `docker-compose.yml`      | `$USER:$USER` | `644` | The script rewrites it on every sync.                  |
| `.env`                    | `$USER:$USER` | `600` | It can hold `AGENT_SECRET`, so only you can read it.   |

To set these, or to fix files that ended up owned by root:

```bash
cd ~/portainer-agent
sudo chown -R "$USER:$USER" .
chmod 755 . sync-portainer-agent.sh
chmod 644 docker-compose.yml
chmod 600 .env
```

The backups (`docker-compose.yml.bak.*`) get your umask, which is usually `644`.

**Docker access:** the script runs `docker` without `sudo`, so your user must be in the
`docker` group. Check with `id -nG | grep -w docker`. If it isn't, add it, then log out and back
in:

```bash
sudo usermod -aG docker "$USER"
```

Anyone in the `docker` group effectively has root on the host, so add only accounts that
already have admin rights.

**Why not `sudo`:** on Ubuntu, `sudo` sets `HOME` to `/root`. The script would then look in
`/root/portainer-agent`, find no compose file, and do a first install there with a bare
`9001:9001` binding. Any files it created would also be owned by root. If you have to use
`sudo`, pass the directory explicitly:
`sudo COMPOSE_DIR=/home/<user>/portainer-agent ./sync-portainer-agent.sh`.

## Moving a host from the old directory

The script handles the move. If `~/portainer-agent` has no compose file and
`~/docker-compose-scripts/portainer_agent/docker-compose.yml` exists, it copies that compose
file and its `.env` across before syncing, so the host keeps its LAN-IP binding. Set up the
new directory as for a new host, then run the script:

```bash
mkdir -p ~/portainer-agent
cd ~/portainer-agent
curl -fsSLO https://raw.githubusercontent.com/BladerunnerxRC/Docker/main/portainer-agent/sync-portainer-agent.sh
chmod 755 sync-portainer-agent.sh

./sync-portainer-agent.sh --dry-run   # reads the old directory, copies nothing
./sync-portainer-agent.sh
```

Docker Compose names a project after its directory, so the project changes from
`portainer_agent` to `portainer-agent`. The move always recreates the container, even if the
version hasn't changed, so that it joins the new project. The script reports that the existing
container belongs to project `portainer_agent` and removes it before recreating. That's
expected for this move.

The script doesn't delete the old directory. When the endpoint is green in Portainer, delete
it yourself. If you leave it, a `docker compose up` run from there later will collide with the
new container:

```bash
rm -rf ~/docker-compose-scripts/portainer_agent
```

## Updating to a new version

1. Check the server's version: `curl -sk https://<server-ip>:9443/api/status`.
2. Change the image tag in this folder's `docker-compose.yml`, then commit and push.
3. On each host, preview the change, then apply it:

   ```bash
   ./sync-portainer-agent.sh --dry-run
   ./sync-portainer-agent.sh
   ```

4. Confirm the endpoint is green in the Portainer UI.

`raw.githubusercontent.com` can serve the old file for a few minutes after a push. To get the
new one straight away, pass the commit SHA: `REF=<sha> ./sync-portainer-agent.sh`.

## sync-portainer-agent.sh

The script runs these steps:

1. Downloads `portainer-agent/docker-compose.yml` from GitHub and validates it with
   `docker compose config`.
2. Keeps the host's `<lan-ip>:9001:9001` binding from the current compose file.
3. Stops unless the tag is `X.Y.Z` and matches the Portainer server version.
4. Shows a diff, backs up the current file to `docker-compose.yml.bak.<timestamp>`, pulls the
   image and recreates the container.
5. Checks that the agent answers on `/ping` within 30 seconds.
6. Prunes dangling images, but only after the check passes.

If the pull fails, the script restores the compose file and leaves the container untouched. If
`docker compose up` fails or `/ping` doesn't answer, it restores the backup and recreates the
container from it. The previous image is still there, because nothing is pruned on failure.

If the compose file hasn't changed and the agent already runs that tag, the script exits
without touching anything.

| Option      | Effect                                                              |
|-------------|---------------------------------------------------------------------|
| `--dry-run` | Shows the diff and target version. Changes nothing.                 |
| `--force`   | Skips the server-version check, and recreates even if nothing changed. |

These environment variables override the defaults:

| Variable           | Default                                       |
|--------------------|-----------------------------------------------|
| `COMPOSE_DIR`      | `~/portainer-agent`                           |
| `LEGACY_DIR`       | `~/docker-compose-scripts/portainer_agent` (the old directory to move from) |
| `REPO`             | `BladerunnerxRC/Docker`                       |
| `REF`              | `main` (a branch, tag or commit SHA)          |
| `SRC_PATH`         | `portainer-agent/docker-compose.yml`          |
| `AGENT_HOST`       | the IP from the port binding, or `127.0.0.1`  |
| `PORTAINER_SERVER` | read from `.env` in `COMPOSE_DIR`             |

**Containers from other projects:** Docker Compose won't take over a container from another
compose project that has the same name. In that case `up` fails with
`Conflict. The container name "/portainer_agent" is already in use`. The other container might
have been started with `docker run`, from a different directory, or as a Portainer stack. Before
recreating, the script removes any `portainer_agent` container that isn't part of its own
compose project, and prints the project and directory the container came from. Retire that
project afterwards, or a later `up` from there will cause the same conflict.

## Troubleshooting an offline endpoint

The image has no shell, so `docker exec` doesn't work. Check from the host instead:

```bash
# Is it running, and which compose project owns it?
docker ps -a --filter name=portainer_agent \
  --format '{{.Status}}  {{.Image}}  {{.Label "com.docker.compose.project.working_dir"}}'

# More than one agent container means a duplicate from another project.
docker ps -a --format '{{.Names}}  {{.Image}}' | grep portainer/agent

# Does it answer? Expect 204.
curl -sk -o /dev/null -w '%{http_code}\n' https://<lan-ip>:9001/ping

# Does its version match the server?
./sync-portainer-agent.sh --dry-run

docker logs --tail 20 portainer_agent
```

The usual causes are a version mismatch with the server, a duplicate container from another
project, or the port bound to the wrong IP.

`.gitattributes` keeps `*.sh` files in LF line endings, because CRLF line endings break them on
Linux.
