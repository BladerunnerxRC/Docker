# Traefik Sync Script — Session Handoff

> State as of 2026-10-24 (end of session). Read this first, then continue from "Next steps".
> Reference material (layout, D&R flow, backups, install commands) lives in
> [`README.md`](README.md); this file records only state, open items and what to do next.

## Goal
Get `edge-sync-traefik-dynamic` working again so Traefik's file-provider config on
smiddleware is deployed from GitHub safely: back up live (locally + NAS), pull, validate,
apply, verify, with a working rollback.

## Decisions made
- **Repo stays public.** Reviewed 2026-10-23: no secrets are committed (`.htpasswd`,
  `acme.json`, certs, `.env` are gitignored). `traefik/dynamic/` does expose internal IPs,
  `.shome` hostnames and which hosts run Webmin/Portainer/HA, so it's a network map useful
  only to someone already on the LAN. Every script imported from the server is read in full
  for secrets before committing.
- **Fix the existing scripts** rather than write a new one.
- **All scripts for this process live in [`traefik/scripts/`](scripts/)** (user request,
  2026-10-24). Edge-stack-wide ones (`edge-stack-bootstrap-dirs`, `edge-cert-check`) stay in
  `scripts/sbin/`. Unrelated server scripts (borg, `srm_export_leases.py`, `safe-*`) are not
  imported; borg already backs them up.
- **Backups:** local copy in `/opt/netlab-stack/traefik/backups/` is the rollback source; each
  backup is also copied to the NAS at `/mnt/backups/traefik-config-scripts/`, best effort
  (warns, never fails the run).
- **API checks are optional.** Router listing only runs if a root-only netrc exists; pass/fail
  is based on HTTPS readiness + Traefik's own log, which need no credentials.
- **Keep `docker restart`** after applying, as before. Strictly unneeded (`watch: true` hot-reloads).

## State

