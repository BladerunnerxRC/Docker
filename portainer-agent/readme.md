# Portainer Agent

Lets a Portainer server (`portainer.shome` / 192.168.200.98, `portainer-2.shome` / 192.168.200.14)
manage Docker on another host.

## Hosts

| Host           | IP              | Agent address          |
|----------------|-----------------|------------------------|
| optiplex-three | 192.168.200.65  | `192.168.200.65:9001`  |

## Install

1. Get the server version: Portainer UI (bottom-left), or on the server host
   `docker inspect portainer --format '{{.Config.Image}}'`.
2. On the target host:

   ```bash
   mkdir -p ~/portainer-agent && cd ~/portainer-agent
   # copy docker-compose.yaml here
   echo "AGENT_VERSION=2.27.3" > .env   # match the server version
   docker compose up -d
   docker logs portainer_agent          # expect "starting Agent API server"
   ```

3. If ufw is enabled: `sudo ufw allow from 192.168.200.0/24 to any port 9001 proto tcp`
4. Portainer UI → **Environments → Add environment → Docker Standalone → Agent**
   - Name: `optiplex-three`
   - Environment address: `192.168.200.65:9001`

## Upgrading

Bump `AGENT_VERSION` in `.env` whenever the server is upgraded, then `docker compose up -d`.

## Optional: AGENT_SECRET

Set `AGENT_SECRET` on **both** the agent and the Portainer server container, or neither —
a mismatch makes the server unable to connect.
