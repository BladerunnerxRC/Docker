#!/usr/bin/env bash
# pull-borg-scripts.sh
#
# Downloads this host's Borg scripts from GitHub into a local scripts folder and keeps a dated
# copy of each download on the Synology share. It installs nothing: deploy the prep script
# afterwards with deploy-borg-prep-<host>.sh, which shows a diff and asks first.
#
# Files pulled (from borg-backup/ in BladerunnerxRC/Docker):
#   borg-prep-appdata-<host>.sh  deploy-borg-prep-<host>.sh  borg-backup-survey.sh  README.md
#
# Usage (on the host, as root so it can write to /mnt/backups):
#   sudo ./pull-borg-scripts.sh [--name HOST] [--branch BRANCH] [--dest DIR]
#     --name     host whose scripts to pull (default: this host's short name)
#     --branch   GitHub branch (default: main)
#     --dest     local folder (default: /home/thomas/borg-backup-scripts)
#
# Local files are owned by the owner of the --dest folder (not root): scripts 750, README 640.
# Copies go to /mnt/backups/borg-script-backups/<host>/github-pulls/<YYYYmmdd-HHMMSS>/ with a
# SOURCE.txt naming the commit; the newest 10 are kept. They sit one level below the deploy
# script's own backups, so its --rollback never picks them up.
# If /mnt/backups is not mounted, or any download fails a check, nothing is changed.
#
# Licensed under the MIT License. Provided "as is" without warranty.

set -Eeuo pipefail

REPO="BladerunnerxRC/Docker"
NAME="$(hostname -s)"
BRANCH="main"
DEST="/home/thomas/borg-backup-scripts"
BACKUP_MOUNT="/mnt/backups"
KEEP_PULLS=10

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME="${2:?--name needs a value}"; shift 2 ;;
    --branch)  BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --dest)    DEST="${2:?--dest needs a value}"; shift 2 ;;
    -h|--help) awk 'NR>2 {if (!/^#/) exit; sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *)         echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 ...) - writing to $BACKUP_MOUNT needs it"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "'$NAME' is not a valid short hostname"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "'$BRANCH' is not a valid branch name"
command -v curl >/dev/null || die "curl is not installed (sudo apt install curl)"

FILES=("borg-prep-appdata-${NAME}.sh" "deploy-borg-prep-${NAME}.sh" "borg-backup-survey.sh" "README.md")
PULL_DIR="${BACKUP_MOUNT}/borg-script-backups/${NAME}/github-pulls"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# -----------------------------
# Download and check every file before changing anything
# -----------------------------
# Pin the branch to its current commit: raw.githubusercontent.com caches branch URLs for up to
# 5 minutes, and the commit is recorded with the backup copy.
COMMIT="$(curl -fsSL -H 'Accept: application/vnd.github.sha' \
          "https://api.github.com/repos/${REPO}/commits/${BRANCH}" 2>/dev/null || true)"
if [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  REF="$COMMIT"
else
  echo "WARNING: could not look up the commit for '$BRANCH' - downloading the branch as cached by GitHub." >&2
  REF="$BRANCH" COMMIT="unknown"
fi
BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}/borg-backup"

echo "Pulling ${#FILES[@]} files from ${REPO}, branch ${BRANCH} (commit ${COMMIT:0:7})"
for f in "${FILES[@]}"; do
  # No --retry: some curl versions exit 0 after a 404 when it is set, despite -f.
  curl -fsSL -o "$STAGE/$f" "$BASE_URL/$f" \
    || die "download failed: $BASE_URL/$f - wrong branch, or not in the repo yet? Nothing was changed."
  [ -s "$STAGE/$f" ] || die "$f downloaded empty. Nothing was changed."
  if [ "$(tr -cd '\r' < "$STAGE/$f" | wc -c)" -gt 0 ]; then
    die "$f has Windows (CRLF) line endings. Nothing was changed."
  fi
  case "$f" in
    *.sh)
      head -n1 "$STAGE/$f" | grep -q '^#!' || die "$f does not start with a #! line. Nothing was changed."
      bash -n "$STAGE/$f" || die "$f has syntax errors. Nothing was changed."
      ;;
  esac
done

# -----------------------------
# Dated copy on the Synology share
# -----------------------------
ls "$BACKUP_MOUNT/" >/dev/null 2>&1 || true   # wakes an x-systemd.automount
mountpoint -q "$BACKUP_MOUNT" \
  || die "$BACKUP_MOUNT is not mounted - mount the Synology backup share first. Nothing was changed."
mkdir -p "$PULL_DIR" || die "cannot create $PULL_DIR - check the share's permissions. Nothing was changed."

# mkdir without -p is atomic: if another pull already took this second, wait for the next one.
tries=0
copy_dir="$PULL_DIR/$(date +%Y%m%d-%H%M%S)"
until mkdir "$copy_dir" 2>/dev/null; do
  [ -e "$copy_dir" ] && [ "$tries" -lt 5 ] || die "cannot create $copy_dir. Nothing was changed."
  tries=$((tries + 1))
  sleep 1
  copy_dir="$PULL_DIR/$(date +%Y%m%d-%H%M%S)"
done
# NFS shares often squash root or use ACLs, so chmod may be refused: keep it best-effort.
chmod 700 "$copy_dir" 2>/dev/null || true
for f in "${FILES[@]}"; do cp "$STAGE/$f" "$copy_dir/$f"; done
printf 'repo:    %s\nbranch:  %s\ncommit:  %s\npulled:  %s\nby:      %s on %s\n' \
  "$REPO" "$BRANCH" "$COMMIT" "$(date -Is)" "${SUDO_USER:-root}" "$(hostname -s)" > "$copy_dir/SOURCE.txt"
echo "Saved a copy to $copy_dir/"

# Folders are named YYYYmmdd-HHMMSS, so a reverse name sort is newest first.
ls -1d "$PULL_DIR"/[0-9]*-[0-9]*/ 2>/dev/null | sort -r | tail -n +$((KEEP_PULLS + 1)) \
  | while read -r old; do rm -rf -- "$old"; done

# -----------------------------
# Update the local scripts folder
# -----------------------------
# A new folder belongs to the owner of its parent (normally thomas), not to root.
if [ ! -d "$DEST" ]; then
  parent="$(dirname "$DEST")"
  install -d -m 750 -o "$(stat -c %u "$parent")" -g "$(stat -c %g "$parent")" "$DEST"
fi
uid="$(stat -c %u "$DEST")" gid="$(stat -c %g "$DEST")"

echo "Updating $DEST:"
for f in "${FILES[@]}"; do
  if [ ! -f "$DEST/$f" ]; then status="new"
  elif cmp -s "$STAGE/$f" "$DEST/$f"; then status="unchanged"
  else status="updated"
  fi
  case "$f" in *.sh) mode=750 ;; *) mode=640 ;; esac
  # Write next to the target, then rename: a script that is running keeps its old copy.
  install -m "$mode" -o "$uid" -g "$gid" "$STAGE/$f" "$DEST/.$f.new"
  mv -f "$DEST/.$f.new" "$DEST/$f"
  printf '  %-40s %s\n' "$f" "$status"
done

echo
echo "Nothing is installed yet. To deploy the prep script (shows a diff and asks first):"
echo "  cd $DEST && sudo ./deploy-borg-prep-${NAME}.sh --test"
