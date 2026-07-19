#!/bin/bash
# borg-verify-backup-mode.sh
#
# Determines HOW a server is being backed up by this Borg UI stack:
#
#   PULL mode  - Borg UI SSHFS-mounts the server over SSH and runs borg
#                inside the borg-backup container; the server needs no borg
#                client. Repo lives on the Borg host (/mnt/borg_<name>).
#   PUSH mode  - a borg client/agent on the server itself runs the backup
#                (cron/systemd/agent) and Borg UI only manages/monitors it.
#
# Run this ON THE BORG HOST (optiplex-docker). It inspects the borg-backup
# container, the local repo directory, the Borg UI database, and (over the
# container's own SSH key) the remote server.
#
# Usage:
#   ./borg-verify-backup-mode.sh                      # defaults: smiddleware 192.168.200.52
#   ./borg-verify-backup-mode.sh smiddleware 192.168.200.52
#   ./borg-verify-backup-mode.sh optiplex-two 192.168.200.14
#
# Env overrides: CONTAINER (default borg-backup), REPO_HOST_PATH (default /mnt/borg_<name>)

set -Eeuo pipefail

NAME="${1:-smiddleware}"
ADDRESS="${2:-192.168.200.52}"
CONTAINER="${CONTAINER:-borg-backup}"
REPO_HOST_PATH="${REPO_HOST_PATH:-/mnt/borg_${NAME}}"

PULL_HITS=()
PUSH_HITS=()

hr()   { printf '\n=== %s ===\n' "$*"; }
info() { printf '  %s\n' "$*"; }

hr "Target: ${NAME} (${ADDRESS}) | container: ${CONTAINER} | repo: ${REPO_HOST_PATH}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: container '$CONTAINER' is not running." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. SSHFS / FUSE mounts inside the container (smoking gun for PULL mode)
# ---------------------------------------------------------------------------
hr "1. FUSE/SSHFS mounts inside ${CONTAINER}"
MOUNTS="$(docker exec "$CONTAINER" sh -c "mount | grep -Ei 'sshfs|fuse' || true")"
if [ -n "$MOUNTS" ]; then
  echo "$MOUNTS"
  if echo "$MOUNTS" | grep -q "$ADDRESS"; then
    PULL_HITS+=("container has an active SSHFS mount of ${ADDRESS}")
  fi
else
  info "(no fuse/sshfs mounts right now - a pull-mode mount may only exist while a backup runs)"
fi

# ---------------------------------------------------------------------------
# 2. borg processes inside the container
# ---------------------------------------------------------------------------
hr "2. borg/ssh processes inside ${CONTAINER}"
docker exec "$CONTAINER" sh -c "ps aux | grep -Ei '[b]org (create|prune|compact|mount)|[s]shfs' || echo '  (none running right now)'"

# ---------------------------------------------------------------------------
# 3. Repo on the Borg host - if the repo lives HERE, backups are written by
#    this stack (pull), since nothing exposes borg-serve into the container.
# ---------------------------------------------------------------------------
hr "3. Local repo at ${REPO_HOST_PATH}"
if [ -f "${REPO_HOST_PATH}/config" ] && grep -q '^\[repository\]' "${REPO_HOST_PATH}/config" 2>/dev/null; then
  info "Borg repository found on this host."
  ls -lt "${REPO_HOST_PATH}" | head -6
  PULL_HITS+=("borg repo for ${NAME} lives on the Borg host at ${REPO_HOST_PATH}")
elif [ -d "${REPO_HOST_PATH}" ]; then
  info "Directory exists but contains no borg repo (no [repository] config):"
  ls -la "${REPO_HOST_PATH}" | head -10
else
  info "No such directory - repo is elsewhere (possibly on the server itself = push mode)."
fi

# ---------------------------------------------------------------------------
# 4. Borg UI database - machines / clients / agents / plans registration.
#    Secret-looking columns are redacted, long values truncated.
# ---------------------------------------------------------------------------
hr "4. Borg UI database entries (redacted)"
docker exec -i "$CONTAINER" python3 - "$NAME" "$ADDRESS" <<'PY' || info "(could not read the Borg UI database)"
import glob, sqlite3, sys
name, address = sys.argv[1], sys.argv[2]
SECRET = ('pass', 'secret', 'token', 'private', 'key')
INTERESTING = ('machine', 'client', 'agent', 'repo', 'plan', 'schedule', 'job', 'script', 'backup', 'mount')
dbs = [p for p in glob.glob('/data/**/*', recursive=True)
       if p.endswith(('.db', '.sqlite', '.sqlite3'))]
if not dbs:
    print('  (no sqlite database found under /data)')
