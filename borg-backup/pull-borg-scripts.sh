#!/usr/bin/env bash
# pull-borg-scripts.sh
#
# Downloads this host's Borg scripts from GitHub into a local scripts folder. It installs
# nothing: deploy the prep script afterwards with deploy-borg-prep-<host>.sh, which shows a
# diff and asks first.
#
# Files pulled (from borg-backup/ in BladerunnerxRC/Docker):
#   borg-prep-appdata-<host>.sh  deploy-borg-prep-<host>.sh  borg-backup-survey.sh  README.md
#   pull-borg-scripts.sh (this script, so it updates itself)
#   VERSION  CHANGELOG.md (skipped on branches that don't have them yet)
#
# Usage (on the host; sudo is not needed):
#   ./pull-borg-scripts.sh [--name HOST] [--branch BRANCH] [--dest DIR]
#     --name     host whose scripts to pull (default: this host's short name)
#     --branch   GitHub branch (default: main)
#     --dest     local folder (default: /home/thomas/scripts/borgbackup for main,
#                /home/thomas/scripts/borgbackup-<branch> for any other branch, so testing
#                a branch never overwrites the files you use)
#     --version  show the version
#
# Scripts are written 750, other files 640. Under sudo they are owned by the owner of the
# --dest folder, not root. SOURCE.txt in the folder records the branch and commit pulled.
# If any download fails a check, nothing is changed.
#
# Licensed under the MIT License. Provided "as is" without warranty.

set -Eeuo pipefail

# Keep in step with borg-backup/VERSION and CHANGELOG.md.
PULL_VERSION="3.0.0"

REPO="BladerunnerxRC/Docker"
NAME=""
BRANCH="main"
DEST=""
DEST_BASE="/home/thomas/scripts/borgbackup"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME="${2:?--name needs a value}"; shift 2 ;;
    --branch)  BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --dest)    DEST="${2:?--dest needs a value}"; shift 2 ;;
    --version) echo "pull-borg-scripts.sh ${PULL_VERSION}"; exit 0 ;;
    -h|--help) awk 'NR>2 {if (!/^#/) exit; sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *)         echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$NAME" ] || NAME="$(hostname -s)"

[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "'$NAME' is not a valid short hostname"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "'$BRANCH' is not a valid branch name"
command -v curl >/dev/null || die "curl is not installed (sudo apt install curl)"

if [ -z "$DEST" ]; then
  if [ "$BRANCH" = "main" ]; then DEST="$DEST_BASE"; else DEST="${DEST_BASE}-${BRANCH//\//-}"; fi
fi

FILES=("borg-prep-appdata-${NAME}.sh" "deploy-borg-prep-${NAME}.sh" "borg-backup-survey.sh" "README.md"
       "pull-borg-scripts.sh")
OPTIONAL_FILES=("VERSION" "CHANGELOG.md")   # added in 2.0.0; older branches don't have them

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

echo "Pulling from ${REPO}, branch ${BRANCH} (commit ${COMMIT:0:7})"
PULLED=()
for f in "${FILES[@]}" "${OPTIONAL_FILES[@]}"; do
  # Check the HTTP status rather than curl -f: only a 404 means "not on this branch"; a network
  # error or a GitHub 5xx (status 000 or 5xx) must stop the pull, even for an optional file.
  # curl's own exit status is checked too: a transfer cut off partway can still report 200.
  rc=0
  code="$(curl -sSL -o "$STAGE/$f" -w '%{http_code}' "$BASE_URL/$f" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || die "download of $f failed (curl exit $rc, HTTP ${code:-none}) - network or GitHub problem? Nothing was changed."
  case "$code" in
    200) ;;
    404)
      case " ${OPTIONAL_FILES[*]} " in
        *" $f "*) echo "  $f is not on this branch - skipped"; rm -f "$STAGE/$f"; continue ;;
      esac
      die "$f is not on branch $BRANCH ($BASE_URL/$f). Nothing was changed."
      ;;
    *) die "download of $f failed (HTTP ${code:-none}) - network or GitHub problem? Nothing was changed." ;;
  esac
  PULLED+=("$f")
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
# The local folder's parent must exist, checked before anything is written.
# -----------------------------
parent="$(dirname "$DEST")"
[ -d "$DEST" ] || [ -d "$parent" ] || die "$parent does not exist - pass --dest DIR. Nothing was changed."

# Under sudo, files belong to the owner of the folder (normally thomas), not to root. A new
# folder takes the owner of its parent.
own=()
if [ "$(id -u)" -eq 0 ]; then
  [ -d "$DEST" ] || own=(-o "$(stat -c %u "$parent")" -g "$(stat -c %g "$parent")")
fi
if [ ! -d "$DEST" ]; then
  install -d -m 750 "${own[@]}" "$DEST" || die "cannot create $DEST. Nothing was changed."
fi
own=()
[ "$(id -u)" -ne 0 ] || own=(-o "$(stat -c %u "$DEST")" -g "$(stat -c %g "$DEST")")

# -----------------------------
# Update the local scripts folder
# -----------------------------
printf 'repo:    %s\nbranch:  %s\ncommit:  %s\npulled:  %s\nby:      %s on %s\ntool:    pull-borg-scripts.sh %s\n' \
  "$REPO" "$BRANCH" "$COMMIT" "$(date -Is)" "${SUDO_USER:-$(id -un)}" "$(hostname -s)" "$PULL_VERSION" \
  > "$STAGE/SOURCE.txt"
PULLED+=("SOURCE.txt")

echo "Updating $DEST:"
for f in "${PULLED[@]}"; do
  if [ ! -f "$DEST/$f" ]; then status="new"
  elif cmp -s "$STAGE/$f" "$DEST/$f"; then status="unchanged"
  else status="updated"
  fi
  case "$f" in *.sh) mode=750 ;; *) mode=640 ;; esac
  # Write next to the target, then rename: a script that is running keeps its old copy.
  install -m "$mode" "${own[@]}" "$STAGE/$f" "$DEST/.$f.new"
  mv -f "$DEST/.$f.new" "$DEST/$f"
  printf '  %-40s %s\n' "$f" "$status"
done

echo
if [ -f "$STAGE/VERSION" ]; then
  echo "Version on ${BRANCH}: $(head -n1 "$STAGE/VERSION") (changes: $DEST/CHANGELOG.md)"
fi
echo "Nothing is installed yet. To deploy the prep script (shows a diff and asks first):"
echo "  cd $DEST && sudo ./deploy-borg-prep-${NAME}.sh --test"
