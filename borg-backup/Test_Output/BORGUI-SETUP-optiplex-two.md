# Borg UI Setup Sheet - optiplex-two

- Generated: 2026-07-15T22:20:22-04:00
- Server: optiplex-two (`192.168.200.14`)
- Companion files: `REPORT.md` (full survey), `borg-prep-appdata-optiplex-two.sh`,
  `BORG_UI-optiplex-two-prep-appdata.sh` (generated with `--generate`)

Work through the sections top to bottom; each maps to a screen in the Borg UI GUI.

## 1. Prerequisites (before touching the GUI)

1. Deploy the prep script on optiplex-two. Direct root SSH login is usually disabled, so copy
   it up as a sudo-capable user and install it with sudo (replace `<admin-user>` with your login):

   ```bash
   scp borg-prep-appdata-optiplex-two.sh <admin-user>@192.168.200.14:/tmp/borg-prep-appdata-optiplex-two.sh
   ssh -t <admin-user>@192.168.200.14 'sudo install -o root -g root -m 700 /tmp/borg-prep-appdata-optiplex-two.sh /usr/local/sbin/borg-prep-appdata-optiplex-two.sh && rm /tmp/borg-prep-appdata-optiplex-two.sh'
   ```

2. Give the Borg UI container SSH access to `root@192.168.200.14`. The wrapper script logs in as
   root with a KEY, which works even when root password login is disabled - but if sshd refuses
   root entirely, set `PermitRootLogin prohibit-password` in `/etc/ssh/sshd_config` on optiplex-two
   and restart `ssh`. Install the container's public key (Borg UI -> Settings -> SSH keys)
   into root's authorized_keys via the sudo user:

   ```bash
   ssh -t <admin-user>@192.168.200.14 'sudo install -d -m 700 -o root -g root /root/.ssh && echo "<paste public key from Borg UI>" | sudo tee -a /root/.ssh/authorized_keys >/dev/null'
   ```

   Then verify non-interactive login from inside the container:

   ```bash
   docker exec -it borg-backup ssh -o BatchMode=yes root@192.168.200.14 true && echo OK
   ```

3. Test the prep script once by hand (from inside the container, using the key installed above):

   ```bash
   docker exec -it borg-backup ssh root@192.168.200.14 /usr/local/sbin/borg-prep-appdata-optiplex-two.sh
   docker exec -it borg-backup ssh root@192.168.200.14 ls -la /var/backups/borg-apps/latest
   ```

## 2. Repository (Borg UI -> Repositories -> Add)

| GUI field | Value |
| --- | --- |
| Name | `optiplex-two` |
| Location (in-container path) | `/local/optiplex-two/borg-repo-optiplex-two` |
| Encryption | `repokey-blake2` |
| Passphrase | generate with `openssl rand -base64 32`; store in your password manager |

The repo path sits one level below the mount on purpose: Borg UI checks that the
*parent* of the repo path is writable (it creates the repo directory itself), and
`/local` is a root-owned directory inside the container image. Pointing the repo at
`/local/optiplex-two` directly fails with `Parent directory is not writable: /local`.

The in-container path needs a host directory behind it - add this line to the
`borg-ui` service volumes in `docker_compose.yml` and recreate the container:

```yaml
      - /mnt/borg_optiplex-two:/local/optiplex-two:rw
```

(Alternative: a remote repo over SSH, e.g. `ssh://borg@backup-host:22/./repos/optiplex-two` - then no volume line is needed.)

After the repo is initialized, export the key and store it OUTSIDE the repo -
with `repokey` the key lives in the repo config, so a lost/corrupt repo also loses the key:

```bash
docker exec -it borg-backup borg key export /local/optiplex-two/borg-repo-optiplex-two /local/borgui-config-export/optiplex-two-borg-key.txt
```

## 3. Script entity (Borg UI -> Scripts -> Add)

| GUI field | Value |
| --- | --- |
| Name | `optiplex-two-prep-appdata` |
| Description | Pre-backup app-data snapshot for optiplex-two services |
| Run-on | Always - Regardless of result |
| Time-out | 300 seconds (5 minutes) |
| Script content | paste from `BORG_UI-optiplex-two-prep-appdata.sh` (the `#!/bin/bash` block) |

