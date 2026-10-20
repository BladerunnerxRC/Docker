# Borg Backup — Session Handoff

> State as of 2026-10-20. Read this first, then continue from "Next steps".
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

## 3.0.0 — branch `borg-local-script-backups`, PR #28 (ready to merge: CI green, no conflicts)
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
| `borg-local-script-backups` | 3.0.0, tested and deployed on optiplex-two | merge PR #28, then delete |
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
- Redeployed 2026-10-20 00:00 (commit 7384f01, sha256 `c86c602f…`) with the versioned Checkmk
  archive name: 0 warnings, 30 s, `checkmk-cmk-2.5.0p16.community-20261020-000029.omd.tar`
  (1.8 GB). Checkmk is 2.5.0p16 (≥ p9 ✓).
- Borg UI plan changed 2026-10-20: exclude `/data/compose/14` added (keeps `/data/compose/11`,
  `12`, `19` - small Portainer stack folders), old `sh:data/compose/14/statup/postgres` removed.
- Borg UI run 2026-10-20 00:04: pre-backup green 22 s; archive has
  `databases/checkmk-cmk-2.5.0p16.community-20261020-000411.omd.tar`; no statping paths; prune,
  compact, check OK. The omd tar added only ~112 MB of new deduplicated data (chunks shared with
  the live volume already in the repo). Backup step still "Warnings": `FileChangedWarning` on the
  live `checkmk_checkmk-sites` volume (`rrdcached/rrd.journal.*`, `log/apache/stats`) - see TODO 1.
- `/home/thomas` now in the snapshot includes `Synology/` installers and a manual
  `checkmk-backups/cmk-2026-10-14.tar.gz`; optional to move out (re-downloadable / superseded).
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
   optiplex-two: done (plan includes it, marker set 2026-10-19). optiplex-three and smiddleware: unknown.
2. **Live KodiDB entity.** Was the Borg UI script entity fixed by hand, or is it still pointing at
   `192.168.1.20`? Check the entity in Borg UI → Scripts, and its last run log.
3. **Matomo host.** What does `MATOMO_DOCKER_HOST` resolve to in the Borg UI entity, and is
   `/var/backups/borg-matomo/latest` in that host's plan?
4. **`claude-discovery`.** Is the read-only discovery account
   ([`claude-discovery/`](claude-discovery/)) installed on any host? `id claude; ls -l /usr/local/sbin/claude-discovery`
5. **Restore test.** No record of a test restore. The README restore flow is untested end to end.
6. **Last good archive per repo** — check Borg UI, or `borg list --last 1` against each repo.

## TODO
First merge PR #28 into `main` (ready: CI green, no conflicts). Then:

- [ ] **1. optiplex-two: stop the live Checkmk volume warnings.** In the Borg UI plan, add the exclude
  `/var/lib/docker/volumes/checkmk_checkmk-sites` (recommended: the `omd backup` archive is the
  restore source, and a failed omd backup shows as a pre-backup warning). If you'd rather keep the
  raw volume as a fallback, exclude only
  `sh:/var/lib/docker/volumes/checkmk_checkmk-sites/_data/cmk/var/rrdcached/**` and
  `sh:/var/lib/docker/volumes/checkmk_checkmk-sites/_data/cmk/var/log/**`.
  Then run the plan twice and record the second run's deduplicated size here: that is the
  steady-state nightly cost of the 1.8 GB omd archive.
- [ ] **2. optiplex-three: deploy 3.0.0 from `main`.**
  ```bash
  mkdir -p ~/scripts/borgbackup && cd ~/scripts/borgbackup
  curl -fsSLO https://raw.githubusercontent.com/BladerunnerxRC/Docker/main/borg-backup/pull-borg-scripts.sh
  chmod 750 pull-borg-scripts.sh && ./pull-borg-scripts.sh
  sudo ./deploy-borg-prep-optiplex-three.sh --test
  ```
  Expect the diff to show only the 3.0.0 changes (script-copy section, `borg-survey-*` exclude).
  Check the test run's summary: "Prep script + rollback copies" OK, warnings explained. Its 2.x
  backups on the share stay where they are. Old `~/borg-backup-scripts` can be deleted afterwards.
- [ ] **3. smiddleware: regenerate with survey 3.0.0** (same flow as optiplex-two): pull from
  `main` into `~/scripts/borgbackup` (smiddleware's deploy script is checked in, so the pull works),
  run a fresh `sudo ./borg-backup-survey.sh`, answer **N** at the deploy offer, review the generated
  script against the hand-written one (AdGuard, Traefik, Dashy volume, portracker), deploy with
  `--test`, send the script to be committed. Resolve open item 1 there (named volumes in the plan,
  then set the marker).

## Later
- Fix the live KodiDB Borg UI entity if open item 2 says it still points at `192.168.1.20`.
- optiplex-two cleanup: delete the old survey folders and old survey script in `~/scripts`
  (`sudo rm -rf ~/scripts/borg-survey-optiplex-two-2026*`, `~/scripts/borg-backup-survey.sh*`).
- Backup-age monitoring (Checkmk handoff step 11): Checkmk local check on each source host,
  CRIT if the last good archive is > 26 h old. DSM can't see Borg client failures.
- Do one real restore drill into `/restore` (e.g. portracker SQLite or the Checkmk omd archive)
  and record the result here.
- Housekeeping: delete the branches listed above; fill or remove the README screenshot
  placeholders; optional summary-table column width fix (survey change).

## Related
- [`checkmk/HANDOFF-POC.md`](../checkmk/HANDOFF-POC.md) — steps 11 (backup-age check) and 13 (`checkmk-sites` in Borg).
