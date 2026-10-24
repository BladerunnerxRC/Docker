# Edge Stack — Traefik Dynamic Config + D&R (Deploy & Recover)

![Traefik](https://img.shields.io/badge/proxy-traefik%20v3-24A1C1?logo=traefikproxy&logoColor=white)
![Provider](https://img.shields.io/badge/provider-file-0F766E)
![TLS](https://img.shields.io/badge/tls-step--ca-F59E0B)
![Host](https://img.shields.io/badge/host-smiddleware-6C757D)
![Bash](https://img.shields.io/badge/scripts-bash-4EAA25?logo=gnubash&logoColor=white)

This `edge-stack` includes Traefik (reverse proxy), AdGuardHome, and supporting apps.  
The goal of this doc is to describe the **dynamic config files** and the **D&R workflow** used to deploy and recover safely on the host.

> [!NOTE]
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

> [!NOTE]
> This path used to be `stacks/edge-stack/traefik/dynamic/`. The repo was
> flattened in `e23e361` (2026-07-01) and every stack moved up to the repo root.
> `edge-sync-traefik-dynamic` read the old path until it was fixed on the
> `fix-traefik-sync-script` branch, so deploys did nothing between those dates.

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

```text
/opt/netlab-stack/traefik/
  dynamic/          # live file-provider YAMLs Traefik watches
  acme/             # ACME storage (sensitive; private-ish material)
  certs/            # local cert assets (if used)
  stepca/           # step-ca integration assets (if used)
  backups/          # tar backup made before each deploy (also copied to the NAS)
  dynamic-archive/  # pre-rollback snapshots + old folders moved out of watched dir
```

### Why `dynamic-archive/` matters

> [!WARNING]
> Traefik’s **file provider loads any YAML** under the watched directory.
> Keeping old configs inside something like `/opt/netlab-stack/traefik/dynamic/backup/`
> can reintroduce “ghost” routers/services.

✅ We keep any archival content **outside** the watched directory:

```text
/opt/netlab-stack/traefik/dynamic-archive/
```

---

## D&R Scripts (Deploy & Recover)

### Installed scripts

These are installed on smiddleware. The copies in [`traefik/scripts/`](scripts/) are the
source; merging does **not** update `/usr/local/sbin`, so install after every change (see
[Install / update the scripts](#install--update-the-scripts)):

```text
/usr/local/sbin/
  edge-stack-bootstrap-dirs
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
sudo /usr/local/sbin/edge-stack-bootstrap-dirs
```

### 2) Deploy (standard operation)

This is your “Deploy” in D&R.

What it does:

1. Fetch `origin/main` and hard-reset the clone (pull-only server model)
2. Extract `traefik/dynamic/` into a staging folder **outside** the watched folder
3. Validate YAML in staging — if it fails, live is never touched
4. Compare live with the repo; stop if they already match (`--dry-run` shows the diff and stops here)
5. Create tar backup of the current live dynamic config (the run stops if this fails),
   then copy it to the NAS (a failed copy only warns; see [Backups](#backups))
6. `rsync --delete` staging → live dynamic
7. Restart Traefik
8. Wait until Traefik answers HTTPS on `127.0.0.1` (any status, no API or login needed)
9. Fail if Traefik logged file-provider errors since step 6; list file-provider
   routers/middlewares through the API only if a credentials file exists (below)

If anything fails after step 6, the script prints the exact rollback command.

Run:

```bash
sudo /usr/local/sbin/edge-sync-traefik-dynamic --dry-run   # always first: read the diff
sudo /usr/local/sbin/edge-sync-traefik-dynamic
```

Help / options:

```bash
sudo /usr/local/sbin/edge-sync-traefik-dynamic --help
sudo /usr/local/sbin/edge-sync-traefik-dynamic --list-backups
sudo /usr/local/sbin/edge-sync-traefik-dynamic --branch <name> [--dry-run]   # test a branch
```

> [!TIP]
> **Optional API listing.** The API sits behind the IP allowlist + basic auth, so the
> scripts only list routers when `/etc/edge-sync/traefik-api.netrc` exists:
>
> ```bash
> sudo install -d -m 0700 /etc/edge-sync
> sudo install -m 0600 /dev/null /etc/edge-sync/traefik-api.netrc
> sudoedit /etc/edge-sync/traefik-api.netrc
> #   machine traefik.shome login tpadmin password <password>
> ```
>
> The request goes to the host's LAN IP (`API_IP` overrides it), because a request to
> `127.0.0.1` reaches Traefik from a Docker `172.x` address that the allowlist refuses.

### Backups

| Made by | Local copy (used for rollback) | NAS copy |
|---|---|---|
| deploy, before applying | `/opt/netlab-stack/traefik/backups/dynamic-live-*.tgz` | `/mnt/backups/traefik-config-scripts/` |
| rollback, before restoring | `/opt/netlab-stack/traefik/dynamic-archive/dynamic-pre-rollback-*.tgz` | same folder |

`/mnt/backups` is the NFS share `192.168.200.3:/volume1/SYSBAK_borgrepos_smiddleware`; only
root can write to it. The copy is skipped with a warning if `/mnt/backups` isn't mounted (so an
unmounted share never fills the local disk) and gives up after 60 s, because the mount is `hard`.
Override with `NAS_DIR=/other/dir`, or turn it off with `NAS_DIR=`. Nothing prunes old
backups yet, in either place.

### Install / update the scripts

Run the **installed** copy, never the one in `/opt/git/Docker`: the sync script resets that
clone while it runs.

```bash
# from main, after merging
cd /opt/git/Docker && git pull --ff-only
sudo install -m 0755 traefik/scripts/edge-sync-traefik-dynamic    /usr/local/sbin/
sudo install -m 0755 traefik/scripts/edge-rollback-traefik-dynamic /usr/local/sbin/

# from a branch, before merging (doesn't touch the clone's checkout)
B=fix-traefik-sync-script
git -C /opt/git/Docker fetch origin "+refs/heads/$B:refs/remotes/origin/$B"
for s in edge-sync-traefik-dynamic edge-rollback-traefik-dynamic; do
  git -C /opt/git/Docker show "origin/$B:traefik/scripts/$s" > "/tmp/$s"
  sudo install -m 0755 "/tmp/$s" /usr/local/sbin/ && rm -f "/tmp/$s"
done
```

### 3) Recover / Rollback (if needed)

This is your “Recover” in D&R.

What it does:

1. Choose latest backup tarball (or user-supplied file)
2. Archive current live dynamic as a safety snapshot (the run stops if this fails)
3. Restore selected tarball via staging + `rsync --delete`, so files added after the
   backup are removed instead of lingering as ghost routers
4. Restart Traefik
5. Wait until Traefik answers HTTPS
6. Fail if Traefik logged file-provider errors; optional API listing as above

Rollback to newest:

```bash
sudo /usr/local/sbin/edge-rollback-traefik-dynamic
```

List backups:

```bash
sudo /usr/local/sbin/edge-rollback-traefik-dynamic --list
```

Rollback to a specific file:

```bash
sudo /usr/local/sbin/edge-rollback-traefik-dynamic /opt/netlab-stack/traefik/backups/dynamic-live-YYYY-MM-DD-HHMMSS.tgz
```

### All Traefik scripts

Every script used for this process is in [`traefik/scripts/`](scripts/):

| Script | Installed at (smiddleware) | Use |
|---|---|---|
| [`edge-sync-traefik-dynamic`](scripts/edge-sync-traefik-dynamic) | `/usr/local/sbin/` | Deploy (above) |
| [`edge-rollback-traefik-dynamic`](scripts/edge-rollback-traefik-dynamic) | `/usr/local/sbin/` | Recover (above) |
| [`traefik-dynamic-archive.sh`](scripts/traefik-dynamic-archive.sh) | `/usr/local/sbin/` | Manual snapshot: `sudo traefik-dynamic-archive.sh` writes `dynamic-archive/dynamic-pre-restore-<ts>.tgz` (the `*.yml` only). Not needed for deploy/rollback, which make their own backups. Lived inside `dynamic/` until 2026-10-24. |
| [`legacy/sync-dynamic.sh`](scripts/legacy/sync-dynamic.sh) | was `/opt/netlab-stack/traefik/` | **Retired**, reference only; exits at once. It synced from the pre-flatten path and validated after going live. |

`edge-stack-bootstrap-dirs` (directory setup) and `edge-cert-check` (daily cert check, not
installed yet) are edge-stack-wide and stay in [`scripts/sbin/`](../scripts/sbin/).

---

## Verification Cheatsheet

> [!IMPORTANT]
> These all hit the Traefik API, which is **NOT** open: `traefik.yml` has no `api.insecure`, so
> `/api` is served only through the `traefik.shome` router, behind `traefik-ipallow@docker` and
> `traefik-auth@docker`. Every call needs credentials from `.htpasswd`. Set the user once and
> let curl prompt for the password:
>
> ```bash
> export TRAEFIK_API_USER=tpadmin
> ```
>
> Without it these return a bare `401` with no JSON, which looks like Traefik is broken.

Show file-provider routers:

```bash
curl -ks -u "$TRAEFIK_API_USER" https://traefik.shome/api/http/routers \
| jq 'map(select(.provider=="file")) | map(.name) | sort'
```

Show file-provider middlewares:

```bash
curl -ks -u "$TRAEFIK_API_USER" https://traefik.shome/api/http/middlewares \
| jq 'map(select(.provider=="file")) | map(.name) | sort'
```

Detect duplicate router rules (should be empty):

```bash
curl -ks -u "$TRAEFIK_API_USER" https://traefik.shome/api/http/routers \
| jq 'map({name,provider,rule,service})
      | group_by(.rule)
      | map(select(length>1))'
```

---

## Notes & Gotchas

### Why verification uses Host/SNI behavior

Your Traefik API/dashboard route typically matches:

``Host(`traefik.shome`)`` → `api@internal`

> [!TIP]
> So `curl https://127.0.0.1/...` can return a default cert + `404` even if Traefik is healthy,
> because the Host header is wrong. Use `https://traefik.shome/...` (or the scripts that use `--resolve`).

### Avoid config “ghosts”

Do not keep old YAML in the watched directory:

```text
/opt/netlab-stack/traefik/dynamic/
```

Store archives in:

```text
/opt/netlab-stack/traefik/dynamic-archive/
```

### Permissions and security

> [!CAUTION]
> `/opt/netlab-stack/traefik/acme` is intentionally restrictive (private-ish).
> Treat `/opt/git/Docker` on the server as a pull-only working copy (no manual edits).

---

## Quick D&R Summary

| | Command |
| --- | --- |
| ![deploy](https://img.shields.io/badge/deploy-16A34A?style=flat-square) | `sudo /usr/local/sbin/edge-sync-traefik-dynamic` |
| ![recover](https://img.shields.io/badge/recover-D97706?style=flat-square) | `sudo /usr/local/sbin/edge-rollback-traefik-dynamic` |
