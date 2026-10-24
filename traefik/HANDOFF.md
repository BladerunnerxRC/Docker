# Traefik Sync Script — Session Handoff

> State as of 2026-10-24. Read this first, then continue from "Next steps".
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
- Branch **`fix-traefik-sync-script`** (from `main` at `4880d3c`), **committed and pushed**.
- **Not yet run on smiddleware.** Only `bash -n`, `--help`, unknown-option rejection and the
  `git archive | tar` extract step were checked, on Windows. shellcheck wasn't run: it isn't
  installed and Docker couldn't pull the image (credential-helper error).
- **Live config had drifted ahead of the repo** (hand edits on the server, 2026-10-05): webmin
  Host-header middlewares, `webmin-optiplex-three` router/service, `wud` service,
  `passHostHeader: true` on webmin, and `grafana`/`nocodb`/`rancher` removed. On 2026-10-24 the
  live `*.yml` were copied back into `traefik/dynamic/` on this branch, so a deploy should now
  be a no-op apart from blank lines.
- Read-only checks on smiddleware (2026-10-24, as thomas over SSH; `thomas` is in the `docker`
  group, sudo needs a password):
  - Step 2 prerequisites all OK: `python3-yaml` (6.0.2), `rsync`, `jq`, `flock`; `/opt/git/Docker`
    owned by thomas (on `main`, behind origin, irrelevant since the script reads `origin/<branch>`);
    live `dynamic/` is `thomas:thomas 0755`; Traefik `v3.7.10`.
  - Step 4 baseline: **zero** `level=error`/` ERR ` lines in 48 h (container up 2 days).
- **2026-10-24 on smiddleware, steps 2–6 done:**
  - `traefik-dynamic-archive.sh` moved out of the watched folder to `/usr/local/sbin/`.
  - Branch scripts installed in `/usr/local/sbin` (md5 matches the branch); old ones kept in
    `~/edge-scripts-old-20261024/`.
  - Dry run behaved: whole-file diffs only from CRLF→LF, no staging dir left, clone untouched.
  - Real run of `78d7fab`: exit 0, Traefik up after 2 s, no log errors. Backup
    `/opt/netlab-stack/traefik/backups/dynamic-live-2026-10-24-140640.tgz`. All routes
    answered 200/302 except `dockhand` and `wud` (502, backends down).
  - Traefik logs at **DEBUG**. Level token is ` DBG `/` ERR `, so the filter still works;
    DEBUG lines with `error=` don't match.
- **Dockhand and wud are retired**: their routers/services removed from the repo after the
  deploy above, to be used as the change for the rollback test (step 7).
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
Steps 1–6 are done (see State); continue at step 7.

1. ~~Commit and push the branch.~~ Done.
2. ~~Check prerequisites on smiddleware; move `traefik-dynamic-archive.sh` out of the watched
   folder.~~ Done 2026-10-24.
3. Install the **branch** copies into `/usr/local/sbin` (README → "Install / update the scripts",
   branch variant). Keep a copy of the old ones first:
   `sudo cp /usr/local/sbin/edge-*-traefik-dynamic ~/`.
4. ~~Baseline the log check.~~ Done 2026-10-24: no errors at all in 48 h. Re-run just before
   step 6 if days have passed. Original note:
   ACME issue/renewal errors name the router (e.g. `routerName=komga@file`), so they'd match
   the filter and make a good deploy exit 30:
   ```bash
   docker logs --since 48h traefik 2>&1 | grep -E 'level=error| ERR ' \
     | grep -E '@file|providerName=file|/etc/traefik/dynamic' | sort | uniq -c | head -40
   ```
   If this shows recurring ACME/renewal lines, change both scripts to report those as a
   warning instead of failing, before step 6.
5. `sudo edge-sync-traefik-dynamic --dry-run --branch fix-traefik-sync-script`
   **Read the diff carefully.** The Oct 5 hand edits are already in the repo, so expect only
   `deleting traefik-dynamic-archive.sh` if step 2's move wasn't done, plus
   `10-middlewares.yml`, `20-routers.yml`, `30-services.yml` showing as changed: live has
   **CRLF** line endings (edited from Windows), the repo has LF. Content is otherwise identical
   (checked 2026-10-24 with `diff --strip-trailing-cr`), so the deploy just normalises them to LF.
   Any real `-` line means live changed again since 2026-10-24: copy it into the repo first.
6. Real run: `sudo edge-sync-traefik-dynamic --branch fix-traefik-sync-script`.
   **Exit 30 means the new config IS live and Traefik logged errors about it.** Read the
   printed lines before deciding whether to run the rollback command it prints.
7. Test rollback using the dockhand/wud removal: dry-run (expect only those `-` lines), deploy
   (both hosts 502 → 404), `sudo edge-rollback-traefik-dynamic --list`, roll back to the backup
   that deploy printed (both back to 502), then deploy again (404).
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
- ~~`rancher` service with undefined `rancher-https` transport~~ and ~~services with no router
  (`grafana`, `nocodb`)~~: gone, resolved by pulling the live config back (2026-10-24).
- [`dynamic/20-routers.yml`](dynamic/20-routers.yml): `k3s-catchall` uses v2 syntax
  ``HostRegexp(`{name:[a-z0-9-]+}.shome`)``. On v3 it's read as a literal regex and matches
  nothing. v3 form: ``HostRegexp(`^[a-z0-9-]+\.shome$`)``. Note: once it works, it catches
  **every** `*.shome` host that has no other router (priority 10) and sends it to k3s.
- Service with no router: `whoami` (file provider). Harmless.
- `traefik.yml` (static config) isn't deployed by any script; it's mounted from
  `/opt/netlab-stack/traefik/traefik.yml` and needs a manual copy + restart.
- Possible follow-up: add `scripts/sbin/*` to CI with `bash -n` + shellcheck, like
  `.github/workflows/borg-backup.yml`.
