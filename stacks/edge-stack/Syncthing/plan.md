### Quick comparison (key decision criteria)

| **Feature**        | **Manual trigger**                                              | **Docker “master” node**                                  | **NAS backup**                                            |
| ------------------ | --------------------------------------------------------------- | --------------------------------------------------------- | --------------------------------------------------------- |
| **How to trigger** | Pause/unpause or set rescan interval = 0 then click **Rescan**. | Acts as always‑on peer; you still control client pauses.  | Backup runs on schedule or on snapshot replication tasks. |
| **Role**           | Any PC can edit then manually push/pull.                        | Anchor node (always online, versioning, web UI).          | Long‑term retention, snapshots, offsite replication.      |
| **Conflict risk**  | Low if you close Bambu Studio before rescan.                    | Lower if Docker node is authoritative (Send Only).        | Protects against corruption/ransomware with snapshots.    |
| **Performance**    | Local edits are fast; manual sync avoids runtime I/O hits.      | Good for availability; use host networking for LAN speed. | Best for backups; not for live low‑latency access.        |



### Which host shares to create and mount (recommended)

Create these shares on the host machine (or mount NAS shares to these host paths). The table below shows **share name**, **host path**, **container path**, **purpose**, and **mount notes**.

| **Share name**        | **Host path**                | **Container path**              | **Purpose**                               | **Mount notes**                                                 |
| --------------------- | ---------------------------- | ------------------------------- | ----------------------------------------- | --------------------------------------------------------------- |
| **syncthing-config**  | `/srv/syncthing/config`      | `/var/syncthing/config`         | Syncthing config, DB, keys, index         | Prefer local fast disk (SSD). Backup to NAS snapshots.          |
| **syncthing-data**    | `/srv/syncthing/data`        | `/var/syncthing/data`           | Anchor copy of synced folders (optional)  | Use local disk or fast NAS; avoid slow mounts for active files. |
| **syncthing-backups** | `/mnt/nas/syncthing-backups` | `/backup` (in backup container) | Long‑term backups, snapshots, replication | This is the NAS share with snapshots/replication enabled.       |
| **optional-temp**     | `/srv/syncthing/tmp`         | (not mounted by default)        | Temporary staging if needed               | Useful if you want to stage restores or do rsync temp files.    |

**Permissions:** ensure the host paths are owned by the UID/GID you set in the container (`PUID`/`PGID`) or set permissive ACLs so the container can read/write. Example:

bash

````
sudo mkdir -p /srv/syncthing/config /srv/syncthing/data /mnt/nas/syncthing-backups
sudo chown -R 1000:1000 /srv/syncthing
sudo chmod -R 750 /srv/syncthing

````

If your NAS uses SMB/CIFS, mount the NAS share to `/mnt/nas/syncthing-backups` on the host (use credentials in `/etc/fstab` or a systemd mount unit) and **enable snapshots/replication** on the NAS side.

### Recommended Syncthing folder & device settings (for Bambu Studio configs)

- **Folder path on Windows:** `%APPDATA%\BambuStudio`
- **Folder settings in Syncthing (Windows clients):**

  - **Rescan Interval:** `0` (manual rescan)
  - **Folder Type:** `Send & Receive` if you want any PC to push changes; use `Receive Only` on machines you want to strictly follow the anchor.
  - **File Versioning:** enable (Simple or Staggered) on the anchor node to keep previous versions.
  - **Ignore Patterns:** add patterns for large temp files or lock files if needed.

- **Client workflow (recommended):**

  1. Edit configs locally on any PC.
  2. **Close Bambu Studio** before syncing.
  3. On the PC, open Syncthing UI → click **Rescan** (or unpause folder briefly).
  4. Wait for sync to complete; verify; reopen Bambu Studio.


### Why keep Syncthing config local and back up to NAS (best practice)

- **Performance:** Syncthing’s database and index are I/O sensitive. Running them on a local SSD gives best responsiveness.
- **Reliability:** Backups on NAS provide snapshots, replication, and point‑in‑time recovery (protects against accidental deletes or ransomware).
- **Flexibility:** If I need to rebuild the anchor node, I can restore the config from NAS snapshots to a new host quickly.

### Portainer deployment steps (concise)

1. Open **Portainer → Stacks → Add stack**.
2. Paste the `docker-compose.yml` content into the editor.
3. Set any environment variables (TZ, PUID, PGID) as needed.
4. Create the host directories and mount NAS shares on the host before deploying.
5. Deploy the stack. Portainer will create the containers and map volumes.

### Extra hardening and convenience tips

- **Enable Syncthing GUI authentication** (set a username/password in the Syncthing web UI).
- **Enable TLS** for the web UI if I expose it externally (avoid exposing it publicly).
- **Enable File Versioning** on the anchor node to recover from accidental changes.
- **Use host networking** for best LAN throughput and discovery; if I must use bridge mode, expose ports `8384`, `22000`, and `21027/udp`.
- **Automate safe sync**: later I can cerate a small PowerShell script that closes Bambu Studio, triggers Syncthing rescan via its REST API, waits for completion, then reopens the app. You said hold that for now — stick a pin in it

### Full Docker Compose stack for Portainer (Syncthing + optional backup job)

Below is a ready‑to‑paste `docker-compose.yml` I can deploy as a **Stack** in Portainer. It runs **Syncthing** as an always‑on anchor node (host networking for best LAN performance), persists config and synced data to host paths (which  I mount from your NAS or local storage), and includes an optional lightweight **backup** service that copies the Syncthing config/data to a NAS backup share on a schedule.

> **Important design notes**
> 
> - Keep **active Bambu/Orca config files local** on each Windows PC; do **not** use symlinks to NAS for live configs. Use Syncthing to replicate local files to the anchor node instead.
> - Store Syncthing **config** on a fast local disk if possible, then back that config to the NAS for snapshots/replication. Storing the live Syncthing database directly on a slow NAS can degrade performance.
> - The backup job in this compose is optional; I can replace it with your NAS vendor’s snapshot/replication or a more advanced backup tool (restic, borg, rclone)