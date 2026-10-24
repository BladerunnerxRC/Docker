# Portainer Agent — Session Handoff

> State as of 2026-10-23. Read this first, then continue from "Next steps".
> Reference material (compose rules, setup, permissions, script behaviour, troubleshooting)
> lives in [`readme.md`](readme.md); this file records only state, decisions and open items.
> Host IPs, server URLs and per-host `.env` values live in the gitignored
> `HANDOFF.local.md` next to this file (local only — not in the public repo).

## Working style
- Professional, clear, concise. When asked for clarification, answer at an 11th-grade reading level.
- Direct and technical; no sugar-coating. Check work before delivering.
- Scripts: ask for diagnostics/logs before proposing fixes; iterate run → logs → fix.
- Suggest continued improvements to code.
- Changes to `main` go through a PR (branch protection). Branch names: `dev-…` / `fix-…` (see `CLAUDE.md`).
- Claude has no SSH access to the hosts: the user runs commands and pastes output. The admin
  workstation can reach both Portainer servers and the agents' `/ping` over the LAN.

## Goal
Every Docker host runs a Portainer agent whose version matches the Portainer server that manages
it, deployed from one compose template in this repo, updated on purpose (never `latest`, never
Watchtower), and verifiable from outside.

## How it works now
- **Template:** [`docker-compose.yml`](docker-compose.yml) on `main`. Its image tag is the version
  every host should run. Currently `portainer/agent:2.45.3`.
- **Deploy/update:** [`sync-portainer-agent.sh`](sync-portainer-agent.sh), run on each host from
  `~/portainer-agent/`. It downloads the template from `main`, keeps the host's
  `<lan-ip>:9001:9001` binding, refuses a tag that isn't `X.Y.Z` or doesn't match
  `PORTAINER_SERVER`'s `/api/status`, then pulls, recreates, checks `/ping`, and rolls back on failure.
- **Per-host config:** `~/portainer-agent/.env` with `PORTAINER_SERVER` (required) and
  `AGENT_SECRET` (optional). Owner = the user, `.env` mode `600`.
- **Old layout:** hosts used `~/docker-compose-scripts/portainer_agent/` with
  `update-portainer-agent.sh`, `portainer_agent_check.sh` and `diagnose_portainer.sh`. Those
  scripts were removed in `2032228` (recoverable from `1974d11`). The sync script moves a host
  from the old directory on its first run; it never deletes the old directory.

## Environment
Two **independent** Portainer Business Edition servers, both on **2.45.3** — intentional.

| Server host | How it's reached | Manages |
|---|---|---|
| optiplex-two | Publishes **9000 only** (HTTP). HTTPS runs on 9443 inside the container but is deliberately not published; TLS is provided by Traefik at `https://portainer-2.shome` (`traefik/dynamic/30-services.yml`). Container `portainer-2--ee`. | optiplex-two (local socket), smiddleware (agent) |
| optiplex-docker | Publishes 9443 (HTTPS), 9000 (HTTP), 8000 (Edge tunnel, unused). Traefik: `https://portainer.shome`. | optiplex-three (agent); others not yet inventoried |

A host's `PORTAINER_SERVER` must point at the server that lists it as an endpoint. URLs are in
`HANDOFF.local.md`.

## Host status

| Host | Directory | Agent | State / blocker |
|---|---|---|---|
| optiplex-three | `~/portainer-agent` | 2.45.2 (synced 2026-10-16) | Needs a re-sync to 2.45.3. Port binding is bare `9001:9001` (listens on every interface). `.env` still has the unused `AGENT_VERSION=` line. |
| smiddleware | `~/portainer-agent` (compose copied from old dir 2026-10-23) | 2.45.2 — shown as **Outdated** in Portainer | Sync stopped: `.env` had `PORTAINER_SERVER` pointing at optiplex-two over `https:9443`, which isn't published. Fix to the HTTP URL, re-run. Old dir still present. |
| optiplex-two | n/a | — | Server host; its own endpoint uses the local socket, no agent needed for its own server. |
| optiplex-docker | n/a | — | Server host. Unknown whether it runs an agent for the other server. |

