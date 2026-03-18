# Syncthing

## Table of contents

- [Synology NAS stack notes](#synology-nas-stack-notes)
- [Required DSM directories](#required-dsm-directories)
- [What each directory is for](#what-each-directory-is-for)
- [Deployment notes](#deployment-notes)
- [DSM deployment steps](#dsm-deployment-steps)
- [DSM checks after deployment](#dsm-checks-after-deployment)
- [Goal](#goal)
- [Enhancements](#enhancements)
- [Notes](#notes)
- [What the Docker “sudo master” provides](#what-the-docker-sudo-master-provides)
- [Possible manual edit then sync workflow (recommended)](#possible-manual-edit-then-sync-workflow-recommended)
- [Risks, mitigations, and possible next steps](#risks-mitigations-and-possible-next-steps)
- [Web Links](#web-links)

## Synology NAS stack notes

This NAS stack has been modified for Synology DSM so the Docker bind mounts use Synology shared-folder paths under `/volume1/docker/syncthing` instead of generic Linux server paths such as `/srv/...`.

The matching compose file is [docker-compose.yml](docker-compose.yml) and is intended for Synology Container Manager, Portainer, or another Docker Compose deployment on the NAS.

### Required DSM directories

Create these directories on the Synology NAS before deploying the stack:

- `/volume1/docker/syncthing/config`
- `/volume1/docker/syncthing/data`
- `/volume1/docker/syncthing/backups`

### What each directory is for

- `/volume1/docker/syncthing/config` stores the Syncthing configuration, database, keys, and metadata.
- `/volume1/docker/syncthing/data` stores the anchor copy of the synced folders.
- `/volume1/docker/syncthing/backups` stores timestamped backups created by the backup sidecar container.

### Deployment notes

- Create the folders first in DSM or over SSH before starting the stack.
- Ensure the container runtime user has read and write access to all three folders.
- `network_mode: "host"` is kept in the compose because it is the preferred option for Syncthing LAN discovery and throughput.
- If host networking is not available in your Synology setup, remove it and expose the required Syncthing ports instead.

### DSM deployment steps

1. In DSM, open **File Station** and create the folders `/docker/syncthing/config`, `/docker/syncthing/data`, and `/docker/syncthing/backups` inside the `volume1` shared storage location.
2. In DSM, open **Container Manager** and confirm Docker is enabled and running.
3. In **Container Manager**, go to **Project** and click **Create**.
4. Enter a project name such as `syncthing-nas`.
5. Choose **Create docker-compose.yml from text** or the equivalent paste/import option in your DSM version.
6. Paste in the contents of [docker-compose.yml](docker-compose.yml).
7. Review the compose and verify the volume mappings point to `/volume1/docker/syncthing/config`, `/volume1/docker/syncthing/data`, and `/volume1/docker/syncthing/backups`.
8. If Container Manager prompts for privileges or host network confirmation, allow the project to use **host networking**.
9. Click **Next** and then **Done** or **Deploy** to create the project.
10. Wait for both containers to start, then open the project details and confirm `syncthing` and `syncthing-backup` show as running.
11. Open a browser to `http://<NAS-IP>:8384` to reach the Syncthing web UI.
12. In Syncthing, set a GUI username and password, add your Windows devices, and create or share the folders you want to sync.

### DSM checks after deployment

- In **Container Manager**, open the `syncthing` container logs and confirm Syncthing started without permission errors.
- In DSM **File Station**, verify files appear under `/volume1/docker/syncthing/config` after first launch.
- Confirm the backup container creates timestamped folders under `/volume1/docker/syncthing/backups`.
- If the web UI does not open, verify the NAS firewall and confirm port `8384` is reachable on the LAN.

## Goal

- Set up a syncing solution for 3D printing slicer configuration files such as Bambu Studio, Orca Slicer, and Prusa Slicer.

  - Be able to use slicers on multiple PCs and sync configuration changes to all systems on demand.
  - Run Syncthing in Docker, either on one of the servers or on one of the NAS devices.

    - Clean backups can be stored on NAS shares with recycle bin, snapshots, and replication handled on the NAS side.

  - Slicers likely need to be shut down before syncing to prevent Windows file locks.
  - Syncthing clients need to be installed on Windows PCs.


## Enhancements

- [ ] Create a PowerShell script to automate slicer shutdown, sync, and restart.

  - [ ] Use `Rescan = 0`, `Receive Only`, and versioning, plus a small PowerShell script to close Bambu Studio, rescan, and reopen it.

- [ ] Create a compiled executable for manual execution of the PowerShell script above, possibly using Sapien.
- [ ] Create a GUI and installer for the executable.
- [ ] Add a backup routine to a NAS share, either manual or scheduled through host cron or an internal Docker container process.
- [ ] Migrate to Kubernetes or Docker Swarm.



<span style="color:rgba(16,185,129,1)">Code subject to change at any time before release. Execute at your own risk.</span>



## Notes



### What the Docker “sudo master” provides

- **Always‑online anchor** so devices can sync even if PCs are offline.
- **Web UI and device management**, file versioning, and central storage of the canonical copy (you can set it to **Send Only** to act as the golden copy).
- **Run in Docker with host networking** for best LAN discovery/performance; map `/var/syncthing` to persistent storage.

### Possible manual edit then sync workflow (recommended)

- **Edit locally on any Windows PC** and **close Bambu Studio** before syncing. **Always close the app** to avoid partial writes and conflicts. **Important.**
- Configure the Syncthing folder on each Windows PC as **Receive Only** (if you want a single authoritative source) or **Send & Receive** (if any PC can be the source).
- For **manual control** set **Rescan Interval = 0** and use the **Rescan** button, or **pause/unpause the folder** when you want to sync. You can script pause/resume/rescan via the Syncthing CLI/API for a one‑click workflow.



### Risks, mitigations, and possible next steps

- **Risk:** Conflicts if two machines edit simultaneously. **Mitigation:** Close Bambu Studio, use Receive Only or manual rescan, enable file versioning.
- **Risk:** Slow performance with NAS/symlinked configs. **Mitigation:** Keep active configs local; use Syncthing to sync them, then snapshot the Docker node to NAS.

## Web Links

(ctl-click)

[Welcome to Syncthing’s documentation! — Syncthing documentation](https://docs.syncthing.net/index.html)

