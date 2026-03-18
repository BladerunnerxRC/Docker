# Syncthing

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



<span style="color:rgba(16,185,129,1)">Code subject to change at any time before release. Execute at your own risk.</span>



## Notes:



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