for db in dbs:
    print(f'--- {db}')
    try:
        con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
        cur = con.cursor()
        tables = [r[0] for r in cur.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")]
        print('  tables:', ', '.join(tables))
        for t in tables:
            if not any(k in t.lower() for k in INTERESTING):
                continue
            cols = [c[1] for c in cur.execute(f'PRAGMA table_info("{t}")')]
            rows = cur.execute(f'SELECT * FROM "{t}" LIMIT 25').fetchall()
            if not rows:
                continue
            print(f'\n  [{t}]')
            for row in rows:
                out = []
                for col, val in zip(cols, row):
                    if val in (None, ''):
                        continue
                    v = str(val)
                    if any(s in col.lower() for s in SECRET):
                        v = '<redacted>'
                    elif len(v) > 100:
                        v = v[:100] + '...'
                    out.append(f'{col}={v}')
                print('    ' + ' | '.join(out))
        con.close()
    except Exception as e:
        print(f'  (skip: {e})')
PY

# ---------------------------------------------------------------------------
# 5. Evidence ON the server itself, via the container's SSH key.
#    A push-mode setup leaves traces: borg binary, cron/systemd jobs, agents.
# ---------------------------------------------------------------------------
hr "5. Client-side evidence on ${NAME} (via ssh root@${ADDRESS})"
REMOTE_OUT="$(docker exec -i "$CONTAINER" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${ADDRESS}" 'sh -s' <<'EOS' || true
echo "-- borg binary:";        command -v borg 2>/dev/null || echo "  none"
echo "-- borg processes:";     ps aux | grep -i "[b]org" || echo "  none"
echo "-- root crontab:";       crontab -l 2>/dev/null | grep -i borg || echo "  none"
echo "-- /etc/cron*:";         grep -ril borg /etc/cron* 2>/dev/null || echo "  none"
echo "-- systemd borg units:"; systemctl list-unit-files 2>/dev/null | grep -i borg || echo "  none"
echo "-- systemd borg timers:"; systemctl list-timers --all 2>/dev/null | grep -i borg || echo "  none"
echo "-- root borg cache/config:"; ls -d /root/.cache/borg /root/.config/borg 2>/dev/null || echo "  none"
echo "-- agent-ish containers:"; docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -Ei 'borg|agent' || echo "  none"
echo "-- prep script:";        ls -la /usr/local/sbin/borg-prep-appdata-* 2>/dev/null || echo "  none"
echo "-- local repos (heuristic):"; find / -maxdepth 4 -name config -path '*borg*' 2>/dev/null | head -5 || true
EOS
)"
if [ -z "$REMOTE_OUT" ]; then
  info "SSH to root@${ADDRESS} failed - cannot inspect the server side."
else
  echo "$REMOTE_OUT"
  echo "$REMOTE_OUT" | grep -A1 '^-- borg binary:' | grep -qv -e '^--' -e 'none' \
    && PUSH_HITS+=("borg client binary is installed on ${NAME}")
  echo "$REMOTE_OUT" | grep -A1 '^-- root crontab:' | grep -qv -e '^--' -e 'none' \
    && PUSH_HITS+=("root crontab on ${NAME} references borg")
  echo "$REMOTE_OUT" | grep -A1 '^-- systemd borg timers:' | grep -qv -e '^--' -e 'none' \
    && PUSH_HITS+=("systemd timer on ${NAME} references borg")
  echo "$REMOTE_OUT" | grep -A1 '^-- agent-ish containers:' | grep -qv -e '^--' -e 'none' \
    && PUSH_HITS+=("agent-like container running on ${NAME}")
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
hr "VERDICT for ${NAME}"
for h in "${PULL_HITS[@]:-}";  do [ -n "$h" ] && echo "  [PULL] $h"; done
for h in "${PUSH_HITS[@]:-}";  do [ -n "$h" ] && echo "  [PUSH] $h"; done

if [ "${#PUSH_HITS[@]}" -gt 0 ] && [ "${#PULL_HITS[@]}" -eq 0 ]; then
  echo "  => PUSH mode: a client on ${NAME} runs its own backups; Borg UI manages/monitors."
elif [ "${#PULL_HITS[@]}" -gt 0 ] && [ "${#PUSH_HITS[@]}" -eq 0 ]; then
  echo "  => PULL mode: Borg UI does the backup itself over SSH/SSHFS; no client on ${NAME}."
elif [ "${#PULL_HITS[@]}" -gt 0 ] && [ "${#PUSH_HITS[@]}" -gt 0 ]; then
  echo "  => MIXED signals - review the evidence above (a borg binary can be leftover/unused;"
  echo "     check section 4 plans and section 3 repo timestamps to see who actually writes)."
else
  echo "  => INCONCLUSIVE from static checks. Check section 4 (database plans) above, or"
  echo "     re-run while a ${NAME} backup is in progress to catch mounts/processes live."
fi
