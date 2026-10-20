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
  | `borg-prep-appdata-optiplex-two.sh` | optiplex-two | `borg-backup/` | pre-2.0.0, survey 2026-08-01 |
  | `borg-prep-appdata-optiplex-three.sh` | optiplex-three (k3s worker) | `borg-backup/` | **2.0.0**, matches deployed |
  | `borg-prep-kodidb.sh` | optiplex-two (`mariadb-kodi`) | [`KodiDB/`](../KodiDB/) | own Borg job |
  | `borg-prep-matomo.sh` | `$MATOMO_DOCKER_HOST` | [`Matomo/`](../Matomo/) | own Borg job |
  | `borgui-config-export-snapshot` | optiplex-docker (in container) | `borg-backup/` | Borg UI self-backup |

- Host IPs are already public in the README; nothing in this handoff needs a `.local.md`.
- CI: [`.github/workflows/borg-backup.yml`](../.github/workflows/borg-backup.yml) runs `bash -n` on
  `borg-backup/*.sh` and checks that `VERSION`, `SURVEY_VERSION`, `PULL_VERSION` and a
  `## [x.y.z]` CHANGELOG heading all agree. **A version bump must touch all four.**

## Completed (2.0.0, merged to `main` via PR #20, 2026-10-12)
See [`CHANGELOG.md`](CHANGELOG.md) for detail.
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

## Unmerged branches
| Branch | Commits | What it does | Merge into `main` |
|---|---|---|---|
| `borg-optiplex-two-cleanup` | 85a25e1, fd4d0bc | optiplex-two: drop dead statping `pg_dumpall` and `/data/compose/14` rsync; **fix KodiDB wrapper SSH target** (`192.168.1.20` placeholder → `192.168.200.14`); remove statping Dashy tile | clean |
| `borg-checkmk-omd-backup` | 81cb2e3 | optiplex-two: hand-added `omd backup cmk -` → `databases/checkmk-cmk.omd.tar.gz` (consistent Checkmk site archive) | clean |
| `borg-prep-summary-and-deploy`, `borg-survey-generator-summary` | none beyond `main` | already merged | delete |

> [!WARNING]
> The two optiplex-two branches merge cleanly into `main` on their own but **conflict with each
> other** (same region of `borg-prep-appdata-optiplex-two.sh` and README). Merge
> `borg-optiplex-two-cleanup` first, then rebase `borg-checkmk-omd-backup` onto `main`.
>
> Until the cleanup branch lands, `KodiDB/BORG_UI-kodidb-prep-dbdump.sh` on `main` still SSHes to
> the placeholder `root@192.168.1.20`.

## Known problem — pull script fails on optiplex-two and smiddleware
`pull-borg-scripts.sh` treats `deploy-borg-prep-<host>.sh` as **required** (only `VERSION` and
`CHANGELOG.md` are optional). Only optiplex-three's deploy script is checked in, so a pull on
optiplex-two or smiddleware dies with "is not on branch main … Nothing was changed."
Fixed by step 3 below (regenerate and commit those hosts' deploy scripts).

## Confirmed on optiplex-two (2026-10-19, after a survey run + manual backup)
- Installed prep script is still the **2026-08-01 (pre-2.0.0)** one: the survey run did not deploy.
  No `/mnt/backups/borg-script-backups/optiplex-two/` exists, so the deploy script never ran there.
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
1. Merge `borg-optiplex-two-cleanup` → `main`; deploy on optiplex-two; fix the live KodiDB entity if (2) says so.
2. Rebase and merge `borg-checkmk-omd-backup`; deploy on optiplex-two; confirm
   `databases/checkmk-cmk.omd.tar.gz` appears in the next archive and the summary has no `WARN` for it.
3. Regenerate optiplex-two and smiddleware with survey 2.0.0 (`sudo ./borg-backup-survey.sh` on each
   host), review the diff, commit the prep **and** `deploy-borg-prep-<host>.sh` scripts, deploy with
   `--test`. This brings the named-volume warning and summary table to both hosts and fixes the pull.
   > [!CAUTION]
   > Regenerating optiplex-two **drops the hand-added `omd backup` block**. Either re-add it after
   > regenerating, or teach the survey to detect a `checkmk` container and emit it (preferred:
   > it then survives future regenerations).
   > Review the 1.x → 2.0.0 diff: generated scripts warn and continue where 1.x aborted.
4. Resolve open item 1 per host: add the volumes path to the plan, then touch the marker.
5. Backup-age monitoring (Checkmk handoff step 11): Checkmk local check on each source host,
   CRIT if the last good archive is > 26 h old. DSM can't see Borg client failures.
6. Do one real restore drill into `/restore` (e.g. portracker SQLite or the Checkmk omd archive)
   and record the result here.
7. Housekeeping:
   - Delete the merged branches listed above.
   - CHANGELOG `[2.0.0]` link points at the `borg-dev` tree; repoint it to `main` or a tag.
   - README "Expected output location (both hosts)" → three hosts; fill or remove the screenshot placeholders.

## Related
- [`checkmk/HANDOFF-POC.md`](../checkmk/HANDOFF-POC.md) — steps 11 (backup-age check) and 13 (`checkmk-sites` in Borg).
