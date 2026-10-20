# Borg Backup — Session Handoff

> State as of 2026-10-19. Read this first, then continue from "Next steps".
> Reference material (architecture, mounts, script behaviour, restore flow) lives in
> [`README.md`](README.md); this file records only state, open items and what to do next.

## Working style
- Professional, clear, concise. When asked for clarification, answer at an 11th-grade reading level.
- Direct and technical; no sugar-coating. Check work before delivering.
- Scripts: ask for diagnostics/logs before proposing fixes; iterate run → logs → fix.
- "mod and print" = modify the file in progress and print the ENTIRE file.
- Infra/config: stack-ready YAML, commented.
- Suggest continued improvements to code.

## Goal
App-consistent Borg backups of every home-lab host, driven from one Borg UI, with prep scripts
that are versioned in this repo, deployed safely, and restorable without Borg UI.

## Environment
- **Borg UI** (`ainullcode/borg-ui` + redis) runs on **optiplex-docker**, deployed from Portainer
  (mount changes go in the Portainer stack editor *and* [`docker_compose.yml`](docker_compose.yml)).
- **Repos** on the Synology over NFSv4, one share per host, mounted at `/mnt/borg_<host>` →
  `/local/<host>` in the container. Encryption `repokey-blake2` (passphrase only needed to restore).
- **Pre-backup jobs** (Borg UI script entities → SSH → `/usr/local/sbin/...` on the host):

  | Job | Host | Repo script | Notes |
  |---|---|---|---|
  | `borg-prep-appdata-smiddleware.sh` | smiddleware | `borg-backup/` | pre-2.0.0, hand-written |
  | `borg-prep-appdata-optiplex-two.sh` | optiplex-two | `borg-backup/` | **3.0.0**, survey 2026-10-19, matches deployed |
  | `borg-prep-appdata-optiplex-three.sh` | optiplex-three (k3s worker) | `borg-backup/` | **2.0.0**, matches deployed |
  | `borg-prep-kodidb.sh` | optiplex-two (`mariadb-kodi`) | [`KodiDB/`](../KodiDB/) | own Borg job |
  | `borg-prep-matomo.sh` | `$MATOMO_DOCKER_HOST` | [`Matomo/`](../Matomo/) | own Borg job |
  | `borgui-config-export-snapshot` | optiplex-docker (in container) | `borg-backup/` | Borg UI self-backup |

- Host IPs are already public in the README; nothing in this handoff needs a `.local.md`.
- CI: [`.github/workflows/borg-backup.yml`](../.github/workflows/borg-backup.yml) runs `bash -n` on
  `borg-backup/*.sh` and checks that `VERSION`, `SURVEY_VERSION`, `PULL_VERSION` and a
  `## [x.y.z]` CHANGELOG heading all agree. **A version bump must touch all four.**

## Completed (2.0.0, merged to `main` via PR #20, 2026-10-12)
See [`CHANGELOG.md`](CHANGELOG.md) for detail. (3.0.0 changes the backup locations below.)
- `deploy-borg-prep-<host>.sh`: safety checks (wrapper/CRLF/syntax/wrong host), diff, y/N, backup to
  `/mnt/backups/borg-script-backups/<host>/<ts>/` (last 10), `--test/--rollback/--list/--backup-only`.
  Prompted by the 2026-10-06 optiplex-three outage (wrapper copied over the prep script).
- `pull-borg-scripts.sh`: fetches a host's scripts from GitHub (LF endings, checked before write),
  branch pulls go to `~/borg-backup-scripts-<branch>`, dated copy + commit on the Synology.
- Survey 2.0.0: summary table + `metadata/prep-summary.txt`, home-dir coverage without double
  copies, 10G/unmeasurable dirs generated commented out, private output (`umask 077`),
  `--name/--address` validation, offers backup/deploy after generating.
- Named-volume warning: prep scripts `WARN` on every run while Docker named volumes are in use,
  until `/etc/borg-backup/docker-volumes-in-plan` exists.
