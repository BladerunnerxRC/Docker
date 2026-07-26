# SearXNG

![Docker Compose](https://img.shields.io/badge/deploy-docker%20compose-2496ED?logo=docker&logoColor=white)
![Portainer](https://img.shields.io/badge/managed%20by-portainer-13BEF9?logo=portainer&logoColor=white)
![SearXNG](https://img.shields.io/badge/app-searxng-3050ff)
![Valkey](https://img.shields.io/badge/cache-valkey-1E88E5)

Privacy-respecting metasearch engine, deployed as a two-service Portainer stack:
[docker-compose.yml](docker-compose.yml).

| Service | Image | Purpose |
| --- | --- | --- |
| `searxng` | `searxng/searxng:latest` | The metasearch engine and web UI, published on host port **8888** (container 8080). |
| `valkey` | `valkey/valkey:8-alpine` | Redis-compatible backend used by SearXNG for rate limiting and caching. Not exposed on the host; reached over the internal `searxng_net` bridge network. |

SearXNG waits for Valkey's healthcheck to pass before starting
(`depends_on: condition: service_healthy`).

## Deploy as a Portainer stack

1. **Stacks → Add stack**, name it `searxng`.
2. Paste [docker-compose.yml](docker-compose.yml) into the web editor (or point Portainer
   at this repository and use `SearXNG/docker-compose.yml` as the compose path).
3. Add the environment variables under **Environment variables**:

   | Variable | Required | Example | Notes |
   | --- | --- | --- | --- |
   | `SEARXNG_SECRET` | yes | output of `openssl rand -hex 32` | Secret key for the instance. The deploy intentionally fails with a clear error if unset. |
   | `SEARXNG_BASE_URL` | no | `https://search.example.lan/` | Public URL if served behind a reverse proxy. Defaults to `http://localhost:8888/`. |

4. **Deploy the stack**, then copy the limiter config in (see
   [Limiter / bot protection](#limiter--bot-protection)) and browse to `http://<host>:8888/`.

> [!IMPORTANT]
> `SEARXNG_SECRET` is required — the stack won't deploy without it. Don't skip step 4's
> limiter config copy either; the container starts fine without it, but bot protection
> stays on defaults until you do.

## Storage

All state lives in named volumes — no host paths to pre-create:

| Volume | Mounted at | Holds |
| --- | --- | --- |
| `searxng_config` | `/etc/searxng` | `settings.yml` and any other instance config. |
| `searxng_cache` | `/var/cache/searxng` | SearXNG's on-disk cache. |
| `searxng_valkey_data` | `/data` (valkey) | Valkey persistence (`--save 30 1` snapshots). |

The SearXNG entrypoint runs as root and fixes volume ownership itself on every start
(`chown -R searxng:searxng`), so no host-side permission setup is needed.

> [!TIP]
> If the container exits with
> `cp: can't create '/etc/searxng/settings.yml': Permission denied`, the stack is missing
> the `CHOWN`/`DAC_OVERRIDE` capabilities under `cap_add` — root without `DAC_OVERRIDE`
> cannot write into the searxng-owned config directory.

## Customization

A default `settings.yml` is generated in the `searxng_config` volume on first start.
To change engines, themes, or limiter behavior, edit it in place, e.g.:

```sh
docker exec -it searxng sh -c 'vi /etc/searxng/settings.yml'
docker restart searxng
```

The Valkey connection is already wired up via `SEARXNG_VALKEY_URL=valkey://valkey:6379/0`,
so the built-in limiter works out of the box.

## Limiter / bot protection

The limiter is force-enabled via `SEARXNG_LIMITER=true` in the compose file (environment
variables override `settings.yml`), and its tuning lives in [limiter.toml](limiter.toml).
What it's tuned for:

- **Trusted LAN** — `pass_ip = ['192.168.200.0/24']` gives LAN clients unrestricted
  access, including the JSON API (relevant for LLM/search integrations that would
  otherwise be classified as bots).
- **Strict for everyone else** — `link_token = true` requires clients to fetch a
  CSS-delivered token before `/search` is accepted, which blocks simple scripted
  scrapers. Token bookkeeping uses Valkey, which this stack already provides.
- **No public-instance passlist** — `pass_searxng_org = false`; the `check.searx.space`
  checker IPs have no business on a private instance.
- **No trusted proxies yet** — port 8888 is published directly, so only loopback is in
  `trusted_proxies`. See [Reverse proxy](#reverse-proxy) before putting traefik in front.

`limiter.toml` is **not** bind-mounted — `searxng_config` is a named volume, and Docker
bind mounts need a real path on the Docker host, which a Portainer-managed git checkout
doesn't reliably provide (Portainer runs as a container itself; relative paths from a git
stack only resolve to real host paths if the stack's environment has "relative path
volumes" set up, which requires bind-mounting a host directory into the Portainer
container — not worth it for one file).

> [!IMPORTANT]
> Copy the file into the volume after every deploy and after every edit to
> `limiter.toml`:
>
> ```sh
> docker cp limiter.toml searxng:/etc/searxng/limiter.toml
> docker restart searxng
> ```
>
> Skipping this doesn't break the container — `SEARXNG_LIMITER=true` still turns the
> limiter on with defaults — but you won't get the tuning above (LAN passlist, link
> token, etc.) until the file is copied in.

## Hardening

Matching the other stacks in this repo, both containers run with:

- `cap_drop: ALL` plus only the capabilities each service needs
  (`CHOWN`/`DAC_OVERRIDE` for SearXNG — its root entrypoint chowns the volumes to
  `searxng` (uid 977) and then writes `settings.yml` into that searxng-owned directory;
  `SETGID`/`SETUID`/`DAC_OVERRIDE` for Valkey)
- `no-new-privileges`
- memory limits (1 GB SearXNG, 256 MB Valkey) and reservations
- healthchecks (`/healthz` for SearXNG, `valkey-cli ping` for Valkey)
- json-file logging capped at 3 × 10 MB per container

## Reverse proxy

To put the instance behind the [traefik](../traefik/) / edge stack:

1. Attach the `searxng` service to the proxy network and remove the published `8888` port.
2. Set `SEARXNG_BASE_URL` to the public URL (e.g. `https://search.example.lan/`) so
   generated links and redirects use the right origin.
3. Uncomment the `172.16.0.0/12` entry in `trusted_proxies` in [limiter.toml](limiter.toml).

> [!WARNING]
> Don't skip step 3. Behind a proxy, every request arrives from the proxy's container
> IP — without a trusted proxy entry, the limiter can't see real client IPs and lumps all
> traffic into one rate-limit bucket (and `pass_ip` matching breaks too).