## 4. Backup plan (Borg UI -> Backups -> Add)

| GUI field | Value |
| --- | --- |
| Plan name | `optiplex-two-daily` |
| Repository | `optiplex-two` |
| Archive name template | `optiplex-two-{now:%Y-%m-%d_%H%M%S}` |
| Compression | `zstd,3` |
| Schedule | daily at 02:00 (cron `0 2 * * *`) - stagger if multiple servers share the Borg host |
| Pre-backup script | `optiplex-two-prep-appdata` (section 3) - **must run before every backup** |

### Source paths

| Path | Size at survey time | Why |
| --- | --- | --- |
| `/var/backups/borg-apps/latest` | - | app-consistent snapshot staged by the prep script (DB dumps, metadata, configs) |
| `/etc` | 8.3M | system configuration |
| `/var/lib/docker/volumes` | 14M | named Docker volumes (DB volumes made consistent by the dumps above) |
| `/data/compose/14` | 544M | compose project 'statping' |
| `/opt/docker/compose/portainer` | 8.0K | compose project 'portainer' |
| `/volume1/docker/portracker` | 76K | bind-mounted app data |

### Exclude patterns

Paste one per line into the plan's exclude list (borg `--exclude` syntax; `sh:` = shell-style glob):

| Pattern | Reason |
| --- | --- |
| `sh:/var/backups/borg-apps/.tmp.*` | in-progress prep staging dirs - only `latest` should be captured |
| `sh:**/*.db-wal` | SQLite write-ahead logs - the prep script stages consistent copies instead |
| `sh:**/*.db-shm` | SQLite shared-memory files (companions of .db-wal) |
| `sh:**/.cache` | hidden application caches (recreatable) |
| `sh:**/lost+found` | filesystem repair artifacts |
| `/var/lib/docker/overlay2` | container image/layer store - recreatable with `docker pull` |
| `/var/lib/docker/buildkit` | Docker build cache - recreatable |
| `/var/lib/docker/tmp` | Docker scratch space |
| `sh:/var/lib/docker/containers/*/*-json.log` | container stdout logs - skip unless you audit them |

Also review for: large re-downloadable media, transcode/thumbnail directories
(Plex/Jellyfin), and per-app `cache/` directories inside the paths above.

## 5. Retention / prune (on the same backup plan)

| GUI field | Value |
| --- | --- |
| Keep daily | 7 |
| Keep weekly | 4 |
| Keep monthly | 6 |
| Keep yearly | 1 |
| Compact after prune | yes (reclaims repo space) |

## 6. Consistency notes for this server

### Databases dumped by the prep script

Raw copies of live DB files are not crash-consistent; restores must use these dumps
from `/var/backups/borg-apps/latest/databases/`:

| Container | Engine | Notes |
| --- | --- | --- |
| postgres | postgres | user=statup |

### SQLite databases (safe-copied by the prep script)

- `/volume1/docker/portracker/portracker.db`

### Tailscale

- Node state (`/var/lib/tailscale`) is captured in the prep snapshot - treat the
  archive as SECRET and never restore it to a second machine (duplicate node identity).

### Kubernetes (k3s)

- Datastore snapshot and configs are captured by the prep script; hostPath/local PVs
  on this node should be added to the source paths above (see `raw/k8s-pv-pvc.txt`).

## 7. First-run verification

- [ ] Prep script runs clean: `docker exec -it borg-backup ssh root@192.168.200.14 /usr/local/sbin/borg-prep-appdata-optiplex-two.sh`
- [ ] First backup completes in Borg UI without warnings
- [ ] Archive list shows the new archive and its size looks plausible
- [ ] Repo key exported and stored off-repo (section 2)
- [ ] Test restore of one file (Borg UI mount/extract into `/restore`)
- [ ] For each database above: dump file exists and is non-empty in the archive under
      `var/backups/borg-apps/latest/databases/`