## Decisions made
- **Pin the tag; never `latest`.** Agent/server version mismatch breaks the handshake and the
  endpoint goes offline. The script enforces `X.Y.Z` and the server match (`--force` overrides).
- **GitHub is the source of truth.** Editing the compose file on a host is pointless — the next
  sync overwrites it. Bump the tag on `main` (via PR), then sync each host.
- **Bind the agent to the host's LAN IP**, not `0.0.0.0`. The template keeps a bare `9001:9001`
  because the IP differs per host; the script preserves each host's binding.
- **No healthcheck** (scratch image, no shell) and **no Watchtower labels**. Monitor
  `https://<host>:9001/ping` externally (HTTP 204, skip cert validation).
- **Directory moved** to `~/portainer-agent`. Compose names the project after the directory, so
  moved hosts get project `portainer-agent`; the first sync after the move removes the container
  from the old `portainer_agent` project and recreates it.
- **Port 9443 on optiplex-two stays unpublished.** HTTPS goes through Traefik; the sync script only
  reads `/api/status`, so the HTTP URL is fine for it.
- **Compose filename is `.yml`** (template renamed from `.yaml` to match the script and hosts).

## Next steps
1. **smiddleware:** set `PORTAINER_SERVER` to the optiplex-two HTTP URL (see local file), run
   `./sync-portainer-agent.sh --dry-run`, then apply. Confirm green in Portainer, then
   `rm -rf ~/docker-compose-scripts/portainer_agent`.
2. **optiplex-three:** run the sync to go 2.45.2 → 2.45.3. Optionally change its port line to
   `"<lan-ip>:9001:9001"` first, and delete the stale `AGENT_VERSION=` line from `.env`.
3. **Template decisions (open):**
   - Add a `logging:` block (`json-file`, `max-size: 10m`, `max-file: 3`). smiddleware's old file
     had it; the template doesn't, so a sync currently **drops log rotation**.
   - Keep or drop `- /:/host`. It's only needed for Portainer's host file browser; smiddleware's
     old file deliberately left it out, and a sync **adds** it.
4. **Inventory the rest:** check every other Docker host for an agent and for the old
   `~/docker-compose-scripts/portainer_agent` directory; record which server manages it.
5. **Shared tag vs two servers:** both servers must be upgraded together, or hosts of the
   lagging server will refuse to sync. If that becomes a problem, add a per-server tag override
   to the script (e.g. `AGENT_VERSION` in `.env` taking precedence over the template tag).

## Improvements offered, not done
- Script: `chmod 600 .env` after copying it from the old directory (`cp -p` keeps the old mode).
- optiplex-two: firewall port 9000 so only the Traefik host (and sync hosts, if they use the
  direct URL) can reach it — today anyone on the LAN can bypass Traefik and log in over HTTP.
- optiplex-two gets its address from DHCP; a reservation would protect Checkmk's agent
  registration and allowlists that are tied to it.

## Gotchas
- `raw.githubusercontent.com` caches for a few minutes after a push; use `REF=<commit-sha>`.
- Don't run the script with `sudo`: on Ubuntu `HOME` becomes `/root` and it does a first install
  in `/root/portainer-agent`. If you must, pass `COMPOSE_DIR=/home/<user>/portainer-agent`.
- `REF`, `REPO`, `SRC_PATH`, `COMPOSE_DIR` don't work from `.env` (read before `.env` loads); pass
  them on the command line.
- The script uses `grep -P`. Fine on Ubuntu; Git Bash on Windows needs `LC_ALL=C.UTF-8` for
  local testing with stubbed `docker`/`curl`.
- A 0-byte `sync-portainer-agent.sh` runs silently and does nothing — check `ls -l` if there's no
  output.
- Local `main` on the admin workstation has a duplicate commit (`4880d3c`, the 2.45.3 bump that
  also landed on `origin/main` as `2c29fe7`) and is behind; reset it to `origin/main` before
  branching from it.
