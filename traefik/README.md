# Edge Stack — Traefik Dynamic Config + D&R (Deploy & Recover)

This `edge-stack` includes Traefik (reverse proxy), AdGuardHome, and supporting apps.  
The goal of this doc is to describe the **dynamic config files** and the **D&R workflow** used to deploy and recover safely on the host.

> **D&R = Deploy & Recover**  
> Deploy = pull → sync → validate → restart → verify  
> Recover = restore backup → restart → verify

---

## Source of Truth (Repo)

Traefik **file provider** dynamic config is stored here:

```text
traefik/dynamic/
  00-servers-transports.yml
  10-middlewares.yml
  20-routers.yml
  30-services.yml
  .gitignore
```

> **Note:** this path used to be `stacks/edge-stack/traefik/dynamic/`. The repo was
> flattened in `e23e361` (2026-07-01) and every stack moved up to the repo root.
> See [Known issue: sync script path](#known-issue-sync-script-path).


### What each file does

- **00-servers-transports.yml**  
  Defines `serversTransports` used by services that need special TLS behavior (e.g., `insecureSkipVerify` for certain internal UIs like Webmin).

- **10-middlewares.yml**  
  Shared middlewares used by routers (security headers, compression, etc.).

- **20-routers.yml**  
  Host rules (`Host(...)`), entrypoints (`websecure`), TLS resolver (`stepca`), and which middleware chain applies per app.

- **30-services.yml**  
  Where each router forwards traffic (e.g., `http://<ip>:<port>` or internal URLs).

---

## Runtime Layout (smiddleware)

On the server (smiddleware), Traefik consumes the synced dynamic config from:

/opt/netlab-stack/traefik/
dynamic/ # live file-provider YAMLs Traefik watches
acme/ # ACME storage (sensitive; private-ish material)
certs/ # local cert assets (if used)
stepca/ # step-ca integration assets (if used)
backups/ # tar backups made before each deploy
dynamic-archive/ # old backup folders moved out of watched dir


### Why `dynamic-archive/` matters

Traefik’s **file provider loads any YAML** under the watched directory.  
Keeping old configs inside something like:

/opt/netlab-stack/traefik/dynamic/backup/


can reintroduce “ghost” routers/services.

✅ We keep any archival content **outside** the watched directory:

/opt/netlab-stack/traefik/dynamic-archive/

---

## D&R Scripts (Deploy & Recover)

### Known issue: sync script path

`edge-sync-traefik-dynamic` was never updated for the repo flatten and still reads the
old layout:

```bash
# scripts/sbin/edge-sync-traefik-dynamic:24
SRC="${REPO}/stacks/edge-stack/traefik/dynamic"   # path no longer exists
```

Because step 1/9 hard-resets the server clone to `origin/main`, that directory is gone
after the fetch and the script aborts at step 2/9:

```text
missing source dir: /opt/git/Docker/stacks/edge-stack/traefik/dynamic
```

It **fails safe** — the abort happens before the backup, rsync, and Traefik restart, so
the live config is never touched. But deploys have been a no-op since the flatten. The fix
is a one-line change to line 24:

```bash
SRC="${REPO}/traefik/dynamic"
```

`edge-rollback-traefik-dynamic` is unaffected; it only reads from
`/opt/netlab-stack/traefik/backups` and never touches the repo.

### Installed scripts

These are installed on smiddleware:

```text
/usr/local/sbin/
  edge-stack-bootstrap-dirs.sh
  edge-sync-traefik-dynamic
  edge-rollback-traefik-dynamic
```

Logs are stored here:

```text
/var/log/edge-sync/
  edge-sync-traefik-dynamic.log
  edge-sync-traefik-dynamic-YYYYmmdd-HHMMSS.log
  edge-rollback-traefik-dynamic.log
  edge-rollback-traefik-dynamic-YYYYmmdd-HHMMSS.log
```

### 1) Bootstrap directories (one-time)
Creates required directories with owners/permissions:

```bash
sudo /usr/local/sbin/edge-stack-bootstrap-dirs.sh

2) Deploy (standard operation)

This is your “Deploy” in D&R.

What it does:

Hard-sync repo clone to origin/main (pull-only server model)

Create tar backup of the current live dynamic config

rsync --delete repo dynamic → live dynamic

Validate YAML (fails safely if YAML is broken)

Restart Traefik

Wait for API readiness

Verify file-provider routers/middlewares

Run:
sudo /usr/local/sbin/edge-sync-traefik-dynamic

Help / options:
sudo /usr/local/sbin/edge-sync-traefik-dynamic --help
sudo /usr/local/sbin/edge-sync-traefik-dynamic --dry-run
sudo /usr/local/sbin/edge-sync-traefik-dynamic --list-backups

3) Recover / Rollback (if needed)

This is your “Recover” in D&R.

What it does:

Choose latest backup tarball (or user-supplied file)

Archive current live dynamic as a safety snapshot

Restore selected tarball

Restart Traefik

Wait for API readiness

Verify file-provider routers/middlewares

Rollback to newest:
sudo /usr/local/sbin/edge-rollback-traefik-dynamic

List backups:
sudo /usr/local/sbin/edge-rollback-traefik-dynamic --list

Rollback to a specific file:
sudo /usr/local/sbin/edge-rollback-traefik-dynamic /opt/netlab-stack/traefik/backups/dynamic-live-YYYY-MM-DD-HHMMSS.tgz

Verification Cheatsheet
Show file-provider routers

curl -ks https://traefik.shome/api/http/routers \
| jq 'map(select(.provider=="file")) | map(.name) | sort'

Show file-provider middlewares
curl -ks https://traefik.shome/api/http/middlewares \
| jq 'map(select(.provider=="file")) | map(.name) | sort'

Detect duplicate router rules (should be empty)
curl -ks https://traefik.shome/api/http/routers \
| jq 'map({name,provider,rule,service})
      | group_by(.rule)
      | map(select(length>1))'

Notes & Gotchas
Why verification uses Host/SNI behavior

Your Traefik API/dashboard route typically matches:

Host(\traefik.shome`)→api@internal`

So curl https://127.0.0.1/... can return a default cert + 404 even if Traefik is healthy,
because the Host header is wrong. Use https://traefik.shome/... (or the scripts that use --resolve).

Avoid config “ghosts”

Do not keep old YAML in the watched directory:
/opt/netlab-stack/traefik/dynamic/

Store archives in:
/opt/netlab-stack/traefik/dynamic-archive/

Permissions and security
/opt/netlab-stack/traefik/acme is intentionally restrictive (private-ish).
Treat /opt/git/Docker on the server as a pull-only working copy (no manual edits).

Quick D&R Summary

Deploy:
sudo /usr/local/sbin/edge-sync-traefik-dynamic

Recover:
sudo /usr/local/sbin/edge-rollback-traefik-dynamic


---

## In GitHub, it should look like this
- The code blocks show up in grey boxes
- The headings are large/bold
- No weird `EOF` lines anywhere

If you want, after you paste it, take a screenshot of the preview tab and I’ll confirm it looks right.



