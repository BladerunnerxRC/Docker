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
| 🚀 | [Installation](#installation) | **Step-by-step, start to finish** |
| ⚙️ | [Environment variables](#environment-variables) | Reference table |
| 🤝 | [Coexistence rules](#coexistence-rules) | Sharing a proxy with the file provider |
| 🔒 | [Security](#security) | The panel has no login |
| 💾 | [Backups & restore](#backups--restore) | Where the state lives |
| 🔧 | [Maintenance & upgrades](#maintenance--upgrades) | Keeping it healthy |
| 🧹 | [Uninstall](#uninstall) | **Detaching from Traefik without breaking it** |
| 🩺 | [Troubleshooting](#troubleshooting) | When something breaks |

**Installation steps:**
[1. Preflight](#step-1--preflight) ·
[2. BasicAuth user](#step-2--create-a-basicauth-user) ·
[3. DNS record](#step-3--add-the-dns-record) ·
[4. Deploy the stack](#step-4--deploy-the-stack-in-portainer) ·
[5. Verify the stack](#step-5--verify-the-stack-is-healthy) ·
[6. Wire up Traefik](#step-6--wire-the-http-provider-into-traefik) ·
[7. Configure the panel](#step-7--configure-the-panel) ·
[8. Add your domain](#step-8--add-your-domain) ·
[9. First service](#step-9--publish-your-first-service)

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
> [Step 6](#step-6--wire-the-http-provider-into-traefik) is correct.

---

## Installation

Nine steps, in order. Steps 1–5 stand the stack up; **step 6 is the one that makes routes
actually work** and is the easiest to skip. Each step ends with a check — if the check
fails, stop there rather than continuing.

Commands marked 🖥️ run on the Docker host (smiddleware). Everything else is a browser.

---

### Step 1 — Preflight

> [!IMPORTANT]
> **Every 🖥️ command in this guide runs on the host where Traefik itself runs** — the
> machine [traefik/README.md](../traefik/README.md#runtime-layout-smiddleware) calls
> *smiddleware*, which is `192.168.200.98` in
> [30-services.yml](../traefik/dynamic/30-services.yml). This stack reaches Traefik over a
> **local** Docker bridge, so the two must share a host. It will not work from
> `optiplex-two` or any other Docker host on the LAN.

Start by confirming you are on the right machine — this check comes first because the
others give misleading results on the wrong one:

🖥️

```bash
docker network inspect edge \
  --format 'edge: {{.Driver}} | attached: {{range .Containers}}{{.Name}} {{end}}'
```

`traefik` **must** appear in the attached list:

```text
edge: bridge | attached: traefik adguardhome whoami ...
```

> [!CAUTION]
> **`edge` existing is not proof you are on the right host.** It is a plain *local* bridge
> — any Docker host can have a network with that name, and they are unrelated networks
> that cannot reach each other. If `docker network inspect edge` succeeds but `traefik` is
> absent from the attached list, you are on the wrong machine. Deploying there would come
> up clean and then fail at [step 6](#step-6--wire-the-http-provider-into-traefik), because
> Traefik cannot resolve `traefik-proxy-admin` across hosts.

Then confirm the rest:

🖥️

```bash
# Traefik is running here
docker ps --filter name=^traefik$ --format '{{.Names}}  {{.Status}}'

# The BasicAuth usersfile Traefik already mounts
sudo ls -l /opt/netlab-stack/traefik/auth/.htpasswd

# You can edit Traefik's static config
sudo test -w /opt/netlab-stack/traefik/traefik.yml && echo "traefik.yml writable"
```

Expected:

```text
traefik  Up 3 days
-rw-r----- 1 root root 92 Jul 12 21:04 /opt/netlab-stack/traefik/auth/.htpasswd
traefik.yml writable
```

| Result | Meaning |
| --- | --- |
| `docker ps` prints nothing | No Traefik here — **wrong host**, `ssh` to the one above |
| `/opt/netlab-stack/...: No such file or directory` | Wrong host, or the usersfile does not exist yet — [step 2](#step-2--create-a-basicauth-user) covers creating it |
| `traefik.yml writable` missing | Wrong host, or you need `sudo` rights on the static config |
| `edge` not found at all | Deploy the [traefik](../traefik/) stack first — this stack declares the network `external` and will not start without it |

**Nothing else to prepare.** No host directories to create; all state lives in a named
volume. No free host port is needed either — see the note in [step 4](#step-4--deploy-the-stack-in-portainer).

> [!TIP]
> **Must the panel run on a different host?** Then this design does not fit as written:
> Traefik would have to poll it by `IP:port` over the LAN instead of by container name,
> which means publishing a host port — and a published port bypasses both middlewares
> guarding a panel that [has no login of its own](#security). If you need that, protect
> the published port at the firewall and treat the
> [debugging-port warning](#optional-direct-host-access-for-debugging) as permanent.

---

### Step 2 — Create a BasicAuth user

The panel has **no login of its own** ([why](#security)), so Traefik's BasicAuth is the
only thing guarding it. Add a user to the usersfile Traefik already mounts.

🖥️

```bash
sudo htpasswd -B /opt/netlab-stack/traefik/auth/.htpasswd tpadmin
```

> [!CAUTION]
> Use `-B` (bcrypt) **without** `-c`. The `-c` flag *creates a new file*, silently
> truncating the existing one and locking you out of every other service that uses it —
> including the Traefik dashboard. Only use `-c` if `ls` in step 1 showed no file at all.

<details>
<summary><strong>If step 1 reported no <code>.htpasswd</code> on the Traefik host</strong></summary>

The traefik stack bind-mounts that exact path
([docker_compose.yaml](../traefik/docker_compose.yaml)):

```yaml
- /opt/netlab-stack/traefik/auth/.htpasswd:/etc/traefik/.htpasswd:ro
```

When a bind-mount source does not exist, **Docker creates it as a directory**, and Traefik
then reports an unreadable usersfile rather than anything about a missing file. Check
which you have before creating a user:

🖥️

```bash
sudo stat -c '%F  %n' /opt/netlab-stack/traefik/auth/.htpasswd
```

- `regular file` → normal case, use the `htpasswd -B` command above without `-c`.
- `directory` → Docker invented it. Remove it, create a real file, and recreate the
  Traefik container so it picks up the new inode:

  ```bash
  sudo rmdir /opt/netlab-stack/traefik/auth/.htpasswd
  sudo htpasswd -cB /opt/netlab-stack/traefik/auth/.htpasswd tpadmin
  sudo chmod 640 /opt/netlab-stack/traefik/auth/.htpasswd
  docker compose -f /opt/netlab-stack/traefik/docker_compose.yaml up -d --force-recreate traefik
  ```

  `-c` is correct **only here**, where you have just confirmed no file exists.
  A `docker restart` is not enough — the bind mount is resolved at container creation.

</details>

**Check** — the user should be listed, and Traefik re-reads the file on change, so no
restart is needed:

🖥️

```bash
sudo cut -d: -f1 /opt/netlab-stack/traefik/auth/.htpasswd
```

---

### Step 3 — Add the DNS record

In **AdGuard Home** ([AdGuard](../AdGuard/), `https://dns.shome`):

1. **Filters → DNS rewrites → Add DNS rewrite**
2. **Domain:** `tpadmin.shome`
3. **Answer:** the IP of the Traefik host — the same address your other `*.shome` names
   resolve to (`192.168.200.98` in [30-services.yml](../traefik/dynamic/30-services.yml))
4. **Save**

**Check** — from any LAN client:

```bash
nslookup tpadmin.shome
```

It must return the Traefik host's IP. A `NXDOMAIN` here becomes a confusing
"connection refused" later.

---

### Step 4 — Deploy the stack in Portainer

1. **Stacks → + Add stack**
2. **Name:** `traefikadmin`

   > [!NOTE]
   > The stack name becomes the prefix for the volume and internal network
   > (`traefikadmin_tpadmin_db_data`). Renaming the stack later orphans the volume and
   > your routes with it.

3. **Build method:** *Repository* — point it at this repo with compose path
   `TraefikAdmin/docker-compose.yml` — or *Web editor*, pasting
   [docker-compose.yml](docker-compose.yml).
4. **Environment variables → Advanced mode**, paste and edit:

   ```ini
   BASE_DOMAIN=shome
   CERTRESOLVER=stepca
   TPADMIN_HOST=tpadmin
   TPADMIN_ALLOWLIST=192.168.200.0/24,192.168.0.0/16
   POSTGRES_DB=traefik_admin
   POSTGRES_USER=tpadmin
   POSTGRES_PASSWORD=changeMeToALongAlphanumericString
   DB_CONNECTION_LIMIT=10
   TZ=America/New_York
   ```

   Every variable is explained in [Environment variables](#environment-variables).
   **Set `POSTGRES_PASSWORD` to a long alphanumeric string** — punctuation breaks it in
   two separate, silent ways ([details](#environment-variables)).

   Before pasting, make sure `TPADMIN_HOST` is not already claimed:

   🖥️
   ```bash
   grep -rn "shome\`" /opt/git/Docker/traefik/dynamic/20-routers.yml
   ```

5. **Deploy the stack.**

> [!NOTE]
> **No free host port required.** This stack publishes nothing. The `3000` in the compose
> file is the container's own listener, reached by Traefik over `edge` at
> `traefik-proxy-admin:3000` — a different address from `0.0.0.0:3000` on the host, which
> [AdGuard Home already owns](../traefik/docker_compose.yaml). The two cannot collide.
>
> Do **not** try to move the app off 3000 with the `PORT` variable to "free it up": the
> image's built-in `HEALTHCHECK` hardcodes `http://localhost:3000/api/health`, so the
> container would go permanently unhealthy while working fine.

---

### Step 5 — Verify the stack is healthy

🖥️

```bash
docker ps --filter name=traefik-proxy-admin --format 'table {{.Names}}\t{{.Status}}'
```

Both must reach `(healthy)` — give it ~40s for the Postgres `start_period`:

```text
NAMES                    STATUS
traefik-proxy-admin      Up 2 minutes (healthy)
traefik-proxy-admin-db   Up 2 minutes (healthy)
```

The app runs its own schema migrations on boot (`instrumentation.ts` → drizzle migrate),
so there is **no manual `db:push` step**, despite what upstream's README implies:

🖥️

```bash
docker logs traefik-proxy-admin 2>&1 | head -20
```

```text
Traefik Configurator version: <build id>
Running database migrations
   ▲ Next.js 15.x
   - Local:  http://0.0.0.0:3000
```

**Check the migrations actually landed** — this is the step that catches a mangled
password, because the app's health check only probes the HTTP listener and stays green
even when the database is unreachable:

🖥️

```bash
docker exec traefik-proxy-admin-db psql -U tpadmin -d traefik_admin -c '\dt'
```

You should see the app's tables (`services`, `domains`, `app_config`, …). An empty
result means migrations failed — check `docker logs traefik-proxy-admin` for
`Running migrations failed`.

**Now confirm Traefik is routing to it.** From a LAN client inside `TPADMIN_ALLOWLIST`:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://tpadmin.shome/     # expect 401
curl -sk -o /dev/null -w '%{http_code}\n' -u tpadmin https://tpadmin.shome/   # expect 200
```

`401` proves DNS, TLS, routing and BasicAuth are all working. Then open
`https://tpadmin.shome/` in a browser and log in.

| Result | Meaning |
| --- | --- |
| `401` then `200` | ✅ Working — continue to step 6 |
| `403` | Your client IP is outside `TPADMIN_ALLOWLIST` |
| `404` | Traefik has no router for this host — check the container's labels applied |
| Connection refused / NXDOMAIN | Step 3 DNS record missing |

> [!IMPORTANT]
> The panel is reachable now, but **no route it creates will work yet.** Traefik does not
> know the panel exists until step 6.

---

### Step 6 — Wire the HTTP provider into Traefik

This is the only change outside this folder. It edits the live edge proxy's **static**
configuration, so it needs a Traefik restart.

#### 6a. Add the provider

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

> [!CAUTION]
> The key is **`endpoint`, singular**. Upstream's README shows `endpoints:` as a list;
> Traefik v3 rejects that unknown key and refuses to start, taking your whole edge proxy
> down with it. Keep a copy of the original file before editing.

Traefik resolves `traefik-proxy-admin` by container name over the shared `edge` network,
and polls it **directly on port 3000** — bypassing its own routers, so the BasicAuth and
IP-allowlist middlewares do not apply to this call and do not need to.

#### 6b. Restart Traefik

🖥️

```bash
docker restart traefik
docker logs traefik 2>&1 | tail -30
```

> [!TIP]
> Order does not matter. If Traefik starts while the panel is down, the HTTP provider
> logs a poll failure and contributes nothing; the file and Docker providers are
> unaffected and every existing route keeps working. A poll that fails *later* does not
> clear routes already published — Traefik keeps the last configuration it received.

#### 6c. Verify the provider connected

First, confirm Traefik can read the endpoint at all:

🖥️

```bash
docker exec traefik wget -qO- http://traefik-proxy-admin:3000/api/traefik/config
```

Expected right now — an empty config, because you have not added a service yet:

```json
{"http":{"services":{},"routers":{}}}
```

That empty object is **success**. A hang or `wget: bad address` means the two containers
are not on the same network; recheck `traefik.docker.network=edge` on the panel.

Then confirm no provider errors:

🖥️

```bash
docker logs traefik 2>&1 | grep -i "provider" | tail -20
```

Nothing mentioning `http` and `error` together. From step 9 onwards, panel routes will
show up under the `http` provider:

```bash
curl -ks https://traefik.shome/api/http/routers \
| jq 'map(select(.provider=="http")) | map({name, rule, service, status})'
```

---

### Step 7 — Configure the panel

Open `https://tpadmin.shome/` → **global settings**. Four settings decide whether
generated routes work at all. Three are here; the fourth is per-domain in step 8.

| Setting | Set it to | Consequence if wrong |
| --- | --- | --- |
| **Default entrypoint** | `websecure` | Empty means routers get no `entryPoints`, so Traefik attaches them to *every* entrypoint — including `:8082`, which serves the API. |
| **Admin panel domain** | `traefik-proxy-admin:3000` | Used as the forward-auth address for protected services and as the upstream for the panel's own generated router. Traefik is the only caller, so a container-reachable address is what matters. The default `localhost:3000` points Traefik at itself. |
| **Default enable duration** | *Forever* — no duration | Routes silently stop working after 12 hours. See below. |
| **Global middlewares** *(optional)* | `security-headers@file`, `compression@file` | Applies your existing hardening to every panel route. The `@file` suffix is required. |

> [!WARNING]
> **Routes expire after 12 hours by default.** `defaultEnableDurationMinutes` ships as
> `720`, and a scheduler disables expired services every 10 seconds — plus on every
> config poll. For permanent homelab routes, set the global default to *forever*, or set
> the duration explicitly per service. The symptom is a route that works all afternoon
> and 404s the next morning with nothing in the Traefik logs, because from Traefik's
> point of view the router was simply withdrawn.
>
> The expiry clock starts at `enabledAt`, so re-enabling a service in the UI restarts it.

---

### Step 8 — Add your domain

**Domains → Add domain:**

| Field | Value |
| --- | --- |
| Domain | `shome` |
| Cert resolver | `stepca` |

Without a resolver the routes still work, but over Traefik's default self-signed cert —
every client gets a certificate warning. `stepca` is the resolver defined in
[traefik.yml](../traefik/traefik.yml); the name must match exactly.

---

### Step 9 — Publish your first service

**Services → Add service.** A worked example:

| Field | Value | Notes |
| --- | --- | --- |
| Name | `example` | Label only |
| Domain | `shome` | From step 8 |
| Hostname mode | `subdomain` | Publishes `example.shome` |
| Subdomain | `example` | **Must not already be claimed** — see [Coexistence rules](#coexistence-rules) |
| Target URL | `http://192.168.200.50:8080` | Where traffic goes |
| Entrypoint | *(blank — inherits `websecure`)* | From step 7 |
| Enable duration | *Forever* | Unless you want it to expire |

Save, then **enable** it.

Add a DNS rewrite for `example.shome` in AdGuard exactly as in [step 3](#step-3--add-the-dns-record) —
the panel creates the Traefik route, but nothing creates DNS for you.

#### Verify end to end

Within ~10 seconds (one poll interval):

🖥️

```bash
# 1. The panel is generating the route
docker exec traefik wget -qO- http://traefik-proxy-admin:3000/api/traefik/config | jq

# 2. Traefik has ingested it
curl -ks https://traefik.shome/api/http/routers \
| jq 'map(select(.provider=="http")) | map({name, rule, service, status})'
```

Expected from (2) — note `"status": "enabled"`:

```json
[{"name":"example@http","rule":"Host(`example.shome`)","service":"example@http","status":"enabled"}]
```

Then from a LAN client:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://example.shome/
```

| Where it breaks | Meaning |
| --- | --- |
| Empty in (1) | Service not enabled in the UI, or already expired |
| Present in (1), absent in (2) | Step 6 incomplete — provider not added or Traefik not restarted |
| Present in (2), browser fails | DNS rewrite for `example.shome` missing |
| Cert warning | Domain has no cert resolver — step 8 |

✅ **Installed.** Repeat step 9 for each service you want to publish.

---

### Optional: direct host access for debugging

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

## Environment variables

Full template with the reasoning inline: [.env.example](.env.example). In Portainer these
go under **Stack → Environment variables**, not a committed `.env`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `BASE_DOMAIN` | `shome` | Must match the traefik stack. |
| `CERTRESOLVER` | `stepca` | Resolver for the panel's own cert. Per-route resolvers are set in the UI ([step 8](#step-8--add-your-domain)). |
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

Everything else — domains, per-domain cert resolvers, the default entrypoint, the admin
panel address, SSO — is configured in the web UI and stored in Postgres, not in
environment variables.

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

## Uninstall

**Separating from Traefik and deleting the stack are two different operations, and the
order is not optional.** Traefik must stop polling the panel *before* the panel goes away.

> [!CAUTION]
> **Do not delete the stack first.** If the panel disappears while
> `providers.http` still points at it, Traefik logs a failed poll every 10 seconds and
> keeps serving the **last configuration it received** — so the panel's routes keep
> working, pointing at a service you think you removed. They then vanish without warning
> at the next Traefik restart, which may be days later and will look unrelated.
> Removing the provider first makes the change immediate, visible, and reversible.

Pick your endpoint:

| Goal | Do |
| --- | --- |
| Stop the panel affecting routing, keep it installed | [Part A](#part-a--detach-from-traefik) only |
| Remove it completely | [Part A](#part-a--detach-from-traefik), then [Part B](#part-b--remove-the-stack) |

---

### Part A — Detach from Traefik

#### A1. Inventory what you are about to lose

Panel routes live only in Postgres — they are **not** in git, so nothing else records
them. Capture both a machine-readable copy and a human-readable list:

🖥️

```bash
# Exact config Traefik is being served
docker exec traefik wget -qO- http://traefik-proxy-admin:3000/api/traefik/config \
| jq > ~/tpadmin-routes-$(date +%F).json

# What that means in practice
curl -ks https://traefik.shome/api/http/routers \
| jq -r 'map(select(.provider=="http")) | .[] | "\(.rule)  ->  \(.service)"'
```

If that second command prints nothing, the panel is publishing no routes and you can go
straight to [A3](#a3-remove-the-provider).

#### A2. Migrate anything you still need

For each route worth keeping, hand it back to the file provider. Translating the example
from [step 9](#step-9--publish-your-first-service):

```yaml
# traefik/dynamic/20-routers.yml
    example:
      rule: "Host(`example.shome`)"
      entryPoints: ["websecure"]
      tls:
        certResolver: stepca
      middlewares: ["security-headers", "compression"]
      service: example
```

```yaml
# traefik/dynamic/30-services.yml
    example:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://192.168.200.50:8080"
```

Commit, then deploy with the D&R script:

🖥️

```bash
sudo /usr/local/sbin/edge-sync-traefik-dynamic
```

> [!WARNING]
> **Confirm the sync script actually works before relying on it here.**
> [traefik/README.md](../traefik/README.md#known-issue-sync-script-path) documents that
> `edge-sync-traefik-dynamic` still reads the pre-flatten path
> (`stacks/edge-stack/traefik/dynamic`) and aborts at step 2/9. It fails safe — it never
> touches the live config — but that means your migrated routes would silently never
> reach the host, and you would then remove the panel that was serving them. Verify
> line 24 reads `SRC="${REPO}/traefik/dynamic"`, or copy the files across by hand.

Confirm the migrated routes are live **under the `file` provider** before continuing —
at this point each host has two routers, one from each provider, which is the one moment
duplicate rules are expected:

```bash
curl -ks https://traefik.shome/api/http/routers \
| jq 'map(select(.rule=="Host(`example.shome`)")) | map({name, provider, status})'
```

#### A3. Remove the provider

Reverse [step 6a](#6a-add-the-provider) in `/opt/netlab-stack/traefik/traefik.yml` **and**
in [traefik/traefik.yml](../traefik/traefik.yml):

```diff
 providers:
   docker:
     exposedByDefault: false
   file:
     directory: /etc/traefik/dynamic
     watch: true
-  http:
-    endpoint: "http://traefik-proxy-admin:3000/api/traefik/config"
-    pollInterval: "10s"
-    pollTimeout: "5s"
```

> [!NOTE]
> Leave `providers.docker` and `providers.file` exactly as they are. Deleting the whole
> `providers:` block, or leaving an empty `http:` key behind, stops Traefik starting.

🖥️

```bash
docker restart traefik
```

#### A4. Verify Traefik is clean and intact

🖥️

```bash
# No panel routers remain — expect 0
curl -ks https://traefik.shome/api/http/routers \
| jq '[.[] | select(.provider=="http")] | length'

# Your other providers are untouched — expect only file / docker / internal
curl -ks https://traefik.shome/api/http/routers | jq -r '.[].provider' | sort | uniq -c

# No provider errors
docker logs traefik 2>&1 | tail -40 | grep -i error
```

Then spot-check a route you did not touch, e.g. `https://komga.shome/`. Traefik is now
fully separated from this stack — the panel can keep running with no effect on routing.

> [!TIP]
> **Rollback.** Nothing here is destructive. To reattach, put the `http:` block back and
> `docker restart traefik`; the panel's routes return on the next poll.

---

### Part B — Remove the stack

Only after Part A verifies clean.

#### B1. Take a final dump

🖥️

```bash
docker exec traefik-proxy-admin-db \
  pg_dump -U tpadmin -d traefik_admin --clean --if-exists \
| gzip > ~/tpadmin-final-$(date +%F).sql.gz
```

Keep this alongside the JSON from [A1](#a1-inventory-what-you-are-about-to-lose). Together
they are the only record of what the panel was doing.

#### B2. Delete the stack

**Portainer → Stacks → `traefikadmin` → Delete.** Or on the host:

🖥️

```bash
cd /opt/git/Docker/TraefikAdmin && docker compose down
```

> [!IMPORTANT]
> Do **not** add `-v` yet — that destroys the database. Remove the volume in B3, after
> you have confirmed the dump is good.
>
> `edge` is declared `external: true` precisely so this step cannot remove it. Compose
> will leave it alone and Traefik keeps running. (Docker also refuses to delete a network
> that still has containers attached, so Traefik is protected twice over.) The
> `tpadmin-back` network is owned by this stack and goes away with it.

#### B3. Remove the volume

Portainer does not always remove named volumes with the stack, and the data outlives the
containers by design. Check and remove explicitly:

🖥️

```bash
docker volume ls | grep tpadmin
docker volume rm traefikadmin_tpadmin_db_data
```

#### B4. Clean up what lives outside the stack

Three things were created outside this folder during install and are not removed by
deleting the stack:

| Item | From | Remove with |
| --- | --- | --- |
| DNS rewrite `tpadmin.shome` | [Step 3](#step-3--add-the-dns-record) | AdGuard Home → Filters → DNS rewrites → delete |
| BasicAuth user `tpadmin` | [Step 2](#step-2--create-a-basicauth-user) | `sudo htpasswd -D /opt/netlab-stack/traefik/auth/.htpasswd tpadmin` |
| Container images | [Step 4](#step-4--deploy-the-stack-in-portainer) | `docker rmi ghcr.io/janhouse/traefik-proxy-admin:v0.2.2` |

> [!CAUTION]
> Use `htpasswd -D` to delete a single user. Never "clean up" by deleting or recreating
> `.htpasswd` — it is shared with the Traefik dashboard and any other service using
> `usersfile`, and recreating it with `-c` locks you out of all of them.

Also delete any DNS rewrites you added for services the panel was publishing
([step 9](#step-9--publish-your-first-service)) — unless you migrated those routes in
[A2](#a2-migrate-anything-you-still-need), in which case leave them.

#### B5. Final check

🖥️

```bash
docker network inspect edge --format 'edge intact — {{len .Containers}} containers'
docker ps --filter name=^traefik$ --format '{{.Names}}  {{.Status}}'
docker ps -a --filter name=traefik-proxy-admin --format '{{.Names}}'   # expect empty
```

Traefik should still be `Up`, `edge` should still exist with your other containers on it,
and nothing named `traefik-proxy-admin` should remain.

---

## Troubleshooting

| Symptom | Step | Likely cause |
| --- | --- | --- |
| 🔴 Traefik fails to start after the wiring edit | 6 | `endpoints:` (plural) instead of `endpoint:`. Traefik v3 rejects the unknown key. |
| 🔴 `edge` exists but `traefik` is not attached to it | 1 | **Wrong host.** `edge` is a local bridge; a same-named network on another Docker host is unrelated. Deploy on the machine running Traefik. |
| 🔴 Stack won't deploy: `network edge not found` | 1 | The traefik stack is not running. |
| 🔴 Traefik logs an unreadable usersfile; `.htpasswd` is a directory | 2 | Bind-mount source did not exist, so Docker created a directory. See the collapsed note in step 2. |
| 🔴 `tpadmin.shome` → connection refused / NXDOMAIN | 3 | No AdGuard DNS rewrite. |
| 🔴 App crash-loops immediately, `EROFS` in logs | 4 | `read_only: true` with a write path not covered by the tmpfs mounts. Remove `read_only` and both `tmpfs` lines to confirm. |
| 🟠 App healthy but every page errors | 4 | `DATABASE_URL` mangled by punctuation in the password. Check with `docker exec traefik-proxy-admin env \| grep DATABASE_URL`. |
| 🟠 `getaddrinfo ENOTFOUND` naming part of your password | 4 | An `@` in `POSTGRES_PASSWORD` split the URL. Use alphanumerics. |
| 🟠 `\dt` returns no tables | 5 | Migrations failed — almost always the password above. |
| 🟠 Panel loads, routes never appear in Traefik | 6 | Provider not added, or Traefik not restarted since. |
| 🟠 `wget: bad address 'traefik-proxy-admin'` from the traefik container | 6 | Containers not on a shared network; check `traefik.docker.network=edge`. |
| 🟠 **Routes work, then 404 the next day** | 7 | 12-hour auto-disable. Set the enable duration to forever. |
| 🟠 Route resolves but shows a cert warning | 8 | Domain has no `certResolver` set in the UI. Set `stepca`. |
| 🟠 Router shows in the API with an error about a missing middleware | 7 | Global middleware referenced without the `@file` suffix. |
| 🟡 401 loop in the browser on the panel | 2 | No matching user in `/opt/netlab-stack/traefik/auth/.htpasswd`. |
| 🟡 403 before any password prompt | 4 | Client outside `TPADMIN_ALLOWLIST`. |
| 🟡 Two routes for one host, behaviour flips on restart | 9 | Duplicate rule across providers. Run the duplicate detector in [Coexistence rules](#coexistence-rules). |
| 🟡 Traefik routes to the wrong IP for the panel | 4 | `traefik.docker.network=edge` removed; Traefik picked the `tpadmin-back` address, which it cannot reach. |

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