- optiplex-three prep script regenerated from the 2026-10-11 survey (adds portracker) and deployed.

## In progress — 3.0.0 on branch `borg-local-script-backups` (not merged)
Decided 2026-10-19: hosts do **not** mount a backup share. optiplex-two has no `/mnt/backups`,
and mounting `SYSBAK_borgrepos_<host>` would give each host write access to its own Borg repo.
- Deploy rollback copies → `/var/backups/borg-script-backups/<host>/<ts>/` on the host (last 10).
- Prep scripts copy themselves + those rollback copies into `metadata/` of every snapshot, so Borg
  carries them off-host with no plan change.
- Pull script → `~/scripts/borgbackup` (branch: `~/scripts/borgbackup-<branch>`), no sudo, no share.
- Survey detects Checkmk containers and generates `omd backup --no-compression <site> -` →
  `databases/checkmk-<site>-<version>-<date-time>.omd.tar`. Supersedes the `borg-checkmk-omd-backup` branch.
- Home copies exclude `borg-survey-*/`.
- Deploy scripts for all three hosts are checked in, so the pull works everywhere.
- `borg-optiplex-two-cleanup` (KodiDB wrapper IP fix, statping removal) is merged into this branch.

Tested locally (Windows Git Bash, fake survey state): generated scripts pass `bash -n`; Checkmk
block generated, unsafe site name refused; deploy install → backup → prune → `--backup-only` →
`--rollback` → identical-file and CRLF checks all behave. Then run for real on optiplex-two
(below): pull, survey, deploy `--test` all worked.

## Branches
| Branch | State | Action |
|---|---|---|
| `borg-local-script-backups` | 3.0.0, tested and deployed on optiplex-two | PR to `main` |
| `borg-optiplex-two-cleanup` | merged into `borg-local-script-backups` | delete after the PR merges |
| `borg-checkmk-omd-backup` | superseded by survey Checkmk detection | delete |
| `borg-prep-summary-and-deploy`, `borg-survey-generator-summary` | already in `main` | delete |

## optiplex-two on 3.0.0 (deployed 2026-10-19 23:35 from the branch)
- Fresh survey 3.0.0 in `~/scripts/borgbackup/borg-survey-optiplex-two-20261019-233036/`; the
  `mariadb-kodi` dump block was removed by hand (KodiDB has its own job). Old 2026-08-01 script
  saved in `/var/backups/borg-script-backups/optiplex-two/20261019-233536/`.
- `--test` run: 38 s total. Checkmk `omd backup --no-compression` OK, 1.7 GB in 34 s. Prep script +
  rollback copies OK. Only warning: named volumes (plan already reads `/var/lib/docker/volumes`);
  marker `/etc/borg-backup/docker-volumes-in-plan` set afterwards.
- The checked-in `borg-prep-appdata-optiplex-two.sh` is the deployed file (survey copy confirmed
  identical with `cmp`). Regenerating brings back the `mariadb-kodi` dump block - delete it again.
- Snapshot ~1.8 GB on `/` (58 GB free). Also covers `/home/openclaw` and `/opt/multi-gmail/tokens`
  (OAuth tokens - secret; repo is encrypted).
- Cosmetic: summary labels longer than 36 chars push the Status column out of line.

## Before 3.0.0 on optiplex-two (2026-10-19, after a survey run + manual backup)
- Installed prep script is still the **2026-08-01 (pre-2.0.0)** one: the survey run did not deploy.
  The survey copy on the host (`~/scripts/borg-backup-survey.sh`, Jul 15) predates 2.0.0, so it
  never offered to deploy; there is also no `/mnt/backups` on the host.
- `~/scripts/` holds six old survey folders (`root:root 755`, world-readable `raw/`). Delete them
  or `chmod -R go-rwx` once the new survey is done.
- It still rsyncs `/data/compose/14` (statping) and still has the dead `pg_dumpall`. No statping or
  postgres container exists; `/data/compose/14` is a leftover folder (May 24) copied every run.
  The Borg UI plan **also** backs up `/data/compose/14` directly, so it is archived twice.
