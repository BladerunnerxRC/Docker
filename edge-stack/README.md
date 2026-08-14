# edge-stack

Reverse proxy + LAN DNS for the `.shome` homelab. Runs on **smiddleware (192.168.200.52)**.

| Service | Image | Reachable at |
|---|---|---|
| `traefik` | `traefik:v3.7.10` (pinned) | `https://traefik.shome/dashboard` |
| `adguardhome` | `adguard/adguardhome:latest` | `https://dns.shome` — and DNS on `:53` |
| `whoami` | `traefik/whoami:latest` | `https://whoami.shome` |

`compose.yaml` was captured from the **live running state** of smiddleware on 2026-08-14,
not from an older committed file. The only intentional deviation is pinning Traefik to
`v3.7.10` — the version that was actually running behind the `:latest` tag.

> **Blast radius: HIGH.** This host is the reverse proxy for every `.shome` service *and*
> the LAN DNS resolver. Redeploying briefly stops AdGuard, which means no DNS for the
> household. Do it in a quiet window, or set a temporary secondary DNS on the router first.

---

## Persistent data

Nothing stateful lives in this repo. All of it is bind-mounted from `/opt/netlab-stack/`:

```
/opt/netlab-stack/traefik/{traefik.yml,dynamic,certs,acme,stepca,auth}
/opt/netlab-stack/adguard/{conf,work}
```

Recreating the containers does **not** touch it — certs, `acme.json`, and AdGuard's
config and query stats all survive. This is what makes redeploy safe.

Note that `traefik.yml` (static config) and `dynamic/*.yml` (file provider) are read from
that host path at runtime, **not** from this repo. Copies committed elsewhere in this
repo are reference material and are not what Traefik loads.

---

## Deploying from Portainer (GitOps)

The repo is public, so **no credentials are required**.

1. **Portainer → Stacks → Add stack**
2. Name: `edge-stack`
3. Build method: **Repository**
4. Fill in:

   | Field | Value |
   |---|---|
   | Repository URL | `https://github.com/BladerunnerxRC/Docker` |
   | Repository reference | `refs/heads/main` |
   | Compose path | `edge-stack/compose.yaml` |
   | Authentication | off |

5. Environment variables: **leave empty**. Every path has a default baked into
   `compose.yaml`. Only add overrides from `.env.example` if your paths differ.
6. Optionally enable **GitOps updates** to re-pull on a polling interval or webhook.
7. **Deploy the stack.**

### First-time cutover

The three containers currently belong to an older Portainer stack that was created from
the web editor (`com.docker.compose.project=edge-stack`,
`config_files=/data/compose/14/...`). Portainer **cannot convert a web-editor stack to a
Git-backed one in place** — the old stack has to go first, or the new deploy fails on
`container_name` collisions.

```bash
# 1. Baseline, to compare against afterward
dig +short @192.168.200.52 whoami.shome     # expect 192.168.200.52
dig +short @192.168.200.52 google.com       # upstream resolution works
curl -ks https://traefik.shome/api/http/routers | jq 'map(select(.provider=="file"))|length'

# 2. Pre-pull so the cutover is not waiting on a download
docker pull traefik:v3.7.10
```

Then delete the old `edge-stack` stack in the Portainer UI — **this starts the DNS
outage** — and immediately deploy the new Git-backed stack per the steps above.

If the old stack does not appear in Portainer's list, remove the containers directly:

```bash
docker rm -f traefik adguardhome whoami && docker network rm edge
```

### Verify

```bash
docker ps --filter label=com.docker.compose.project=edge-stack \
  --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
# expect: traefik traefik:v3.7.10 | adguardhome :latest | whoami :latest

dig +short @192.168.200.52 whoami.shome     # 192.168.200.52
dig +short @192.168.200.52 google.com       # real answer

for h in whoami dns traefik; do
  echo -n "$h.shome -> "; curl -kso /dev/null -w '%{http_code}\n' https://$h.shome/
done
```

Success = three containers up on the right tags, DNS resolving, file-provider router
count matching the baseline, and no step-ca certificate errors.

---

## Known cruft

Reproduced deliberately so this file matches production. Each is safe to remove, but
removing it is a **behavior change** and should be its own commit.

- **Dead Kubernetes providers.** Traefik runs with `--providers.kubernetesingress` and
  `--providers.kubernetescrd`, both pointed at `/kubeconfig`. The bind mounts a
  *directory* (`/opt/netlab-stack/traefik/kubeconfig`) where a *file* is expected, so
  neither provider works. The real credential file is
  `/opt/netlab-stack/traefik/traefik-smiddleware.kubeconfig`. Nothing on this host uses
  Kubernetes, so the flags and the mount can simply be deleted.
- **`--log.level=DEBUG`.** Verbose and noisy for a permanently running edge proxy.
  `INFO` is set in `traefik.yml`'s static config, but the CLI flag overrides it.

## Dashboard authentication

**The Traefik dashboard is protected by IP allowlist only.** Its router middlewares are
`traefik-ipallow@docker` and nothing else, so anyone on `192.168.200.0/24` **or the whole
of `192.168.0.0/16`** reaches `/dashboard` and `/api` with no password.

`/opt/netlab-stack/traefik/auth/.htpasswd` exists and is already mounted into the
container, but nothing references it. `compose.yaml` carries the BasicAuth middleware
lines commented out — uncomment them and add `traefik-auth@docker` to the router's
middlewares list to turn it on. Narrowing `TRAEFIK_DASHBOARD_ALLOWLIST` to just
`192.168.200.0/24` is worth doing regardless.

## Watchtower

Watchtower also runs on this host (`/home/thomas/docker-compose-scripts/watchtower/`) and
updates images on floating tags. Traefik is now pinned, so watchtower will leave it alone;
`adguardhome` and `whoami` remain on `:latest` and will still drift. That is intentional
for AdGuard.
