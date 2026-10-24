# Traefik Sync Script — Session Handoff

> State as of 2026-10-23. Read this first, then continue from "Next steps".
> Reference material (layout, D&R flow, install commands) lives in [`README.md`](README.md);
> this file records only state, open items and what to do next.

## Goal
Get `edge-sync-traefik-dynamic` working again so Traefik's file-provider config on
smiddleware is deployed from GitHub safely: back up live, pull, validate, apply, verify,
with a working rollback.

## Decisions made
- **Repo stays public.** Reviewed 2026-10-23: no secrets are committed (`.htpasswd`,
  `acme.json`, certs, `.env` are gitignored). `traefik/dynamic/` does expose internal IPs,
  `.shome` hostnames and which hosts run Webmin/Portainer/HA, so it's a network map useful
  only to someone already on the LAN. A private repo would only hide future changes anyway;
  history is already public.
- **Fix the existing scripts** rather than write a new one.
- **API checks are optional.** Router listing only runs if a root-only netrc exists; pass/fail
  is based on HTTPS readiness + Traefik's own log, which need no credentials.
- **Keep `docker restart`** after applying, as before. Strictly unneeded (`watch: true` hot-reloads).

## State
- Branch **`fix-traefik-sync-script`** (from `main` at `4880d3c`).
- **Not committed, not pushed, not tested on smiddleware.** Only `bash -n`, `--help`, unknown-option
  rejection and the `git archive | tar` extract step were checked, on Windows. shellcheck
  wasn't run: it isn't installed and Docker couldn't pull the image (credential-helper error).
- Changed files:
  - [`scripts/sbin/edge-sync-traefik-dynamic`](../scripts/sbin/edge-sync-traefik-dynamic) — rewritten
  - [`scripts/sbin/edge-rollback-traefik-dynamic`](../scripts/sbin/edge-rollback-traefik-dynamic) — fixed
  - [`README.md`](README.md) — known-issue section removed, steps corrected, install/test section added
  - this file, plus a pointer in the root `CLAUDE.md`

## What was wrong and what changed

### edge-sync-traefik-dynamic
| Problem (old script) | Fix |
|---|---|
| `SRC` still pointed at `stacks/edge-stack/traefik/dynamic` (pre-flatten), so every run aborted at step 2. **No deploys since 2026-07-01.** | Source is `traefik/dynamic`, read straight from `origin/<branch>` with `git archive`. |
| Ignored all arguments, so the README's `--dry-run` would have done a **real deploy**. | `--help`, `--dry-run`, `--list-backups`, `--branch NAME`; anything else is rejected. |
| YAML was validated **after** rsync into the watched folder, so with `watch: true` a broken file was already live. | Extract to a staging dir outside the watched folder (`/opt/netlab-stack/traefik/.sync-staging-*`), validate there, then rsync. An empty source is refused (rsync `--delete` would wipe live). |
| Backup was `\|\| true`, so a failed backup still went on to overwrite live. | Backup is required; the run stops if it fails. |
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
- Pre-rollback archive was `|| true`; now required.
- Unknown `-options` are rejected; root/args checked before touching `/var/log`.

## Next steps (in order)
1. **Review the diff** (`git diff main`), then commit and push the branch. The server can only
   test it once it's on GitHub.
2. On smiddleware, check the prerequisites: `python3-yaml`, `rsync`, `jq`, `flock` (util-linux)
   are installed; `/opt/git/Docker` is a clone owned by thomas; `ls -ld /opt/netlab-stack/traefik/dynamic`
   (staging copies this owner/mode).
3. Install the **branch** copies into `/usr/local/sbin` (README → "Install / update the scripts",
   branch variant). Keep a copy of the old ones first:
   `sudo cp /usr/local/sbin/edge-*-traefik-dynamic ~/`.
4. **Baseline the log check** before any real run, so you know what "normal" looks like.
   ACME issue/renewal errors name the router (e.g. `routerName=komga@file`), so they'd match
   the filter and make a good deploy exit 30:
   ```bash
   docker logs --since 48h traefik 2>&1 | grep -E 'level=error| ERR ' \
     | grep -E '@file|providerName=file|/etc/traefik/dynamic' | sort | uniq -c | head -40
   ```
   If this shows recurring ACME/renewal lines, change both scripts to report those as a
   warning instead of failing, before step 6.
5. `sudo edge-sync-traefik-dynamic --dry-run --branch fix-traefik-sync-script`
   **Read the diff carefully.** Live hasn't been synced since 2026-07-01, so any hand edits on
   the server will show as `-` lines and would be removed. Copy anything worth keeping into the
   repo first.
6. Real run: `sudo edge-sync-traefik-dynamic --branch fix-traefik-sync-script`.
   **Exit 30 means the new config IS live and Traefik logged errors about it.** Read the
   printed lines before deciding whether to run the rollback command it prints.
7. Test rollback: `sudo edge-rollback-traefik-dynamic --list`, then roll back to the backup from
   step 6, then deploy again.
8. Merge the PR, then reinstall from `main` and run once with no options.

## Things to verify on the host (assumptions I couldn't test)
- **Log filter matches real errors.** I assumed Traefik v3 writes errors with ` ERR ` and that
  file-provider errors mention `@file` / `providerName=file`. Best test: a throwaway branch with
  a router that points at a missing service; deploy it with `--branch`, expect exit 30 and the
  rollback hint, then roll back. If the filter misses it, look at the real line in
  `docker logs traefik` and adjust the `grep -E` in both scripts.
- **Optional API listing.** It assumes a request to the host's own LAN IP reaches Traefik with
  that IP as source (Docker DNAT, no masquerade), so it passes `traefik-ipallow`. If it returns
  403, it's just reported as SKIP; set `API_IP` or drop the feature.
- **Line endings.** Working tree is CRLF (`core.autocrlf=true`); after `git add`,
  `git ls-files --eol scripts/sbin` must still show `i/lf`.

## Open items (not changed, reported only)
- [`dynamic/30-services.yml`](dynamic/30-services.yml): `rancher` uses
  `serversTransport: rancher-https`, which isn't defined in `00-servers-transports.yml`.
  No router points at `rancher`, so it may not error today. Either define the transport or
  delete the service. If it does log an error, the new log check fails the deploy (exit 30),
  so check this before step 6.
- [`dynamic/20-routers.yml`](dynamic/20-routers.yml): `k3s-catchall` uses v2 syntax
  ``HostRegexp(`{name:[a-z0-9-]+}.shome`)``. On v3 it's read as a literal regex and matches
  nothing. v3 form: ``HostRegexp(`^[a-z0-9-]+\.shome$`)``. Note: once it works, it catches
  **every** `*.shome` host that has no other router (priority 10) and sends it to k3s.
- Services with no router: `grafana`, `nocodb`, `whoami` (file provider). Harmless.
- `traefik.yml` (static config) isn't deployed by any script; it's mounted from
  `/opt/netlab-stack/traefik/traefik.yml` and needs a manual copy + restart.
- Possible follow-up: add `scripts/sbin/*` to CI with `bash -n` + shellcheck, like
  `.github/workflows/borg-backup.yml`.
