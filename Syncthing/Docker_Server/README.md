# Syncthing

![Syncthing](https://img.shields.io/badge/app-syncthing-0891B2?logo=syncthing&logoColor=white)
![Docker Compose](https://img.shields.io/badge/deploy-docker%20compose-2496ED?logo=docker&logoColor=white)
![Status](https://img.shields.io/badge/status-pre--release-F59E0B)

### Goal

- Set up syncing solution for 3D printing slicers such a Bambu Studio, Orca Slicer, and Prusa Slicer config files.

  - Want to be able to use slicers on multiple PCs and sync any config changes to all on demand
  - Syncthing would also be running in docker (TBD one of the servers or Docker on one of the NASs.

    - clean backups can be backed up to NAS shares with recycle, snapshot and replication on NAS side.

  - Slicers need to be shutdown prior to syncing to prevent Windows file locks?
  - Syncthing clients need to be installed on windows PCs


### Enhancements

- [ ]  Create PowerShell script to automate slicer(s) shutdown , sync, slicer restart.

  - [ ] (Rescan=0, Receive Only, versioning) and a small PowerShell script to close Bambu Studio → rescan → reopen.

- [ ]  Create compiled executable for the manual execution of the PS above. (maybe use Sapian)
- [ ]  Create gui and install for the exe
- [ ]  Some type of backup routine to NAS share manual/auto may be scheduled in host server cron   or internal to docker container.
- [ ]  Migrate to Kubernetes or Docker Swarm



> [!WARNING]
> Code subject to change at any time before release. Execute at your own risk.



## Notes:



### What the Docker “sudo master” provides

- **Always‑online anchor** so devices can sync even if PCs are offline.
- **Web UI and device management**, file versioning, and central storage of the canonical copy (you can set it to **Send Only** to act as the golden copy).
- **Run in Docker with host networking** for best LAN discovery/performance; map `/var/syncthing` to persistent storage.

### Possible manual edit then sync workflow (recommended)

> [!IMPORTANT]
> **Edit locally on any Windows PC** and **close Bambu Studio** before syncing. **Always close the app** to avoid partial writes and conflicts.

- Configure the Syncthing folder on each Windows PC as **Receive Only** (if you want a single authoritative source) or **Send & Receive** (if any PC can be the source).
- For **manual control** set **Rescan Interval = 0** and use the **Rescan** button, or **pause/unpause the folder** when you want to sync. You can script pause/resume/rescan via the Syncthing CLI/API for a one‑click workflow.



### Risks, mitigations, and possible next steps

| | Risk | | Mitigation |
| --- | --- | --- | --- |
| ![risk](https://img.shields.io/badge/risk-C9372C?style=flat-square) | Conflicts if two machines edit simultaneously. | ![fix](https://img.shields.io/badge/fix-16A34A?style=flat-square) | Close Bambu Studio, use Receive Only or manual rescan, enable file versioning. |
| ![risk](https://img.shields.io/badge/risk-C9372C?style=flat-square) | Slow performance with NAS/symlinked configs. | ![fix](https://img.shields.io/badge/fix-16A34A?style=flat-square) | Keep active configs local; use Syncthing to sync them, then snapshot the Docker node to NAS. |

## Web Links

(ctl-click)

[Welcome to Syncthing’s documentation! — Syncthing documentation](https://docs.syncthing.net/index.html)

