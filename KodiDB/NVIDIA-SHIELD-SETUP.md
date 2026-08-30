# NVIDIA Shield — Kodi Setup Guide

Step-by-step guide for setting up Kodi on an **NVIDIA Shield Pro / Android TV**
as a client of the shared MariaDB library described in [README.md](README.md).
Follow these in order — steps are ordered because later ones depend on earlier
ones actually working.

> [!TIP]
> If the Shield is your **first** client (the one that builds the shared
> library), do all steps below in order. If it's joining a library that
> already exists on other clients, skip to
> [Step 7](#step-7-scan-or-inherit-the-library) after Step 6.

---

## Contents

1. [Prerequisites](#step-1-prerequisites)
2. [Install Kodi & disable auto-update](#step-2-install-kodi--disable-auto-update)
3. [Enable Developer options & Network debugging](#step-3-enable-developer-options--network-debugging)
4. [Install ADB on another machine](#step-4-install-adb-on-another-machine)
5. [Push `advancedsettings.xml` to the Shield](#step-5-push-advancedsettingsxml-to-the-shield)
6. [Force stop and restart Kodi](#step-6-force-stop-and-restart-kodi)
7. [Scan or inherit the library](#step-7-scan-or-inherit-the-library)
8. [Confirm the connection worked](#step-8-confirm-the-connection-worked)
9. [Prevent the Shield from sleeping](#step-9-prevent-the-shield-from-sleeping)
10. [Ongoing maintenance](#step-10-ongoing-maintenance)
11. [Troubleshooting](#troubleshooting)

---

## Step 1: Prerequisites

- The [MariaDB stack](README.md) is already deployed and reachable on your
  network, and you know its host IP and port (default `3306`).
- The `kodi` database user and password are already set up (see
  [Database Setup](README.md#database-setup) in the README).
- Your media is shared over the network as `nfs://` or `smb://` — **not** a
  local drive. Every Kodi client, including the Shield, must reach media by
  the exact same path string.
- The Shield is connected via **wired Ethernet** if it will act as the
  library scanner (recommended — see [Step 10](#step-10-ongoing-maintenance)).

---

## Step 2: Install Kodi & disable auto-update

1. On the Shield: open the **Play Store**, install **Kodi**.
2. Before doing anything else, disable auto-updates for it:
   **Play Store → Kodi → ⋮ / Options → uncheck Auto-update**.

> [!CAUTION]
> Skipping this is the most common way a shared library breaks later. If the
> Play Store silently updates Kodi to a new major version, it migrates the
> database to a new schema and every other client — still on the old version —
> wakes up pointing at a database that no longer exists.

3. **Do not launch Kodi yet.** Writing `advancedsettings.xml` before the first
   launch avoids the Shield building a local library first, which can make it
   look like your config didn't apply.

---

## Step 3: Enable Developer options & Network debugging

Android's scoped storage hides Kodi's config folder from the built-in file
manager and from network shares, so you'll use ADB to place the config file.

1. **Settings → Device Preferences → About**.
2. Click **Build** seven times to unlock Developer options.
3. **Settings → Device Preferences → Developer options → Network debugging**,
   turn it **on**.
4. Note the IP address shown — you'll need it in Step 5.

---

## Step 4: Install ADB on another machine

**ADB** (Android Debug Bridge) is Google's command-line tool for talking to
Android devices over the network. It's part of the free **SDK Platform
Tools** package (~10 MB) — you do not need Android Studio.

| Platform | Install |
|---|---|
| Any | [Direct download](https://developer.android.com/tools/releases/platform-tools) — [Windows](https://dl.google.com/android/repository/platform-tools-latest-windows.zip) · [macOS](https://dl.google.com/android/repository/platform-tools-latest-darwin.zip) · [Linux](https://dl.google.com/android/repository/platform-tools-latest-linux.zip) |
| Windows | `winget install Google.PlatformTools` |
| macOS | `brew install --cask android-platform-tools` |
| Debian / Ubuntu | `sudo apt install adb` |
| Fedora | `sudo dnf install android-tools` |
| Arch | `sudo pacman -S android-tools` |

Run this on any machine on the **same LAN** as the Shield (the Docker host
running the database works fine). Verify the install:

```bash
adb version
```

---

## Step 5: Push `advancedsettings.xml` to the Shield

1. On the machine with ADB, create a file named `advancedsettings.xml`:

   ```xml
   <advancedsettings>
     <videodatabase>
       <type>mysql</type>
       <host>192.168.1.20</host>   <!-- Docker host IP running MariaDB -->
       <port>3306</port>
       <user>kodi</user>
       <pass>your_kodi_password</pass>
     </videodatabase>

     <musicdatabase>
       <type>mysql</type>
       <host>192.168.1.20</host>
       <port>3306</port>
       <user>kodi</user>
       <pass>your_kodi_password</pass>
     </musicdatabase>

     <videolibrary>
       <importwatchedstate>true</importwatchedstate>
       <importresumepoint>true</importresumepoint>
     </videolibrary>
   </advancedsettings>
   ```

   Replace `<host>` with your Docker host's IP and `<user>`/`<pass>` with your
   actual `MARIADB_USER` / `MARIADB_PASSWORD` values.

   > [!NOTE]
   > `<type>mysql</type>` is correct even though the server is MariaDB — there
   > is no separate `mariadb` type. If your password contains `&`, `<`, or
   > `>`, escape them as `&amp;`, `&lt;`, `&gt;`.

2. Connect and push the file:

   ```bash
   adb connect 192.168.1.50:5555          # the Shield's IP from Step 3
   adb shell mkdir -p /sdcard/Android/data/org.xbmc.kodi/files/.kodi/userdata
   adb push advancedsettings.xml /sdcard/Android/data/org.xbmc.kodi/files/.kodi/userdata/advancedsettings.xml
   adb disconnect
   ```

   > [!NOTE]
   > Keep each command on **one line**. A trailing `\` for line continuation
   > is bash syntax and does nothing useful in PowerShell/cmd — it gets
   > pushed to the device as a literal character, corrupting the path.
   >
   > The `mkdir -p` is required because Step 2 deliberately skips launching
   > Kodi first — which means `.kodi/userdata/` doesn't exist yet.
   > `adb push` won't create missing parent directories on its own; without
   > this step it fails with `remote secure_mkdirs failed: No such file or
   > directory`.

3. **Accept the on-screen authorisation prompt** on the TV the first time you
   connect. If you skip this, `adb push` reports success but nothing actually
   changes.

> [!TIP]
> Alternative without ADB: install a file manager add-on inside Kodi, or use
> **Kodi Settings → File manager**, and copy the file in from a network
> source. Kodi can write to its own data directory even when Android's file
> pickers can't reach it — but this requires launching Kodi first, which
> means doing Step 6 (restart) *after* placing the file, same as the ADB path.

---

## Step 6: Force stop and restart Kodi

`advancedsettings.xml` is only read at startup, and Android does **not** stop
Kodi when you press Home — it stays resident in memory.

1. **Settings → Apps → See all apps → Kodi → Force stop.**
2. Reopen Kodi from the home screen.

(Equivalent via ADB: `adb shell am force-stop org.xbmc.kodi`, then relaunch
manually — ADB can't reopen the app for you.)

---

## Step 7: Scan or inherit the library

**If this Shield is the first client** setting up the shared library:

1. If you have an existing local Kodi library worth keeping, export it first:
   **Settings → Media → Library → Export library → *separate files*.** This
   writes `.nfo` files next to your media, which the MySQL scan will pick up.
   Skipping this means that watched history and ratings are lost — switching
   to MySQL does not migrate the local SQLite library.
2. Add your media sources using **network paths only**:

   ```diff
   + nfs://192.168.1.30/volume1/Movies    ← works from every client
   + smb://192.168.1.30/Movies
   - /storage/emulated/0/Movies           ← local path: unreachable elsewhere
   ```

3. Let the scan run to completion. This builds the library every other client
   will read.

**If another client already built the library**, just add the *same* network
sources here, using byte-identical path strings — no scan needed, the library
should appear immediately after Step 6.

---

## Step 8: Confirm the connection worked

> [!WARNING]
> Kodi fails **silently** here — if the database connection is refused, it
> falls back to a local SQLite library with no warning. Always check the log.

Pull the log via ADB:

```bash
adb connect 192.168.1.50:5555
adb pull /sdcard/Android/data/org.xbmc.kodi/files/.kodi/temp/kodi.log
```

Look for:

```diff
+ Running database version MyVideos131          ← connected to MariaDB
- Unable to open database ... [1045]            ← bad credentials or missing grant
```

A `[1045]` error means the credentials or the database's global grant are
wrong — see [Database Setup](README.md#database-setup) in the README.

---

## Step 9: Prevent the Shield from sleeping

If this Shield is going to be the library's scanner (recommended — see
[Step 10](#step-10-ongoing-maintenance)):

**Settings → Device Preferences → Sleep → Never** (or long enough to cover
your scheduled library update window). A sleeping Shield silently skips its
scheduled update.

---

## Step 10: Ongoing maintenance

- **Designate only one scanner.** On every *other* client, turn off
  **Settings → Media → Library → Update library on startup**. Concurrent
  scans against one database cause lock contention and duplicate entries. The
  Shield is a good choice for this role — mains-powered, always on, and
  ideally wired.
- **Keep Kodi versions in sync across all clients.** The database name
  encodes the schema version (e.g. `MyVideos131`). A newer client migrates
  the schema out from under older ones, stranding them. Since Step 2 disabled
  Play Store auto-update, upgrades only happen when you choose — do them on
  every client, in one sitting, and take a fresh backup first.
- **Artwork is not shared.** Each client caches its own thumbnails/fanart
  locally; only metadata lives in the database. This is expected.
- **Watched state syncs on library refresh**, not instantly to clients that
  are already open and sitting on a list view.

---

## Troubleshooting

| | Symptom | Likely cause / fix |
|---|---|---|
| 🔴 | Kodi shows an empty/local library | `advancedsettings.xml` didn't load — recheck the path in Step 5 and force stop + restart (Step 6). Confirm via `kodi.log` (Step 8). |
| 🔴 | Every other client went empty overnight | Kodi auto-updated on the Shield and migrated the schema. Revisit Step 2 to disable auto-update, then bring all clients to the same version. |
| 🟠 | Config changes don't take effect | Home button doesn't stop Kodi on Android — you need **Force stop** (Step 6). |
| 🟠 | Can't reach `Android/data/` with a file manager | Expected — Android scoped storage hides it. Use ADB (Steps 4–5). |
| 🟠 | `adb push` reports success but nothing changes | The on-screen authorisation prompt was never accepted — reconnect and watch the TV. |
| 🟠 | `remote secure_mkdirs failed: No such file or directory` | `.kodi/userdata/` doesn't exist yet because Kodi hasn't been launched — run `adb shell mkdir -p ...` first (Step 5). |
| 🟠 | `remote couldn't create file: Read-only file system` | The destination path got mangled (often a stray `\` line-continuation from a bash example run in PowerShell/cmd) and resolved to device root. Re-check the full path is on one line. |
| 🟠 | `adb: command not found` / `'adb' is not recognized` | Platform Tools aren't installed or aren't on your `PATH` — see Step 4. |
| 🟠 | Media plays on one client, "file not found" on another | A source was added by local path instead of `nfs://`/`smb://` — see Step 7. |
| 🟠 | Scheduled library update never runs | The Shield slept — see Step 9. |
| 🔵 | Library is empty right after switching to MySQL | Expected — local libraries aren't migrated. Export to `.nfo` first (Step 7), then rescan. |

<sub>🔴 breaks the shared library · 🟠 causes wrong or inconsistent behaviour · 🔵 expected, not a fault</sub>

For database-side issues (grants, password rotation, backups), see the main
[README.md](README.md).
