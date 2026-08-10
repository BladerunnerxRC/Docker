<h1 align="center">Traefik Proxy Admin</h1>

<p align="center">
  <em>A web UI for your routing table — bolted onto the Traefik you already run, not a second one.</em>
</p>

<p align="center">
  <img alt="Traefik Proxy Admin v0.2.2" src="https://img.shields.io/badge/traefik--proxy--admin-v0.2.2-24A1C1?style=for-the-badge&logo=traefikproxy&logoColor=white">
  <img alt="PostgreSQL 16" src="https://img.shields.io/badge/PostgreSQL-16-4169E1?style=for-the-badge&logo=postgresql&logoColor=white">
  <img alt="Docker Compose" src="https://img.shields.io/badge/Docker_Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white">
  <img alt="Portainer" src="https://img.shields.io/badge/Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white">
  <img alt="AGPL-3.0" src="https://img.shields.io/badge/upstream-AGPL--3.0-A42E2B?style=for-the-badge">
</p>

A Portainer stack running [Janhouse/traefik-proxy-admin](https://github.com/Janhouse/traefik-proxy-admin)
— a panel for creating Traefik routers, services and middlewares from a web form
instead of hand-editing YAML — plus the PostgreSQL instance that stores them.

It **sits beside** the [traefik](../traefik/) stack. It does not run Traefik, bind
`:80`/`:443`, touch `traefik/dynamic/`, or interfere with the
[D&R sync scripts](../traefik/README.md#dr-scripts-deploy--recover). Your existing
Traefik picks up the panel's routes by polling it over the **HTTP provider**, as a
third config source alongside the file and Docker providers it already uses.

---

## Contents

| | Section | |
|---|---|---|
| 🏗️ | [Architecture](#architecture) | How the pieces fit together |
| 🔀 | [What changed vs. upstream](#what-changed-vs-upstream) | Why this file differs from the project's example |
| 📋 | [Requirements](#requirements) | What must exist first |
| ⚙️ | [Environment variables](#environment-variables) | Stack configuration |
| 🚀 | [Deploying in Portainer](#deploying-in-portainer) | Getting the stack up |
| 🔌 | [Wiring it into your existing Traefik](#wiring-it-into-your-existing-traefik) | **The one edit outside this folder** |
| 🧭 | [First-run setup](#first-run-setup) | Four settings that decide whether routes work |
| 🤝 | [Coexistence rules](#coexistence-rules) | Sharing a proxy with the file provider |
| 🔒 | [Security](#security) | The panel has no login |
| 💾 | [Backups & restore](#backups--restore) | Where the state lives |
| 🔧 | [Maintenance & upgrades](#maintenance--upgrades) | Keeping it healthy |
| 🩺 | [Troubleshooting](#troubleshooting) | When something breaks |

---

## Architecture

```mermaid
flowchart TB
    subgraph lan["LAN — 192.168.200.0/24"]
        browser["Browser<br/><code>tpadmin.shome</code>"]
        client["Any client<br/><code>*.shome</code>"]
    end

    subgraph edge["edge network — existing traefik stack"]
        traefik["<b>traefik</b><br/>:80 :443 :8082"]
    end

    subgraph this["TraefikAdmin stack — this folder"]
        panel["<b>traefik-proxy-admin</b><br/>Next.js UI + API :3000"]
        db[("<b>postgres 16</b><br/>routes, domains,<br/>sessions")]
    end

    filecfg[/"traefik/dynamic/*.yml<br/>file provider"/]
    dockercfg[/"container labels<br/>docker provider"/]

    browser -->|"HTTPS + BasicAuth"| traefik
    client -->|HTTPS| traefik
    traefik -->|"routes to :3000"| panel
    traefik -.->|"HTTP provider<br/>polls /api/traefik/config<br/>every 10s"| panel
    panel <-->|"tpadmin-back<br/>internal only"| db
    filecfg -.->|watch| traefik
    dockercfg -.->|socket| traefik

    classDef net fill:#0B4F6C,stroke:#01BAEF,color:#fff
    classDef app fill:#1B3A4B,stroke:#24A1C1,color:#fff
    classDef store fill:#2D3142,stroke:#4169E1,color:#fff
    classDef cfg fill:#3D2C2E,stroke:#C97B84,color:#fff
    class traefik,panel app
    class db store
    class filecfg,dockercfg cfg
```

Two config paths reach Traefik, and they never touch each other:

| Path | Source of truth | Changed by | Applied |
| --- | --- | --- | --- |
| **File provider** | `traefik/dynamic/*.yml` in git | `edge-sync-traefik-dynamic` | On file write (watched) |
| **HTTP provider** | PostgreSQL in this stack | The web UI | Next poll, ≤10s |

`rsync --delete` in the D&R script only ever sees `dynamic/`, so it cannot delete a
route created in the panel — and the panel cannot overwrite a hand-written YAML route.
That separation is the main reason this stack uses the HTTP provider rather than
writing files into the watched directory.

---

## What changed vs. upstream

Upstream ships [`docker.compose.example.yml`](https://github.com/Janhouse/traefik-proxy-admin/blob/main/docker.compose.example.yml)
for a stack that owns its own proxy and uses authentik for auth. Deployed as-is here it
would fail at `docker compose up`. Every deviation:

| Upstream | This stack | Why |
| --- | --- | --- |
| `networks: traefik` (external) | `networks: edge` (external) | That is what the traefik stack actually creates. |
| App on a `192.168.212.0/24` bridge shared with Postgres | Separate `tpadmin-back`, `internal: true` | `192.168.212.0/24` risks colliding with the LAN; `internal` removes the DB's gateway entirely. |
| `middlewares=security@file, base@file, auth-traefik@docker` | `tpadmin-ipallow@docker, tpadmin-auth@docker, security-headers@file, compression@file` | None of the upstream middleware names exist here. A router referencing a missing middleware is dropped with a `middleware does not exist` error. |
| authentik forward-auth (`outpost.goauthentik.io` router) | BasicAuth against the existing `.htpasswd` + IP allowlist | No authentik on this network. See [Security](#security). |
| `tls.domains[0].main` / `sans` wildcard labels | `tls.certresolver=stepca` | The step-ca resolver issues per-host certs via `tlsChallenge`; no wildcard is requested. |
| `image: ...:latest` | `image: ...:v0.2.2` | A `latest` pull that changes the config schema rewrites your routing table unattended. |
| Watchtower + promtail labels | dropped | Not used in this repo. |
| No resource limits, no `cap_drop` | Limits, `cap_drop: ALL`, `read_only` | House style — see [Manyfold3D](../Manyfold3D/docker-compose.yml). |

> [!NOTE]
> Upstream's README shows the Traefik provider block as `providers.http.endpoints` (a
> plural list). Traefik v3 takes **`endpoint`, singular**. Copying upstream's snippet
> verbatim makes Traefik fail to start on its static config. The block in
> [Wiring it into your existing Traefik](#wiring-it-into-your-existing-traefik) is correct.

---

## Requirements

- The [traefik](../traefik/) stack running, which provides the external `edge` network.
- A DNS record for `tpadmin.shome` pointing at the Traefik host, added in
  [AdGuard Home](../AdGuard/) alongside your other `*.shome` names.
- At least one user in `/opt/netlab-stack/traefik/auth/.htpasswd` (already mounted into
  the Traefik container). To add one:

  ```bash
  htpasswd -B /opt/netlab-stack/traefik/auth/.htpasswd tpadmin
  ```

  Traefik re-reads the usersfile on change; no restart needed.
- Write access to `/opt/netlab-stack/traefik/traefik.yml` and the ability to restart
  Traefik once — see [Wiring](#wiring-it-into-your-existing-traefik).

No host directories to pre-create. All state lives in the `tpadmin_db_data` named volume.

> [!NOTE]
> **No free host port required.** This stack publishes nothing. The `3000` in the compose
> file is the container's own listener, reached by Traefik over `edge` at
> `traefik-proxy-admin:3000` — a different address from `0.0.0.0:3000` on the host, which
> [AdGuard Home already owns](../traefik/docker_compose.yaml). The two cannot collide.
>
> Do **not** try to move the app off 3000 with the `PORT` variable to "free it up": the
> image's built-in `HEALTHCHECK` hardcodes `http://localhost:3000/api/health`, so the
> container would go permanently unhealthy while working fine. If you want direct host
> access for debugging, map a spare host port instead — see below.

---

## Environment variables

Full template with the reasoning inline: [.env.example](.env.example).

| Variable | Default | Purpose |
| --- | --- | --- |
| `BASE_DOMAIN` | `shome` | Must match the traefik stack. |
| `CERTRESOLVER` | `stepca` | Resolver for the panel's own cert. Per-route resolvers are set in the UI. |
| `TPADMIN_HOST` | `tpadmin` | Panel is published at `<TPADMIN_HOST>.<BASE_DOMAIN>`. |
| `TPADMIN_ALLOWLIST` | `192.168.200.0/24,192.168.0.0/16` | Source CIDRs allowed to reach the panel. |
| `POSTGRES_DB` | `traefik_admin` | Database name. |
| `POSTGRES_USER` | `tpadmin` | Database role. |
| `POSTGRES_PASSWORD` | — | **Alphanumeric only.** See below. |
| `DB_CONNECTION_LIMIT` | `10` | Connection pool size. |
| `TZ` | `America/New_York` | Container timezone. |

> [!CAUTION]
> `POSTGRES_PASSWORD` is substituted into a connection **URL**
> (`postgresql://user:PASSWORD@host:5432/db`), so it passes through two layers that
> both read punctuation as syntax and both fail misleadingly:
>
> - **`$`** — Compose and Portainer interpolate before Docker sees the value.
>   `Ab#$Cd1234` becomes `Ab#`, because `$Cd1234` is an undefined variable.
> - **`@ : / ? # &`** — structural in a URL. An `@` splits userinfo from host, so the
>   app tries to resolve whatever follows it and reports a DNS failure that says
>   nothing about the password.
> - **`%`** — starts a percent-escape; a stray `%2` is a malformed sequence.
>
> Use a long `A-Za-z0-9` string. Length beats symbol soup.

---

## Deploying in Portainer

1. **Stacks → Add stack → Repository** (or Web editor, pasting
   [docker-compose.yml](docker-compose.yml)).
2. Set the environment variables from the table above under **Environment variables**.
   Do not commit a real `.env` — it is gitignored.
3. **Deploy the stack.**

The app runs its own schema migrations on boot (`instrumentation.ts` → `drizzle migrate`),
so there is no manual `db:push` step despite what upstream's README implies. First boot
logs should show:

```text
Traefik Configurator version: <build id>
Running database migrations
```

Verify both containers are healthy, then browse to `https://tpadmin.shome/` and
authenticate with your `.htpasswd` credentials.

> [!IMPORTANT]
> The panel is reachable now, but **no route it creates will work yet.** Traefik does
> not know the panel exists until you complete the next section.

### Optional: a host port for debugging

Nothing in normal operation needs this. It also **bypasses every access control on this
stack** — no IP allowlist, no BasicAuth, and the app has no login of its own — so a
published port hands full routing-table CRUD to anything that can reach the host.

If you need it temporarily, map a free host port (3000 is AdGuard's) and remove it when
you are done:

```yaml
    # under the traefik-proxy-admin service
    ports:
      - "3010:3000"   # host 3010 -> container 3000
```

---

## Wiring it into your existing Traefik

This is the only change outside this folder, and it is deliberately left for you to
apply — it edits the live edge proxy's **static** configuration, which requires a
Traefik restart to take effect.

### 1. Add the HTTP provider

Edit `/opt/netlab-stack/traefik/traefik.yml` on the Docker host, and make the identical
change to [traefik/traefik.yml](../traefik/traefik.yml) in this repo so the two stay in
sync:

```diff
 providers:
   docker:
     exposedByDefault: false
   file:
     directory: /etc/traefik/dynamic
     watch: true
+  http:
+    endpoint: "http://traefik-proxy-admin:3000/api/traefik/config"
+    pollInterval: "10s"
+    pollTimeout: "5s"
```

Traefik resolves `traefik-proxy-admin` by container name over the shared `edge` network.
It polls the container **directly on port 3000**, bypassing its own routers — so the
BasicAuth and IP-allowlist middlewares do not apply to this call, and do not need to.

### 2. Restart Traefik

```bash
docker restart traefik
```

> [!TIP]
> Order does not matter. If Traefik starts while the panel is down, the HTTP provider
> logs a poll failure and contributes nothing; the file and Docker providers are
> unaffected and every existing route keeps working. A poll that fails *later* does not
> clear routes already published — Traefik keeps the last configuration it received.

### 3. Verify

The panel's routers appear under the `http` provider. Adapting the checks from
[traefik/README.md](../traefik/README.md#verification-cheatsheet):

```bash
# Routers contributed by the panel (empty until you add a service in the UI)
curl -ks https://traefik.shome/api/http/routers \
| jq 'map(select(.provider=="http")) | map({name, rule, service, status})'

# Provider is alive: this should NOT be empty once a service exists
curl -ks https://traefik.shome/api/http/routers | jq -r '.[].provider' | sort -u
```

You can also read exactly what Traefik is being served:

```bash
docker exec traefik wget -qO- http://traefik-proxy-admin:3000/api/traefik/config | jq
```

---

## First-run setup

Four settings decide whether generated routes work at all. Three live in the UI's global
config, one per domain.

| Setting | Set it to | Consequence if wrong |
| --- | --- | --- |
| **Default entrypoint** | `websecure` | Empty means routers get no `entryPoints`, so Traefik attaches them to *every* entrypoint — including `:8082`, which serves the API. |
| **Admin panel domain** | `traefik-proxy-admin:3000` | Used as the forward-auth address for protected services and as the upstream for the panel's own generated router. Traefik is the only caller, so a container-reachable address is what matters. The default `localhost:3000` points Traefik at itself. |
| **Default enable duration** | *Forever* (see warning) | Routes silently stop working after 12 hours. |
| **Cert resolver** (per domain) | `stepca` | No resolver means no certificate; clients get Traefik's default self-signed cert and a browser warning. |

Then add a domain (`shome`, resolver `stepca`) and your first service.

> [!WARNING]
> **Routes expire after 12 hours by default.** `defaultEnableDurationMinutes` ships as
> `720`, and a scheduler disables expired services every 10 seconds — plus on every
> config poll. For permanent homelab routes, set the global default to *forever*
> (no duration), or set the duration explicitly per service. The symptom is a route
> that works all afternoon and 404s the next morning with nothing in the Traefik logs,
> because from Traefik's point of view the router was simply withdrawn.
>
> The expiry clock starts at `enabledAt`, so re-enabling a service in the UI restarts it.

---

## Coexistence rules

Three providers now feed one Traefik. What that does and does not mean:

**Names cannot collide.** Traefik namespaces by provider — `komga@file`, `tpadmin@docker`
and `komga@http` are three distinct routers even with identical names. You never have to
avoid a name.

**Rules absolutely can collide.** Two routers matching the same `Host()` on the same
entrypoint is undefined-ish behaviour: Traefik picks by priority, and priority defaults to
rule length, so two identical rules are a coin flip that can change on restart. Before
publishing a hostname in the panel, check it is not already claimed in
[traefik/dynamic/20-routers.yml](../traefik/dynamic/20-routers.yml) or by a container
label. Currently claimed: `traefik`, `dns`, `whoami`, `dockhand`, `haos`, `komga`,
`manyfold3d`, `portainer`, `portainer-2`, `porttracker`, `webmin-mid`, `webmin-opti`,
`webmin-optiplex-two`, `borg-optiplex-docker`, `wud`.

Your own duplicate detector already covers this:

```bash
curl -ks https://traefik.shome/api/http/routers \
| jq 'map({name,provider,rule,service}) | group_by(.rule) | map(select(length>1))'
```

**The `k3s-catchall` router does not eat panel routes — by design.** It matches
`HostRegexp({name:[a-z0-9-]+}.shome)`, i.e. *every* single-label `.shome` host, but it is
pinned to `priority: 10`. A plain ``Host(`x.shome`)`` rule gets a default priority equal
to its rule length (~20+), so it wins. Do not remove that explicit priority, and do not
give panel-generated routers a priority below 10.

**Middlewares cross providers.** Routes created in the panel can reference
`security-headers@file` and `compression@file` by name — add them under *global
middlewares* in the UI to apply them everywhere. The `@file` suffix is required.

**D&R is unaffected.** `edge-sync-traefik-dynamic` reads the repo and writes
`/opt/netlab-stack/traefik/dynamic/`. Panel routes live in Postgres and arrive over HTTP.
Neither can clobber the other, and a rollback of the dynamic config leaves panel routes
untouched.

---

## Security

> [!CAUTION]
> **The panel has no built-in authentication.** There is no login page, no admin
> password, and no root `middleware.ts` in the upstream app — that is why upstream fronts
> it with authentik. Anyone who reaches port 3000 gets full CRUD over your routing table:
> they can point any `*.shome` hostname at any address, or expose an internal host.
> The `tpadmin-ipallow` + `tpadmin-auth` middlewares in this stack are the *entire*
> access control. Do not remove them, and do not publish port 3000 to the host.

What this stack does about it:

| Control | Effect |
| --- | --- |
| `tpadmin-ipallow` | Rejects sources outside `TPADMIN_ALLOWLIST` before authentication. |
| `tpadmin-auth` | BasicAuth against the `.htpasswd` Traefik already mounts. `removeheader=true` stops credentials leaking upstream to the app. |
| No published ports | Nothing on the host or LAN reaches `:3000` or `:5432` directly. |
| `internal: true` on `tpadmin-back` | Postgres has no route off the host in either direction. |
| Own middleware names | `tpadmin-*` rather than borrowing `traefik-auth@docker` from the traefik stack, whose redeploy would otherwise drop auth from this router without warning. |
| `cap_drop: ALL`, `read_only`, `no-new-privileges` | Container runs as uid 1001 with no capabilities and no writable filesystem beyond two tmpfs mounts. |

Residual exposure worth knowing about:

- **`/api/traefik/config` is unauthenticated** and returns your full generated routing
  table. Any container on the shared `edge` network can read it. That is inherent — the
  Traefik HTTP provider sends no credentials — but it means `edge` should be treated as
  a trusted network, not a dumping ground.
- **`api.insecure: true` in [traefik/traefik.yml](../traefik/traefik.yml)** publishes the
  Traefik API on host port `8082` with no auth, which also exposes the config the panel
  generates. Unrelated to this stack, but it widens the same blast radius.

---

## Backups & restore

Everything the panel knows lives in the `tpadmin_db_data` volume. Losing it loses every
route you created in the UI — they are **not** in git, unlike `traefik/dynamic/`.

> [!NOTE]
> Compose prefixes the real volume name with the project, so in Portainer it appears as
> `<stackname>_tpadmin_db_data`. The commands below go through `docker exec` and are
> unaffected; anything that addresses the volume directly needs the full name from
> `docker volume ls | grep tpadmin`.

Dump:

```bash
docker exec traefik-proxy-admin-db \
  pg_dump -U tpadmin -d traefik_admin --clean --if-exists \
| gzip > tpadmin-$(date +%F).sql.gz
```

Restore into a fresh stack:

```bash
gunzip -c tpadmin-2026-08-10.sql.gz \
| docker exec -i traefik-proxy-admin-db psql -U tpadmin -d traefik_admin
```

To fold this into [Borg](../borg-backup/), write the dump to the staged appdata path from
a pre-backup hook, the same pattern as
[KodiDB's `borg-prep-kodidb.sh`](../KodiDB/borg-prep-kodidb.sh). A volume-level snapshot
of a running Postgres is crash-consistent at best; prefer the dump.

---

## Maintenance & upgrades

**Upgrading the app.** Bump the tag in [docker-compose.yml](docker-compose.yml) and
redeploy. Migrations run automatically on boot. Current pin:

```text
ghcr.io/janhouse/traefik-proxy-admin:v0.2.2
sha256:7a86202ab3855f09ef5a8b97350306917114efaba7c3dc04b6eb13fdddea9496
```

Published tags: `v0.2`, `v0.2.1`, `v0.2.2`, `latest`. Take a dump before upgrading — the
migrations are one-way.

**Rotating the database password.** The `POSTGRES_*` variables are only read when the
data volume is first created. Changing them later updates the app's `DATABASE_URL`
but not the server, and the app fails authentication. Rotate both:

```bash
docker exec -it traefik-proxy-admin-db \
  psql -U tpadmin -d traefik_admin -c "ALTER USER tpadmin WITH PASSWORD 'newAlphanumericValue';"
```

then update the stack variable and redeploy.

**Postgres major upgrades.** `postgres:16-alpine` is pinned deliberately. Moving to 17
requires `pg_upgrade` or a dump/restore cycle — a bare tag bump leaves the container
crash-looping on `incompatible data directory version`.

---

## Troubleshooting

| Symptom | Subsystem | Likely cause |
| --- | --- | --- |
| 🔴 Traefik fails to start after the wiring edit | Static config | `endpoints:` (plural) instead of `endpoint:`. Traefik v3 rejects the unknown key. |
| 🔴 `tpadmin.shome` → connection refused / NXDOMAIN | DNS | No AdGuard record for `tpadmin.shome`. |
| 🔴 App crash-loops immediately, `EROFS` in logs | Container | `read_only: true` with a write path not covered by the tmpfs mounts. Remove `read_only` and both `tmpfs` lines to confirm. |
| 🟠 App healthy but every page errors | Database | `DATABASE_URL` mangled by a punctuation character in the password. Check with `docker exec traefik-proxy-admin env \| grep DATABASE_URL`. |
| 🟠 `getaddrinfo ENOTFOUND` naming part of your password | Database | An `@` in `POSTGRES_PASSWORD` split the URL. Use alphanumerics. |
| 🟠 Panel loads, routes never appear in Traefik | HTTP provider | Provider not added, or Traefik not restarted since. Check `docker exec traefik wget -qO- http://traefik-proxy-admin:3000/api/traefik/config`. |
| 🟠 **Routes work, then 404 the next day** | Scheduler | 12-hour auto-disable. Set the enable duration to forever. |
| 🟠 Route resolves but shows a cert warning | TLS | Domain has no `certResolver` set in the UI. Set `stepca`. |
| 🟠 Router shows in the API with an error about a missing middleware | Middlewares | Global middleware referenced without the `@file` suffix. |
| 🟡 401 loop in the browser on the panel | BasicAuth | No matching user in `/opt/netlab-stack/traefik/auth/.htpasswd`. |
| 🟡 403 before any password prompt | IP allowlist | Client outside `TPADMIN_ALLOWLIST`. |
| 🟡 Two routes for one host, behaviour flips on restart | Coexistence | Duplicate rule across providers. Run the duplicate detector above. |
| 🟡 Traefik routes to the wrong IP for the panel | Networking | `traefik.docker.network=edge` removed; Traefik picked the `tpadmin-back` address, which it cannot reach. |

Logs:

```bash
docker logs -f traefik-proxy-admin
docker logs -f traefik-proxy-admin-db
docker logs traefik 2>&1 | grep -i "http provider\|providers/http"
```

---

## Upstream

[Janhouse/traefik-proxy-admin](https://github.com/Janhouse/traefik-proxy-admin) ·
AGPL-3.0-or-later · built for exposing internal services through Headscale, but the
Traefik half is generic.