- No `omd backup` in the installed script (the `borg-checkmk-omd-backup` branch was never deployed).
- The plan **does** include `/var/lib/docker/volumes` (bambuddy, `checkmk_checkmk-sites` archived).
  Marker `/etc/borg-backup/docker-volumes-in-plan` not set yet.
- Expected recurring warning: `FileChangedWarning` on the live `checkmk_checkmk-sites` volume
  (`var/check_mk/last_job_runs.mk`). Harmless; the `omd backup` archive is the consistent copy.

## Open items — status unknown
Confirm each before acting on it.

1. **Named volumes in each plan.** Does each host's Borg UI plan include
   `/var/lib/docker/volumes` (or `<data-root>/volumes`)? Is the marker set?
   ```bash
   docker info --format '{{.DockerRootDir}}'
   docker ps -q | xargs -r docker inspect --format '{{.Name}}{{range .Mounts}}{{if eq .Type "volume"}} {{.Name}}{{end}}{{end}}'   # named volumes in use
   ls -l /etc/borg-backup/docker-volumes-in-plan
   ```
   On optiplex-two this covers `checkmk_checkmk-sites` (Checkmk handoff step 13).
2. **Live KodiDB entity.** Was the Borg UI script entity fixed by hand, or is it still pointing at
   `192.168.1.20`? Check the entity in Borg UI → Scripts, and its last run log.
3. **Matomo host.** What does `MATOMO_DOCKER_HOST` resolve to in the Borg UI entity, and is
   `/var/backups/borg-matomo/latest` in that host's plan?
4. **`claude-discovery`.** Is the read-only discovery account
   ([`claude-discovery/`](claude-discovery/)) installed on any host? `id claude; ls -l /usr/local/sbin/claude-discovery`
5. **Restore test.** No record of a test restore. The README restore flow is untested end to end.
6. **Last good archive per repo** — check Borg UI, or `borg list --last 1` against each repo.

## Next steps
1. ~~optiplex-two: fresh 3.0.0 survey, remove `mariadb-kodi` block, deploy with `--test`~~ — done
   2026-10-19 (see above). Named-volume marker set. Deployed script committed (identical, `cmp`). Then the Checkmk archive name gained version + date-time (redeployed, below).
   Redeployed 2026-10-20 00:00 (commit 7384f01, sha256 `c86c602f…`): 0 warnings, 30 s, archive
   `checkmk-cmk-2.5.0p16.community-20261020-000029.omd.tar` (1.8 GB). Checkmk is 2.5.0p16 (≥ p9 ✓).
2. ~~Commit the optiplex-two prep script~~ — done.
3. In Borg UI: remove `/data/compose/14` from the optiplex-two plan, run it, and confirm the archive
   has `databases/checkmk-cmk-<version>-<date-time>.omd.tar`, no `statup` paths, 0 pre-backup warnings. Note the
   deduplicated size of the first two runs (how well Borg dedups the 1.7 GB omd tar). Fix the live
   KodiDB entity if open item 2 says so. Clean up the old survey folders in `~/scripts`.
4. Merge the branch to `main` (PR); then optiplex-three: pull from `main`, deploy the 3.0.0 prep
   script with `--test`. Its 2.x share backups stay where they are.
5. Regenerate smiddleware with survey 3.0.0, review, deploy, commit. Resolve open item 1 there.
6. Backup-age monitoring (Checkmk handoff step 11): Checkmk local check on each source host,
   CRIT if the last good archive is > 26 h old. DSM can't see Borg client failures.
7. Do one real restore drill into `/restore` (e.g. portracker SQLite or the Checkmk omd archive)
   and record the result here.
8. Housekeeping: delete the branches listed above; fill or remove the README screenshot placeholders.

## Related
- [`checkmk/HANDOFF-POC.md`](../checkmk/HANDOFF-POC.md) — steps 11 (backup-age check) and 13 (`checkmk-sites` in Borg).