### PRs (all pushed)
| PR | Branch → base | Content | Status |
|---|---|---|---|
| [#34](https://github.com/BladerunnerxRC/Docker/pull/34) | `fix-traefik-sync-script` → `main` | Sync/rollback fix, scripts moved to `traefik/scripts/`, NAS copy, dynamic config (Oct 5 live edits pulled back, dockhand/wud removed) | **Draft** until step 1 below passes |
| [#35](https://github.com/BladerunnerxRC/Docker/pull/35) | `fix-edge-bootstrap-dirs` → `main` | `scripts/sbin/edge-stack-bootstrap-dirs` was a pasted `sudo tee <<EOF` installer, not the script; now the real script, duplicate `scripts/edge-stack-bootstrap-dirs.sh` removed | Ready; independent of #34 |
| [#36](https://github.com/BladerunnerxRC/Docker/pull/36) | `traefik-import-server-scripts` → `fix-traefik-sync-script` | Imports `traefik-dynamic-archive.sh`, `legacy/sync-dynamic.sh` (retired, guarded `exit 1`), `legacy/mkcert-traefik-refresh.sh` (unused; reviewed, no secrets) + README "All Traefik scripts" table | Stacked on #34; GitHub retargets it to `main` when #34 merges |

Local checkout was left on `traefik-import-server-scripts` (top of the stack, shows every
script in `traefik/scripts/`).

### smiddleware (as of 14:12, 2026-10-24)
- **Live config = `6d98cf1`** (dockhand/wud removed), deployed with the fixed script, exit 0.
  All active routes 200/302; `dockhand.shome`/`wud.shome` 404.
- Backups so far (local only, made before NAS copy existed):
  `/opt/netlab-stack/traefik/backups/dynamic-live-2026-10-24-140640.tgz` (Oct 5 config, CRLF)
  and `...-141207.tgz` (still has dockhand/wud → the rollback-test target).
- **Installed in `/usr/local/sbin`: the `78d7fab`-era scripts, WITHOUT the NAS copy.** The
  current #34 scripts (`c69de10`) are not installed yet.
- Old Dec 2025 scripts saved in `~/edge-scripts-old-20261024/`.
- `traefik-dynamic-archive.sh` moved out of the watched folder to `/usr/local/sbin/`.
- `/opt/netlab-stack/traefik/sync-dynamic.sh` (old, dangerous) **still on the server**.
- `~/mkcert-traefik-refresh.sh`: temporary review copy (0600), can be deleted.
- Clone `/opt/git/Docker` is on pre-flatten `main` (`7224e63`, 215 commits behind). The sync
  doesn't depend on it (reads `origin/<branch>`).
- Access: SSH alias `smiddleware` works as thomas with a key; thomas is in `docker` group;
  **sudo needs a password**, so every root step is run by the user.

### Verified
- Prerequisites, Traefik error baseline (zero errors in 48 h), dry run (no staging left, clone
  untouched), two real deploys with exit 0 and route checks.
- `nas_copy` tested on smiddleware as thomas (copy OK / denied → warn / not mounted → skip /
  disabled), with `set -E` + `ERR` trap: never trips the trap.

### Not verified yet
- **Root can write `/mnt/backups/traefik-config-scripts`.** thomas gets "Permission denied"
  although the folders show 0777 (NFSv4 from `192.168.200.3:/volume1/SYSBAK_borgrepos_smiddleware`),
  so it depends on Synology's NFS squash setting.
- Rollback with the new scripts; NAS copy in a real run.
- Root's crontab (`sudo crontab -l`) was never checked for anything calling these scripts.

## What was wrong and what changed

### edge-sync-traefik-dynamic
| Problem (old script) | Fix |
|---|---|
| `SRC` still pointed at `stacks/edge-stack/traefik/dynamic` (pre-flatten), so every run aborted at step 2. **No deploys since 2026-07-01.** | Source is `traefik/dynamic`, read straight from `origin/<branch>` with `git archive`. |
| Ignored all arguments, so the README's `--dry-run` would have done a **real deploy**. | `--help`, `--dry-run`, `--list-backups`, `--branch NAME`; anything else is rejected. |
| YAML was validated **after** rsync into the watched folder, so with `watch: true` a broken file was already live. | Extract to a staging dir outside the watched folder (`/opt/netlab-stack/traefik/.sync-staging-*`), validate there, then rsync. An empty source is refused (rsync `--delete` would wipe live). |
| Backup was `\|\| true`, so a failed backup still went on to overwrite live. | Backup is required; the run stops if it fails. Then copied to the NAS (best effort). |
| `rsync ... \|\| true` hid copy errors. | No `\|\| true`. |
| Waited on `https://127.0.0.1:8080/api/overview`, which nothing serves (no `api.insecure`, port not published), so every run would restart Traefik and then fail. | Ready = any HTTP status from `https://127.0.0.1/` (404 is normal), then a 5 s settle. |
| No real verification. | Fails (exit 30) if `docker logs --since <apply time>` has error lines (`level=error` or ` ERR `) that mention `@file`, `providerName=file` or `/etc/traefik/dynamic`. |
| `ssh-keyscan` added a fresh unverified GitHub key to **root's** known_hosts each run; git runs as thomas, and ssh reads the home directory from the user database, not `$HOME`, so it was never used. | Removed. |
| No way back after a bad apply except knowing the backup name. | Any failure after the apply prints `sudo edge-rollback-traefik-dynamic <exact backup>`. Deployed commit is logged. |
| — | `flock` on `/run/edge-sync-traefik.lock`, shared with rollback. Stops early with "Nothing to do" if live already matches. |

### edge-rollback-traefik-dynamic
- Same broken 8080 readiness check, now the same HTTPS check + log scan.
- `tar -xzf` over live left behind files added since the backup, which kept loading as ghost
  routers. Now: extract to staging, then `rsync --delete` into live.
- Pre-rollback archive was `|| true`; now required, and copied to the NAS (best effort).
- Unknown `-options` are rejected; root/args checked before touching `/var/log`.

## Next steps (in order, all on smiddleware with sudo unless noted)
1. **Finish testing #34:**
   ```bash
   # a. root can write the NAS folder? (if this fails, stop: Synology NFS export squashes root)
   sudo touch /mnt/backups/traefik-config-scripts/.w && sudo rm /mnt/backups/traefik-config-scripts/.w && echo NAS_OK

   # b. one-off: existing backups + old scripts to the NAS
   sudo cp /opt/netlab-stack/traefik/backups/dynamic-live-2026-10-24-*.tgz /mnt/backups/traefik-config-scripts/
   sudo mkdir -p /mnt/backups/traefik-config-scripts/scripts-old-20261024
   sudo cp ~/edge-scripts-old-20261024/* /mnt/backups/traefik-config-scripts/scripts-old-20261024/

   # c. retire the old sync script
   sudo mv /opt/netlab-stack/traefik/sync-dynamic.sh ~/edge-scripts-old-20261024/

   # d. install the current #34 scripts (path is now traefik/scripts/)
   B=fix-traefik-sync-script
   git -C /opt/git/Docker fetch origin "+refs/heads/$B:refs/remotes/origin/$B"
   for s in edge-sync-traefik-dynamic edge-rollback-traefik-dynamic; do
     git -C /opt/git/Docker show "origin/$B:traefik/scripts/$s" > "/tmp/$s"
     sudo install -m 0755 "/tmp/$s" /usr/local/sbin/ && rm -f "/tmp/$s"
   done

   # e. rollback test: expect dockhand/wud back to 502 + a nas_copy=...dynamic-pre-rollback-*.tgz line
   sudo edge-rollback-traefik-dynamic /opt/netlab-stack/traefik/backups/dynamic-live-2026-10-24-141207.tgz

   # f. redeploy: expect 404 again + a nas_copy=...dynamic-live-*.tgz line
   sudo edge-sync-traefik-dynamic --branch fix-traefik-sync-script

   # g. check the NAS
   sudo ls -l /mnt/backups/traefik-config-scripts /mnt/backups/traefik-config-scripts/scripts-old-20261024
   rm -f ~/mkcert-traefik-refresh.sh
   ```
   Route check (no sudo; Claude can run it over SSH):
   `for h in dockhand wud komga webmin-mid; do printf "%-12s %s\n" $h "$(curl -sk -o /dev/null -m 5 -w '%{http_code}' --resolve $h.shome:443:127.0.0.1 https://$h.shome/)"; done`
   A no-op deploy stops at "Nothing to do" before the backup, so it never tests the NAS copy.
2. Mark #34 ready, merge it (then #36, retargeted to `main`, and #35 in any order).
3. Reinstall from `main` (README → Install, "from main") and run once with no options. That
   run hard-resets `/opt/git/Docker` to the current layout. After #35:
   `sudo install -m 0755 scripts/sbin/edge-stack-bootstrap-dirs /usr/local/sbin/` (replaces
   the 3-line wrapper that points at the pre-flatten path; don't run it on the live host).
4. Check `sudo crontab -l` for anything still calling the old paths or `sync-dynamic.sh`.

## Things to verify on the host (assumptions not yet tested)
- **Log filter matches real errors.** Assumes Traefik v3 writes errors with ` ERR ` and that
  file-provider errors mention `@file` / `providerName=file`. Best test: a throwaway branch with
  a router that points at a missing service; deploy it with `--branch`, expect exit 30 and the
  rollback hint, then roll back. If the filter misses it, look at the real line in
  `docker logs traefik` and adjust the `grep -E` in both scripts. (Traefik logs at **DEBUG**;
  DEBUG lines containing `error=` don't match, which is correct.)
- **Optional API listing.** Assumes a request to the host's own LAN IP reaches Traefik with
  that IP as source, so it passes `traefik-ipallow`. If it returns 403 it's reported as SKIP;
  set `API_IP` or drop the feature.
- **Line endings.** Working tree is CRLF (`core.autocrlf=true`); after `git add`,
  `git ls-files --eol traefik/scripts` must still show `i/lf`. New executable files need
  `git add --chmod=+x` (`core.filemode=false`).

## Open items (not changed, reported only)
- [`dynamic/20-routers.yml`](dynamic/20-routers.yml): `k3s-catchall` uses v2 syntax
  ``HostRegexp(`{name:[a-z0-9-]+}.shome`)``. On v3 it matches nothing. v3 form:
  ``HostRegexp(`^[a-z0-9-]+\.shome$`)``. Once it works it catches **every** `*.shome` host
  without its own router (priority 10), including retired ones like dockhand/wud, and sends
  them to k3s.
- Service with no router: `whoami` (file provider). Harmless.
- Nothing prunes old backups (local `backups/`, `dynamic-archive/`, or the NAS folder).
- Traefik runs at DEBUG log level: high log volume.
- `edge-cert-check` (`scripts/sbin/`) is not installed on smiddleware.
- `traefik.yml` (static config) isn't deployed by any script; it's mounted from
  `/opt/netlab-stack/traefik/traefik.yml` and needs a manual copy + restart.
- `/opt/netlab-stack/traefik/certs/` still holds the unused mkcert cert/key + `.bak`/`.tst`
  copies and the original `mkcert-traefik-refresh.sh`.
- Possible follow-up: add `traefik/scripts/*` and `scripts/sbin/*` to CI with `bash -n` +
  shellcheck, like `.github/workflows/borg-backup.yml`.
