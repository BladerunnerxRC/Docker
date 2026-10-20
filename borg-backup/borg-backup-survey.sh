#!/usr/bin/env bash

# borg-backup-survey.sh
#
# Surveys an Ubuntu Linux server and reports what can be backed up by Borg, then
# optionally generates custom, per-server versions of the two scripts used by this
# repo's backup workflow:
#
#   1. borg-prep-appdata-<name>.sh      - runs ON the surveyed server (as root) before
#                                         each Borg backup; stages an app-consistent
#                                         snapshot under /var/backups/borg-apps/latest.
#   2. BORG_UI-<name>-prep-appdata.sh   - Borg UI "script entity" wrapper that triggers
#                                         the prep script over SSH from the Borg server.
#
# What the survey inspects:
#   - System identity, OS, disks, installed packages
#   - Docker: containers (Compose-managed AND standalone "docker run" containers),
#     images, volumes, networks, Compose projects, bind mounts
#   - Databases running inside containers (Postgres, MySQL/MariaDB, MongoDB, Redis,
#     InfluxDB, ...) and SQLite files found in bind-mounted app dirs
#   - Applications outside Docker (systemd services: web servers, databases, media
#     servers, monitoring, etc.) and their usual data/config paths
#   - Home directories of login users (UID 1000+ under /home)
#   - Tailscale (daemon state, node status)
#   - Kubernetes (k3s, microk8s, kubeadm) including datastore/etcd considerations
#   - Other platforms: LXD, libvirt/KVM, snap packages, ZFS datasets
#
# Usage (run on the target Ubuntu server, ideally as root):
#   sudo ./borg-backup-survey.sh                 # survey + report, then ask about generating scripts
#   sudo ./borg-backup-survey.sh --report-only   # survey + report only
#   sudo ./borg-backup-survey.sh --generate      # survey + report + generate scripts without prompting
#   sudo ./borg-backup-survey.sh --from DIR      # skip the survey; generate scripts from a previous
#                                                # run's raw data (DIR = earlier output directory)
#
# If a previous survey directory for this host is found in the current directory,
# an interactive run asks whether to re-run the survey or reuse its raw data.
#
# Options:
#   --name NAME       Short server name used in generated filenames (default: hostname -s)
#   --address ADDR    IP/hostname the Borg UI wrapper should SSH to (default: primary IP)
#   --output DIR      Output directory (default: ./borg-survey-<name>-<timestamp>)
#   --from DIR        Reuse raw data from a previous survey directory (implies --generate)
#   --report-only     Do not offer to generate scripts
#   --generate        Generate scripts without prompting
#   --version         Show the version (also stamped into every generated script's header)
#   -h | --help       Show help
#
# Output:
#   <output>/REPORT.md                            Human-readable survey report
#   <output>/raw/...                              Raw inventory data backing the report
#   <output>/borg-prep-appdata-<name>.sh          Generated prep script (review before deploying!)
#   <output>/BORG_UI-<name>-prep-appdata.sh       Generated Borg UI wrapper script
#   <output>/deploy-borg-prep-<name>.sh           Installs the prep script to /usr/local/sbin
#                                                 (backup of the old one, diff, safety checks)
#
# The generated scripts are STARTING POINTS built from what was detected at survey
# time. Review them (especially rsync sources and database credentials handling)
# before deploying to /usr/local/sbin/ on the server.
#
# Licensed under the MIT License. Provided "as is" without warranty.

set -Eeuo pipefail

# Keep in step with borg-backup/VERSION and CHANGELOG.md.
SURVEY_VERSION="3.0.0"

# ---------------------------------------------------------------------------
# Arguments and defaults
# ---------------------------------------------------------------------------
MODE="prompt"          # prompt | report-only | generate
NAME=""
ADDRESS=""
OUT_DIR=""
FROM_DIR=""

usage() { awk 'NR>2 {if (!/^#/) exit; sub(/^# ?/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="${2:?--name requires a value}"; shift 2 ;;
    --address)     ADDRESS="${2:?--address requires a value}"; shift 2 ;;
    --output)      OUT_DIR="${2:?--output requires a value}"; shift 2 ;;
    --from)        FROM_DIR="${2:?--from requires a value}"; shift 2 ;;
    --report-only) MODE="report-only"; shift ;;
    --generate)    MODE="generate"; shift ;;
    --version)     echo "borg-backup-survey.sh ${SURVEY_VERSION}"; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -n "$FROM_DIR" ] && [ "$MODE" = "report-only" ]; then
  echo "ERROR: --from reuses existing raw data to generate scripts; it cannot be combined with --report-only." >&2
  exit 1
fi
[ -n "$FROM_DIR" ] && MODE="generate"

[ -n "$NAME" ] || NAME="$(hostname -s 2>/dev/null || echo server)"
[ -n "$ADDRESS" ] || ADDRESS="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[ -n "$ADDRESS" ] || ADDRESS="<server-ip>"

# NAME and ADDRESS are written into generated shell scripts, so only allow hostname-safe tokens.
if ! [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
  echo "ERROR: server name '$NAME' is not a valid short hostname (letters, digits, '-'); pass --name NAME." >&2
  exit 1
fi
if [ "$ADDRESS" != "<server-ip>" ] && ! [[ "$ADDRESS" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]]; then
  echo "ERROR: address '$ADDRESS' is not a valid IP address or hostname; pass --address ADDR." >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT_DIR" ] || OUT_DIR="./borg-survey-${NAME}-${STAMP}"
RAW="${OUT_DIR}/raw"
REPORT="${OUT_DIR}/REPORT.md"

if [ "$(id -u)" -ne 0 ]; then
  echo "WARNING: not running as root - some information (Docker, service data dirs," >&2
  echo "         directory sizes) may be incomplete. Recommended: sudo $0" >&2
fi

# The output can hold secrets (docker inspect includes container environment variables), so
# everything is written private. Under sudo, the output dir is handed to the user who ran sudo
# when the survey exits, so they can read it without sudo. An existing --output dir must be an
# earlier survey's folder or empty: it is closed up before anything is written into it, because
# umask doesn't change files that already exist. Any other existing dir is refused.
# Missing parents of --output are created first, with normal permissions, so the user can still
# reach the output folder that is handed back to them.
if [ -z "$FROM_DIR" ] && [ ! -d "$(dirname "$OUT_DIR")" ]; then
  mkdir -p "$(dirname "$OUT_DIR")"
fi
umask 077
HAND_BACK=0
if [ ! -e "$OUT_DIR" ]; then
  HAND_BACK=1
elif [ -n "$FROM_DIR" ]; then
  :   # --from replaces OUT_DIR below
elif [ -d "$OUT_DIR" ] && { [ -f "$OUT_DIR/raw/survey-state.sh" ] || [ -z "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; }; then
  HAND_BACK=1
  chmod -R go-rwx "$OUT_DIR" 2>/dev/null || {
    echo "ERROR: cannot make ${OUT_DIR} private (it was probably written by root) - re-run with sudo." >&2
    exit 1
  }
else
  echo "ERROR: --output ${OUT_DIR} already exists and is not an earlier survey's folder - choose a new folder." >&2
  exit 1
fi
hand_back_output() {
  [ "$HAND_BACK" -eq 1 ] && [ -d "$OUT_DIR" ] || return 0
  # umask only covers new files; this also closes up a --from dir written by an older survey.
  chmod -R go-rwx "$OUT_DIR" 2>/dev/null || true
  if [ "$(id -u)" -eq 0 ] && [[ "${SUDO_UID:-}" =~ ^[1-9][0-9]*$ ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$OUT_DIR" 2>/dev/null || true
  fi
}
trap hand_back_output EXIT

have() { command -v "$1" >/dev/null 2>&1; }
slugify() { echo "$1" | sed 's|^/||; s|/|-|g; s|[^A-Za-z0-9._-]|_|g'; }

dir_size() {
  # Human-readable size of a directory, bounded so a huge tree can't stall the survey.
  # du exits non-zero after printing its total when some entries are unreadable: keep that
  # total, and print "?" only when there is none (du timed out).
  local s
  if [ -d "$1" ]; then
    s="$(timeout 20 du -sh "$1" 2>/dev/null | awk 'NR == 1 {print $1}')" || true
    echo "${s:-?}"
  else
    echo "-"
  fi
}

# ---------------------------------------------------------------------------
# Collected state (filled by the collectors below, consumed by report/generators)
# ---------------------------------------------------------------------------
DOCKER_PRESENT=0
declare -A COMPOSE_PROJECTS=()   # project name -> working dir
declare -a APP_DIRS=()           # host dirs worth rsync-ing into the snapshot
declare -a DB_CONTAINERS=()      # "container|kind|detail" (kind: checkmk/postgres/mysql/mariadb/mongo/redis/influxdb/other)
declare -a STANDALONE_CONTAINERS=() # "container|image|status|ports" for containers with no Compose project label
declare -a SQLITE_FILES=()       # host paths of SQLite DB files found in bind mounts
declare -a NATIVE_SERVICES=()    # "service|kind|paths" for non-Docker apps
TAILSCALE_PRESENT=0
TAILSCALE_STATE=""
K8S_KIND=""                      # k3s | microk8s | kubeadm | ""
declare -a K8S_PATHS=()
declare -a OTHER_PLATFORMS=()    # freeform notes: LXD, libvirt, ZFS, ...
declare -A NAMED_VOLUMES=()      # Docker named volume in use -> containers using it ("a, b")
DOCKER_VOLUMES_DIR="/var/lib/docker/volumes"   # <docker data-root>/volumes, from docker info
# Created by the operator once the host's Borg plan reads DOCKER_VOLUMES_DIR. Outside the prep
# script on purpose, so deploying or regenerating the script never resets it.
DOCKER_VOLUMES_ACK="/etc/borg-backup/docker-volumes-in-plan"
# Local folder where deploy-borg-prep-<name>.sh keeps rollback copies (<base>/<name>/<date-time>/).
# The prep script copies it into each snapshot, so Borg carries it off the host.
SCRIPT_BACKUP_BASE="/var/backups/borg-script-backups"
KEEP_SCRIPT_BACKUPS=10
declare -a HOME_DIRS=()         # home dirs of login users (UID 1000+ under /home)
declare -A HOME_SIZE=()          # home dir -> du -sh size, measured once (not saved in state)
declare -A DIR_SEEN=()           # dedup for APP_DIRS

# dir_size results of 10G and up, or unknown ("?"), are LARGE: their copies are generated
# commented out so the operator decides. du -h prints whole numbers from 10 up (even 1010G).
is_large() { [[ "$1" == "?" || "$1" =~ ^[0-9]{2,}G$ || "$1" =~ ^[0-9.]+[TPE]$ ]]; }

# Why a LARGE directory was generated commented out, for comments and the report.
large_note() { if [ "$1" = "?" ]; then echo "size unknown, du timed out"; else echo "LARGE: $1"; fi; }

# Fills HOME_SIZE for every home dir not measured yet. Call directly, not in $( ): the
# cache has to survive in this shell.
measure_homes() {
  local h
  for h in "${HOME_DIRS[@]}"; do
    [ -n "${HOME_SIZE[$h]:-}" ] || HOME_SIZE[$h]="$(dir_size "$h")"
  done
}

# Home dirs the generated prep script copies whole (set by generate_prep_script).
declare -a COPIED_HOMES=()

# Named volumes are not copied into the prep snapshot, so the Borg plan has to read them itself.
warn_named_volumes() {
  [ "${#NAMED_VOLUMES[@]}" -gt 0 ] || return 0
  echo "WARNING: ${#NAMED_VOLUMES[@]} Docker named volume(s) in use: ${!NAMED_VOLUMES[*]}"
  echo "         They are NOT in the prep snapshot. Add ${DOCKER_VOLUMES_DIR} to this host's"
  echo "         Borg plan, then turn the warning off: sudo mkdir -p /etc/borg-backup &&"
  echo "         sudo touch ${DOCKER_VOLUMES_ACK}"
  echo
}

# True if path $1 is one of the home dirs or inside one (for the report's recommendations).
in_any_home() {
  local h
  for h in "${HOME_DIRS[@]}"; do
    case "$1" in "$h"|"$h"/*) return 0 ;; esac
  done
  return 1
}

# Prints the copied home dir that contains path $1; fails if none does. The home copy uses
# rsync --one-file-system, so a path on another file system (a separate disk or NFS mount inside
# the home) is not covered by it. When that can't be checked (the path is missing here, as with
# --from on another machine), it counts as not covered: a second copy beats a missing one.
home_containing() {
  local h hdev pdev
  for h in "${COPIED_HOMES[@]}"; do
    case "$1" in
      "$h"|"$h"/*)
        hdev="$(stat -c %d "$h" 2>/dev/null)" || return 1
        pdev="$(stat -c %d "$1" 2>/dev/null)" || return 1
        [ "$hdev" = "$pdev" ] || return 1
        echo "$h"; return 0
        ;;
    esac
  done
  return 1
}

add_app_dir() {
  local d="$1"
  [ -d "$d" ] || return 0
  case "$d" in
    /|/proc*|/sys*|/dev*|/run*|/tmp*|/var/run*|/var/lib/docker*|/etc/localtime|/etc/timezone) return 0 ;;
    *.sock) return 0 ;;
  esac
  # collapse to the compose project dir if this path lives inside one
  local p
  for p in "${!COMPOSE_PROJECTS[@]}"; do
    case "$d" in "${COMPOSE_PROJECTS[$p]}"|"${COMPOSE_PROJECTS[$p]}"/*) return 0 ;; esac
  done
  if [ -z "${DIR_SEEN[$d]:-}" ]; then
    DIR_SEEN[$d]=1
    APP_DIRS+=("$d")
  fi
}

# ---------------------------------------------------------------------------
# Collector: system
# ---------------------------------------------------------------------------
collect_system() {
  echo "==> Collecting system information..."
  {
    date -Is
    hostnamectl 2>/dev/null || true
    uname -a
    cat /etc/os-release 2>/dev/null || true
  } > "$RAW/system-info.txt"
  df -hT -x tmpfs -x devtmpfs -x overlay > "$RAW/disk-usage.txt" 2>/dev/null || true
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT > "$RAW/lsblk.txt" 2>/dev/null || true
  dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$RAW/dpkg-packages.tsv" 2>/dev/null || true
  have snap && snap list > "$RAW/snap-list.txt" 2>/dev/null || true
  crontab -l > "$RAW/root-crontab.txt" 2>/dev/null || true
  ls /etc/cron.d /etc/cron.daily /etc/cron.weekly > "$RAW/cron-dirs.txt" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Collector: home directories
# ---------------------------------------------------------------------------
collect_homes() {
  echo "==> Collecting home directories..."
  local user uid home
  # 60000+ are system/nobody accounts; homes outside /home are service accounts.
  while IFS=: read -r user _ uid _ _ home _; do
    [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] || continue
    case "$home" in /home/?*) ;; *) continue ;; esac
    [ -d "$home" ] || continue
    [ -z "${HOME_SIZE[$home]:-}" ] || continue   # several accounts can share one home
    HOME_DIRS+=("$home")
    HOME_SIZE[$home]="$(dir_size "$home")"
    printf '%s\t%s\t%s\n' "$user" "$home" "${HOME_SIZE[$home]}" >> "$RAW/home-dirs.tsv"
  done < <(getent passwd 2>/dev/null || cat /etc/passwd)
}

# ---------------------------------------------------------------------------
# Collector: Docker (containers, compose projects, mounts, in-container databases)
# ---------------------------------------------------------------------------
collect_docker() {
  if ! have docker || ! docker info >/dev/null 2>&1; then
    echo "==> Docker: not present or not accessible (skipping)"
    return 0
  fi
  DOCKER_PRESENT=1
  echo "==> Collecting Docker inventory..."

  docker ps -a --no-trunc > "$RAW/docker-ps-a.txt" 2>/dev/null || true
  docker images --digests > "$RAW/docker-images.txt" 2>/dev/null || true
  docker volume ls > "$RAW/docker-volumes.txt" 2>/dev/null || true
  docker network ls > "$RAW/docker-networks.txt" 2>/dev/null || true

  local ids
  ids="$(docker ps -aq 2>/dev/null || true)"
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  docker inspect $ids > "$RAW/docker-inspect-all.json" 2>/dev/null || true

  # Compose projects (from labels)
  local line proj wdir
  while IFS='|' read -r proj wdir; do
    [ -n "$proj" ] || continue
    [ -n "$wdir" ] && [ -d "$wdir" ] && COMPOSE_PROJECTS["$proj"]="$wdir"
  done < <(docker ps -a --format '{{.Names}}' | while read -r c; do
             docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null
           done | sort -u)

  # Standalone containers (started with "docker run" or a non-Compose tool -
  # no compose file exists to back up, so docker-inspect-all.json is their record)
  local sname simage sstatus sproj sports
  while IFS='|' read -r sname simage sstatus; do
    [ -n "$sname" ] || continue
    sproj="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$sname" 2>/dev/null || true)"
    if [ -z "$sproj" ]; then
      sports="$(docker ps -a --filter "name=^${sname}\$" --format '{{.Ports}}' 2>/dev/null | head -n1 || true)"
      STANDALONE_CONTAINERS+=("${sname}|${simage}|${sstatus}|${sports}")
    fi
  done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null || true)
  if [ "${#STANDALONE_CONTAINERS[@]}" -gt 0 ]; then
    printf '%s\n' "${STANDALONE_CONTAINERS[@]}" > "$RAW/docker-standalone-containers.psv"
  fi

  # Bind mounts -> candidate app data dirs
  docker ps -a --format '{{.Names}}' | while read -r c; do
    docker inspect -f '{{$n:=.Name}}{{range .Mounts}}{{$n}}|{{.Type}}|{{.Source}}|{{.Destination}}|{{.Name}}{{println}}{{end}}' "$c" 2>/dev/null
  done | sed 's/^\///' | grep . > "$RAW/docker-mounts.psv" || true

  # Named volumes live under <data-root>/volumes, which isn't always /var/lib/docker.
  local droot
  droot="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
  [ -n "$droot" ] && DOCKER_VOLUMES_DIR="${droot%/}/volumes"

  local vname mcont mtype src
  while IFS='|' read -r mcont mtype src _dst vname; do
    case "$mtype" in
      bind)
        if [ -d "$src" ]; then
          add_app_dir "$src"
        fi
        ;;
      volume)
        # Docker gives the volume's name directly; the prep script doesn't copy named volumes.
        [ -n "$vname" ] || continue
        NAMED_VOLUMES["$vname"]="${NAMED_VOLUMES[$vname]:+${NAMED_VOLUMES[$vname]}, }${mcont}"
        ;;
    esac
  done < "$RAW/docker-mounts.psv"

  # Database containers (by image name)
  local cname image kind detail env
  while IFS='|' read -r cname image; do
    kind="" detail=""
    case "$image" in
      *check-mk*|*checkmk*)                        kind="checkmk" ;;
      *pgvector*|*timescale*|*postgres*|*postgis*) kind="postgres" ;;
      *mysql*)                                     kind="mysql" ;;
      *mariadb*)                                   kind="mariadb" ;;
      *mongo-express*)                             kind="" ;;
      *mongo*)                                     kind="mongo" ;;
      *redis*|*valkey*)                            kind="redis" ;;
      *influxdb*)                                  kind="influxdb" ;;
      *elasticsearch*|*opensearch*)                kind="search"; detail="use snapshot API, raw file copy of a running node is not reliable" ;;
      *clickhouse*)                                kind="other"; detail="clickhouse - use BACKUP TABLE / clickhouse-backup" ;;
      *neo4j*)                                     kind="other"; detail="neo4j - use neo4j-admin dump" ;;
    esac
    if [ -n "$kind" ]; then
      env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cname" 2>/dev/null || true)"
      case "$kind" in
        checkmk)  detail="site=$(echo "$env" | sed -n 's/^CMK_SITE_ID=//p' | head -n1)"; [ "$detail" = "site=" ] && detail="site=cmk" ;;
        postgres) detail="user=$(echo "$env" | sed -n 's/^POSTGRES_USER=//p' | head -n1)"; [ "$detail" = "user=" ] && detail="user=postgres" ;;
        mysql|mariadb)
          if echo "$env" | grep -q '^MYSQL_ROOT_PASSWORD\|^MARIADB_ROOT_PASSWORD'; then detail="root password in container env"; else detail="root password NOT found in env - dump needs credentials"; fi ;;
      esac
      DB_CONTAINERS+=("${cname}|${kind}|${detail}")
    fi
  done < <(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null || true)

  # SQLite files inside bind-mounted app dirs (shallow scan)
  local d f
  for d in "${APP_DIRS[@]}"; do
    while IFS= read -r f; do
      SQLITE_FILES+=("$f")
    done < <(find "$d" -maxdepth 3 -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) 2>/dev/null | head -n 20)
  done
  # dedupe
  if [ "${#SQLITE_FILES[@]}" -gt 0 ]; then
    mapfile -t SQLITE_FILES < <(printf '%s\n' "${SQLITE_FILES[@]}" | sort -u)
  fi
}

# ---------------------------------------------------------------------------
# Collector: applications outside Docker (systemd services)
# ---------------------------------------------------------------------------
collect_native() {
  have systemctl || return 0
  echo "==> Collecting non-Docker applications (systemd services)..."
  systemctl list-units --type=service --state=running --no-pager --no-legend \
    > "$RAW/systemd-running-services.txt" 2>/dev/null || true

  # service-name-pattern|kind|data-and-config-paths (colon separated)
  local known="
postgresql|postgres|/var/lib/postgresql:/etc/postgresql
mysql|mysql|/var/lib/mysql:/etc/mysql
mariadb|mariadb|/var/lib/mysql:/etc/mysql
mongod|mongo|/var/lib/mongodb:/etc/mongod.conf
redis-server|redis|/var/lib/redis:/etc/redis
influxdb|influxdb|/var/lib/influxdb:/etc/influxdb
nginx|web|/etc/nginx:/var/www
apache2|web|/etc/apache2:/var/www
caddy|web|/etc/caddy:/var/lib/caddy
haproxy|web|/etc/haproxy
grafana-server|app|/var/lib/grafana:/etc/grafana
prometheus|app|/var/lib/prometheus:/etc/prometheus
gitea|app|/var/lib/gitea:/etc/gitea
vaultwarden|app|/var/lib/vaultwarden
jellyfin|app|/var/lib/jellyfin:/etc/jellyfin
plexmediaserver|app|/var/lib/plexmediaserver
unifi|app|/var/lib/unifi
pihole-FTL|app|/etc/pihole:/etc/dnsmasq.d
home-assistant|app|/var/lib/homeassistant
smbd|infra|/etc/samba
nfs-server|infra|/etc/exports
named|infra|/etc/bind
bind9|infra|/etc/bind
isc-dhcp-server|infra|/etc/dhcp
fail2ban|infra|/etc/fail2ban
netdata|app|/etc/netdata:/var/lib/netdata
zabbix-server|app|/etc/zabbix
openvpn|infra|/etc/openvpn
wg-quick@|infra|/etc/wireguard
"
  local unit pat kind paths
  while IFS='|' read -r pat kind paths; do
    [ -n "$pat" ] || continue
    unit="$(awk -v p="$pat" '$1 ~ "^"p {print $1; exit}' "$RAW/systemd-running-services.txt" 2>/dev/null || true)"
    if [ -n "$unit" ]; then
      NATIVE_SERVICES+=("${unit}|${kind}|${paths}")
    fi
  done <<< "$known"
}

# ---------------------------------------------------------------------------
# Collector: Tailscale
# ---------------------------------------------------------------------------
collect_tailscale() {
  if have tailscale || [ -d /var/lib/tailscale ]; then
    echo "==> Collecting Tailscale information..."
    TAILSCALE_PRESENT=1
    [ -d /var/lib/tailscale ] && TAILSCALE_STATE="/var/lib/tailscale"
    tailscale status > "$RAW/tailscale-status.txt" 2>/dev/null || true
    tailscale ip > "$RAW/tailscale-ip.txt" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Collector: Kubernetes
# ---------------------------------------------------------------------------
collect_kubernetes() {
  if [ -d /etc/rancher/k3s ] || have k3s; then
    K8S_KIND="k3s"
    K8S_PATHS=(/etc/rancher/k3s /var/lib/rancher/k3s/server/manifests /var/lib/rancher/k3s/server/token)
  elif have microk8s || [ -d /var/snap/microk8s ]; then
    K8S_KIND="microk8s"
    K8S_PATHS=(/var/snap/microk8s/current)
  elif [ -d /etc/kubernetes/manifests ]; then
    K8S_KIND="kubeadm"
    K8S_PATHS=(/etc/kubernetes)
  fi
  if [ -n "$K8S_KIND" ]; then
    echo "==> Collecting Kubernetes ($K8S_KIND) information..."
    { have kubectl && kubectl get nodes -o wide; } > "$RAW/k8s-nodes.txt" 2>/dev/null || true
    { have kubectl && kubectl get all -A; } > "$RAW/k8s-all.txt" 2>/dev/null || true
    { have kubectl && kubectl get pv,pvc -A; } > "$RAW/k8s-pv-pvc.txt" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Collector: other platforms (LXD, libvirt, ZFS)
# ---------------------------------------------------------------------------
collect_other() {
  if have lxc && lxc list >/dev/null 2>&1; then
    OTHER_PLATFORMS+=("LXD detected - containers/VMs listed in raw/lxd-list.txt; use 'lxc export' for instance backups, or back up /var/snap/lxd/common/lxd (snap) with LXD stopped")
    lxc list > "$RAW/lxd-list.txt" 2>/dev/null || true
  fi
  if have virsh && virsh list --all >/dev/null 2>&1; then
    OTHER_PLATFORMS+=("libvirt/KVM detected - domains in raw/libvirt-list.txt; back up /etc/libvirt (XML configs); disk images in /var/lib/libvirt/images need VM shutdown or qcow2 snapshots for consistency")
    virsh list --all > "$RAW/libvirt-list.txt" 2>/dev/null || true
  fi
  if have zfs && zfs list >/dev/null 2>&1; then
    OTHER_PLATFORMS+=("ZFS detected - datasets in raw/zfs-list.txt; consider 'zfs snapshot' before Borg reads dataset paths for point-in-time consistency")
    zfs list -o name,used,mountpoint > "$RAW/zfs-list.txt" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
write_report() {
  echo "==> Writing report to ${REPORT}"
  {
    echo "# Borg Backup Survey - ${NAME}"
    echo
    echo "- Generated: $(date -Is)"
    echo "- Host: $(hostname -f 2>/dev/null || hostname)"
    echo "- Address: ${ADDRESS}"
    echo "- OS: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo "- Surveyed as root: $([ "$(id -u)" -eq 0 ] && echo yes || echo 'NO - results may be incomplete')"
    echo
    echo "Raw inventory data backing this report is in \`raw/\`."
    echo

    # --- Docker ---
    echo "## Docker"
    echo
    if [ "$DOCKER_PRESENT" -eq 1 ]; then
      echo "- Containers: $(docker ps -q | wc -l) running / $(docker ps -aq | wc -l) total"
      echo "- Named volumes: ${#NAMED_VOLUMES[@]} in use by containers, $(docker volume ls -q | wc -l) in total"
      echo
      if [ "${#NAMED_VOLUMES[@]}" -gt 0 ]; then
        echo "### ⚠️ Named volumes - NOT in the prep snapshot"
        echo
        echo "**Add \`${DOCKER_VOLUMES_DIR}\` to this host's Borg plan, or these volumes are not backed up.**"
        echo "The prep script copies bind-mounted folders into the snapshot, but not named volumes."
        echo "Database dumps still cover databases stored in them. The prep script reports a warning"
        echo "on every run until the plan includes the path and you turn the warning off with"
        echo "\`sudo mkdir -p /etc/borg-backup && sudo touch ${DOCKER_VOLUMES_ACK}\`."
        echo
        echo "| Volume | Used by | Size |"
        echo "| --- | --- | --- |"
        # One du for all volumes, bounded as a whole, instead of up to 20 s per volume.
        local v vs vp
        local -a vpaths=()
        local -A vsize=()
        for v in "${!NAMED_VOLUMES[@]}"; do vpaths+=("${DOCKER_VOLUMES_DIR}/${v}/_data"); done
        while IFS=$'\t' read -r vs vp; do vsize[$vp]="$vs"; done \
          < <(timeout 60 du -sh "${vpaths[@]}" 2>/dev/null || true)
        for v in "${!NAMED_VOLUMES[@]}"; do
          echo "| \`${v}\` | ${NAMED_VOLUMES[$v]} | ${vsize[${DOCKER_VOLUMES_DIR}/${v}/_data]:-?} |"
        done
        echo
      fi
      if [ "${#COMPOSE_PROJECTS[@]}" -gt 0 ]; then
        echo "### Compose projects"
        echo
        echo "| Project | Working dir | Size |"
        echo "| --- | --- | --- |"
        local p
        for p in "${!COMPOSE_PROJECTS[@]}"; do
          echo "| ${p} | \`${COMPOSE_PROJECTS[$p]}\` | $(dir_size "${COMPOSE_PROJECTS[$p]}") |"
        done
        echo
      fi
      if [ "${#STANDALONE_CONTAINERS[@]}" -gt 0 ]; then
        echo "### Standalone containers (not managed by Compose)"
        echo
        echo "These containers were started with \`docker run\` (or a non-Compose tool), so there"
        echo "is no compose file to back up. The \`docker-inspect-all.json\` captured by the prep"
        echo "script is the record of how to recreate them (image, env, mounts, ports, restart"
        echo "policy). Their bind mounts are listed below; named volumes are covered by"
        echo "\`${DOCKER_VOLUMES_DIR}\`."
        echo
        echo "| Container | Image | Status | Ports |"
        echo "| --- | --- | --- | --- |"
        local s
        for s in "${STANDALONE_CONTAINERS[@]}"; do
          echo "| $(echo "$s" | cut -d'|' -f1) | $(echo "$s" | cut -d'|' -f2) | $(echo "$s" | cut -d'|' -f3) | $(echo "$s" | cut -d'|' -f4) |"
        done
        echo
      fi
      if [ "${#APP_DIRS[@]}" -gt 0 ]; then
        echo "### Bind-mounted app data directories"
        echo
        echo "These host paths are mounted into containers and hold app state/config:"
        echo
        echo "| Host path | Size |"
        echo "| --- | --- |"
        local d
        for d in "${APP_DIRS[@]}"; do
          echo "| \`${d}\` | $(dir_size "$d") |"
        done
        echo
      fi
      if [ "${#DB_CONTAINERS[@]}" -gt 0 ]; then
        echo "### Databases running in containers"
        echo
        echo "Raw file copies of live database dirs are NOT crash-consistent. The generated"
        echo "prep script adds proper dumps for these before Borg runs:"
        echo
        echo "| Container | Engine | Notes |"
        echo "| --- | --- | --- |"
        local e
        for e in "${DB_CONTAINERS[@]}"; do
          echo "| $(echo "$e" | cut -d'|' -f1) | $(echo "$e" | cut -d'|' -f2) | $(echo "$e" | cut -d'|' -f3) |"
        done
        echo
      fi
      if [ "${#SQLITE_FILES[@]}" -gt 0 ]; then
        echo "### SQLite databases found in app dirs"
        echo
        echo "These get \`.backup\` (SQLite backup API) treatment in the generated prep script:"
        echo
        local f
        for f in "${SQLITE_FILES[@]}"; do echo "- \`${f}\`"; done
        echo
      fi
    else
      echo "Docker not detected."
      echo
    fi

    # --- Native apps ---
    echo "## Applications outside Docker"
    echo
    if [ "${#NATIVE_SERVICES[@]}" -gt 0 ]; then
      echo "| Service | Type | Data/config paths |"
      echo "| --- | --- | --- |"
      local e p out
      for e in "${NATIVE_SERVICES[@]}"; do
        out=""
        for p in $(echo "$e" | cut -d'|' -f3 | tr ':' ' '); do out="${out}\`${p}\` "; done
        echo "| $(echo "$e" | cut -d'|' -f1) | $(echo "$e" | cut -d'|' -f2) | ${out} |"
      done
      echo
      echo "Native PostgreSQL/MySQL/MongoDB services get dump commands in the generated prep script."
      echo
    else
      echo "No recognized non-Docker application services detected (see raw/systemd-running-services.txt for the full list)."
      echo
    fi

    # --- Home directories ---
    echo "## Home directories"
    echo
    if [ "${#HOME_DIRS[@]}" -gt 0 ]; then
      local hd hsize
      for hd in "${HOME_DIRS[@]}"; do
        hsize="${HOME_SIZE[$hd]:-?}"
        if is_large "$hsize"; then
          echo "- \`${hd}\` ($(large_note "$hsize")) - generated commented out; consider having Borg read it directly"
        else
          echo "- \`${hd}\` (${hsize}) - copied into the snapshot, except \`~/.cache\`, \`borg-survey-*\` folders and anything mounted inside it"
        fi
      done
    else
      echo "None found."
    fi
    echo

    # --- Tailscale ---
    echo "## Tailscale"
    echo
    if [ "$TAILSCALE_PRESENT" -eq 1 ]; then
      echo "- Tailscale detected. Node state: \`${TAILSCALE_STATE:-not found}\`"
      echo "- Backing up \`/var/lib/tailscale\` preserves node identity/keys (treat as SECRET;"
      echo "  restoring it to a second machine creates a duplicate node)."
      echo "- Often it is preferable to just re-authenticate a rebuilt machine instead of restoring state."
    else
      echo "Not detected."
    fi
    echo

    # --- Kubernetes ---
    echo "## Kubernetes"
    echo
    if [ -n "$K8S_KIND" ]; then
      echo "- Detected: **${K8S_KIND}**"
      local kp
      for kp in "${K8S_PATHS[@]}"; do [ -e "$kp" ] && echo "- Config/state path: \`${kp}\`"; done
      case "$K8S_KIND" in
        k3s)      echo "- The generated prep script runs \`k3s etcd-snapshot save\` when the etcd datastore is used, and copies the SQLite datastore (\`/var/lib/rancher/k3s/server/db\`) safely otherwise. Manifests and tokens are included." ;;
        microk8s) echo "- Use \`microk8s.backup\` or snapshot \`/var/snap/microk8s/current\`; the dqlite datastore should be captured via \`microk8s\` tooling for consistency." ;;
        kubeadm)  echo "- Back up \`/etc/kubernetes\` (incl. \`pki/\`) and take etcd snapshots via \`etcdctl snapshot save\`. Consider Velero for cluster-level resources + PVs." ;;
      esac
      echo "- Persistent volumes: see \`raw/k8s-pv-pvc.txt\` - hostPath/local PVs on this node should be added to Borg paths."
    else
      echo "Not detected."
    fi
    echo

    # --- Other platforms ---
    if [ "${#OTHER_PLATFORMS[@]}" -gt 0 ]; then
      echo "## Other platforms"
      echo
      local o
      for o in "${OTHER_PLATFORMS[@]}"; do echo "- ${o}"; done
      echo
    fi

    # --- Recommendations ---
    echo "## What Borg should back up on this server"
    echo
    echo "1. \`/var/backups/borg-apps/latest\` - the app-consistent snapshot staged by the"
    echo "   generated prep script (dumps, configs, metadata). **Run the prep script before every backup.**"
    echo "2. \`/etc\` - system configuration."
    # Compose projects and app dirs inside a home dir are covered by that home's entry.
    local p d hd n=3
    local -a covered=()
    if [ "$DOCKER_PRESENT" -eq 1 ]; then
      echo "${n}. \`${DOCKER_VOLUMES_DIR}\` - named Docker volumes (DB volumes are made consistent by the dumps in item 1)."
      n=$((n+1))
    fi
    for hd in "${HOME_DIRS[@]}"; do echo "${n}. \`${hd}\` - home directory"; n=$((n+1)); done
    if [ "$DOCKER_PRESENT" -eq 1 ]; then
      for p in "${!COMPOSE_PROJECTS[@]}"; do
        if in_any_home "${COMPOSE_PROJECTS[$p]}"; then
          covered+=("\`${COMPOSE_PROJECTS[$p]}\` (compose project '${p}')")
        else
          echo "${n}. \`${COMPOSE_PROJECTS[$p]}\` - compose project '${p}'"; n=$((n+1))
        fi
      done
      for d in "${APP_DIRS[@]}"; do
        if in_any_home "$d"; then covered+=("\`${d}\`"); else echo "${n}. \`${d}\`"; n=$((n+1)); fi
      done
    fi
    if [ "${#covered[@]}" -gt 0 ]; then
      echo
      echo "Already covered by a home directory above: $(printf '%s, ' "${covered[@]}" | sed 's/, $//')."
    fi
    echo
    echo "Suggested excludes: \`/var/lib/docker/overlay2\`, \`/var/lib/docker/tmp\`, container image"
    echo "layers (recreatable from registries), \`*.db-wal\`/\`*.db-shm\` (handled by SQLite-safe dumps),"
    echo "caches, and large re-downloadable media unless you explicitly want it."
    echo
    echo "## Consistency caveats"
    echo
    echo "- Live database files copied without a dump can be corrupt on restore - always pair"
    echo "  raw volume backups with the dumps the prep script produces."
    echo "- Secrets are included (Tailscale state, ACME certs, DB dumps). Ensure the Borg"
    echo "  repository is encrypted (\`borg init -e repokey-blake2\` or similar)."
  } > "$REPORT"
}

# ---------------------------------------------------------------------------
# Generator: borg-prep-appdata-<name>.sh
# ---------------------------------------------------------------------------
generate_prep_script() {
  local out="${OUT_DIR}/borg-prep-appdata-${NAME}.sh"
  echo "==> Generating ${out}"

  local h h2 d p wdir slug inhome
  local -A app_size=() home_note=()   # home_note: why a home gets no copy of its own

  # Decide what is copied whole, so nothing lands in the snapshot twice:
  #  - a home inside a copied app dir (a container bind-mounting /home) is copied with it;
  #  - a home inside another copied home is copied with that one;
  #  - app dirs and compose projects inside a copied home are skipped further down.
  measure_homes
  for d in "${APP_DIRS[@]}"; do app_size[$d]="$(dir_size "$d")"; done
  for h in "${HOME_DIRS[@]}"; do
    is_large "${HOME_SIZE[$h]}" && continue
    for d in "${APP_DIRS[@]}"; do
      is_large "${app_size[$d]}" && continue
      case "$h" in "$d"|"$d"/*) home_note[$h]="inside app dir ${d}, copied with it"; break ;; esac
    done
  done
  COPIED_HOMES=()
  for h in "${HOME_DIRS[@]}"; do
    is_large "${HOME_SIZE[$h]}" && continue
    [ -z "${home_note[$h]:-}" ] || continue
    for h2 in "${HOME_DIRS[@]}"; do
      [ "$h2" != "$h" ] && [ -z "${home_note[$h2]:-}" ] && ! is_large "${HOME_SIZE[$h2]}" || continue
      # Same file system only: the outer home's copy stops at mount points (--one-file-system).
      case "$h" in
        "$h2"/*)
          if [ "$(stat -c %d "$h" 2>/dev/null)" = "$(stat -c %d "$h2" 2>/dev/null)" ] \
             && [ -n "$(stat -c %d "$h" 2>/dev/null)" ]; then
            home_note[$h]="inside home ${h2}, copied with it"; break
          fi
          ;;
      esac
    done
    [ -n "${home_note[$h]:-}" ] || COPIED_HOMES+=("$h")
  done

  cat > "$out" <<EOF
#!/usr/bin/env bash

# This script prepares an app-consistent snapshot of relevant data for backup by Borg.
# Generated by borg-backup-survey.sh ${SURVEY_VERSION} on $(date -Is) for host: ${NAME}
# REVIEW BEFORE DEPLOYING - it reflects what was detected at survey time.
#
# It collects system information, Docker metadata, application data, database dumps,
# and platform state (Tailscale/Kubernetes where present). The resulting snapshot is
# staged in a temporary directory and atomically moved to the "latest" location for
# Borg to pick up. Run as root; backup data is protected with strict permissions (umask 077).
#
# Output: timestamped progress lines on stdout, warnings on stderr, and a summary table
# at the end. The summary is also saved in the snapshot as metadata/prep-summary.txt, next to
# a copy of this script (metadata/prep-script.sh) and its rollback copies (metadata/script-backups/).
#
# Usage:
#   sudo ./borg-prep-appdata-${NAME}.sh
# Deploy to /usr/local/sbin/borg-prep-appdata-${NAME}.sh on ${NAME} and ensure Borg
# includes "\${BASE}/latest" in its backup paths. Run before each Borg backup.
#
# Licensed under the MIT License. Provided "as is" without warranty.

set -Eeuo pipefail
umask 077

HOST_NAME="${NAME}"
BASE="/var/backups/borg-apps"
LATEST="\${BASE}/latest"

# Docker named volumes are NOT copied into this snapshot; Borg has to read Docker's volumes folder
# (<data-root>/volumes, normally /var/lib/docker/volumes). While named volumes are in use, each
# run warns until this file exists. Create it once the host's Borg plan includes that folder:
#   sudo mkdir -p /etc/borg-backup && sudo touch ${DOCKER_VOLUMES_ACK}
# It lives outside this script, so deploying or regenerating the script never resets it.
DOCKER_VOLUMES_ACK="${DOCKER_VOLUMES_ACK}"

# Rollback copies kept by deploy-borg-prep-${NAME}.sh. Each run copies them, and this script
# itself, into metadata/ of the snapshot.
SCRIPT_BACKUPS="${SCRIPT_BACKUP_BASE}/${NAME}"

mkdir -p "\$BASE"
TMP="\$(mktemp -d "\${BASE}/.tmp.XXXXXX")"
trap 'rm -rf "\$TMP"' EXIT

mkdir -p "\$TMP"/{metadata,docker,apps,databases,native,tailscale,kubernetes}
EOF

  cat >> "$out" <<'EOF'

# -----------------------------
# Logging and summary helpers
# -----------------------------
RUN_START=$(date +%s)
WARNINGS=0
declare -a SUMMARY_ROWS=()   # "label|status|files|bytes|seconds"
declare -a WARN_LINES=()
SEC_LABEL="" SEC_PATHS="" SEC_START=0 SEC_STATUS=""

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() {
  WARNINGS=$((WARNINGS + 1))
  WARN_LINES+=("${SEC_LABEL:-general}: $*")
  if [ -n "$SEC_LABEL" ]; then SEC_STATUS="WARN"; fi
  printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

# Section paths are relative to $TMP; stats tolerate missing paths so set -e never trips here.
# One find pass gives both counts (file bytes, not disk usage); %.0f keeps mawk from printing
# large totals in exponent form.
section_start() {
  SEC_LABEL="$1"; SEC_PATHS="$2"; SEC_START=$(date +%s); SEC_STATUS="OK"
  log "${SEC_LABEL}..."
}
section_skip() {
  log "${SEC_LABEL}: skipped ($*)"
  SEC_STATUS="SKIP"
}
section_end() {
  local files=0 bytes=0 p n b
  for p in $SEC_PATHS; do
    [ -e "$TMP/$p" ] || continue
    n=0 b=0
    read -r n b < <(find "$TMP/$p" -type f -printf '%s\n' 2>/dev/null \
      | awk '{n++; b += $1} END {printf "%.0f %.0f\n", n, b}') || true
    files=$((files + ${n:-0})); bytes=$((bytes + ${b:-0}))
  done
  SUMMARY_ROWS+=("${SEC_LABEL}|${SEC_STATUS}|${files}|${bytes}|$(( $(date +%s) - SEC_START ))")
  SEC_LABEL=""
}

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

print_summary() {
  local row label status files bytes secs tot_files=0 tot_bytes=0 w line
  line="$(printf '%.0s-' {1..72})"
  echo "$line"
  printf ' %s pre-backup snapshot - %s\n' "$HOST_NAME" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "$line"
  printf ' %-36s %-6s %8s %10s %6s\n' "Section" "Status" "Files" "Size" "Time"
  printf ' %-36s %-6s %8s %10s %6s\n' "-------" "------" "-----" "----" "----"
  for row in "${SUMMARY_ROWS[@]}"; do
    IFS='|' read -r label status files bytes secs <<< "$row"
    printf ' %-36s %-6s %8s %10s %5ss\n' "$label" "$status" "$files" "$(human "$bytes")" "$secs"
    tot_files=$((tot_files + files)); tot_bytes=$((tot_bytes + bytes))
  done
  echo "$line"
  printf ' %-36s %-6s %8s %10s %5ss\n' "Total" "" "$tot_files" "$(human "$tot_bytes")" "$(( $(date +%s) - RUN_START ))"
  echo
  echo " Snapshot:  ${LATEST}"
  echo " Warnings:  ${WARNINGS}"
  for w in "${WARN_LINES[@]}"; do echo "   - $w"; done
  echo "$line"
}

# rsync SRC into DEST with any extra rsync options. Exit 24 (files vanished mid-copy) is normal
# on live data and stays silent; any other failure is a warning and the run continues.
copy_tree() {
  local src="$1" dest="$2" rc
  shift 2
  rsync -a --delete "$@" "$src" "$dest" \
    || { rc=$?; [ "$rc" -eq 24 ] || warn "rsync of $src exited $rc (partial copy)"; }
}

trap 'printf "[%s] ERROR: %s failed at line %s: %s\n" "$(date +%H:%M:%S)" "${SEC_LABEL:-prep script}" "$LINENO" "$BASH_COMMAND" >&2' ERR

log "Preparing app-consistent backup data for ${HOST_NAME}..."

# -----------------------------
# System inventory
# -----------------------------
section_start "System inventory" "metadata"
{
  date -Is
  hostnamectl || true
  uname -a || true
  cat /etc/os-release || true
} > "$TMP/metadata/system-info.txt"

dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$TMP/metadata/dpkg-packages.tsv" 2>/dev/null || true
section_end
EOF

  # --- Docker inventory + compose configs ---
  if [ "$DOCKER_PRESENT" -eq 1 ]; then
    cat >> "$out" <<'EOF'

# -----------------------------
# Docker inventory
# -----------------------------
section_start "Docker inventory" "docker"
if command -v docker >/dev/null 2>&1; then
  docker ps -a --no-trunc > "$TMP/docker/docker-ps-a.txt" 2>/dev/null || true
  docker images --digests > "$TMP/docker/docker-images.txt" 2>/dev/null || true
  docker volume ls > "$TMP/docker/docker-volumes.txt" 2>/dev/null || true
  docker network ls > "$TMP/docker/docker-networks.txt" 2>/dev/null || true

  docker inspect $(docker ps -aq) > "$TMP/docker/docker-inspect-all.json" 2>/dev/null || true

  # Named volumes live under Docker's data-root, which isn't always /var/lib/docker.
  vroot="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
  vroot="${vroot:-/var/lib/docker}"; vroot="${vroot%/}/volumes"

  # Docker volume metadata only - the volume data itself is backed up by Borg directly.
  if [ -d "$vroot" ]; then
    find "$vroot" -maxdepth 3 -mindepth 1 -print > "$TMP/docker/docker-volume-tree.txt" 2>/dev/null || true
  fi

  # Checked on every run, so an app added since the survey is caught too.
  vols="$(docker ps -aq 2>/dev/null \
    | xargs -r docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{println}}{{end}}{{end}}' 2>/dev/null \
    | grep . | sort -u | paste -sd' ' || true)"
  if [ -n "$vols" ]; then
    if [ -e "$DOCKER_VOLUMES_ACK" ]; then
      log "Named volumes, backed up by Borg from ${vroot}: ${vols}"
    else
      warn "named volumes not in this snapshot: ${vols} - add ${vroot} to the Borg plan, then: sudo mkdir -p ${DOCKER_VOLUMES_ACK%/*} && sudo touch ${DOCKER_VOLUMES_ACK}"
    fi
  fi
else
  section_skip "docker not installed"
fi
section_end
EOF
    for p in "${!COMPOSE_PROJECTS[@]}"; do
      wdir="${COMPOSE_PROJECTS[$p]}"
      slug="$(slugify "$wdir")"
      if inhome="$(home_containing "$wdir")"; then
        cat >> "$out" <<EOF

# Compose project ${p} (${wdir}) is inside ${inhome}, copied below with the home directory.
EOF
        continue
      fi
      cat >> "$out" <<EOF

# -----------------------------
# Compose project: ${p}
# -----------------------------
section_start "Compose project ${p}" "apps/${slug}"
if [ -d ${wdir} ]; then
  copy_tree ${wdir}/ "\$TMP/apps/${slug}/" --exclude='*.db-wal' --exclude='*.db-shm'
else
  section_skip "${wdir} not found"
fi
section_end
EOF
    done
  fi

  # --- Home directories ---
  # Only ~/.cache is excluded (/.cache/ is anchored to the home), plus survey output folders
  # anywhere in the home (their raw/ can hold container environment variables), and
  # --one-file-system keeps NAS shares or other mounts under the home out of the snapshot.
  local hslug hsize
  for h in "${HOME_DIRS[@]}"; do
    hslug="$(slugify "$h")"
    hsize="${HOME_SIZE[$h]}"
    if [ -n "${home_note[$h]:-}" ]; then
      cat >> "$out" <<EOF

# Home directory ${h} is ${home_note[$h]}.
EOF
    elif is_large "$hsize"; then
      cat >> "$out" <<EOF

# -----------------------------
# Home directory: ${h} ($(large_note "$hsize") - review before enabling; consider having
# Borg read this path directly instead of duplicating it into the snapshot)
# -----------------------------
section_start "Home directory (${h})" "apps/${hslug}"
section_skip "$(large_note "$hsize"), disabled in this script"
# copy_tree ${h}/ "\$TMP/apps/${hslug}/" --one-file-system --exclude='/.cache/' --exclude='borg-survey-*/' --exclude='*.db-wal' --exclude='*.db-shm'
section_end
EOF
    else
      cat >> "$out" <<EOF

# -----------------------------
# Home directory: ${h} (${hsize})
# -----------------------------
section_start "Home directory (${h})" "apps/${hslug}"
if [ -d ${h} ]; then
  copy_tree ${h}/ "\$TMP/apps/${hslug}/" --one-file-system --exclude='/.cache/' --exclude='borg-survey-*/' --exclude='*.db-wal' --exclude='*.db-shm'
else
  section_skip "${h} not found"
fi
section_end
EOF
    fi
  done

  # --- Bind-mounted app dirs ---
  local size
  for d in "${APP_DIRS[@]}"; do
    slug="$(slugify "$d")"
    if inhome="$(home_containing "$d")"; then
      cat >> "$out" <<EOF

# App data ${d} is inside ${inhome}, copied above with the home directory.
EOF
      continue
    fi
    size="${app_size[$d]}"
    if is_large "$size"; then
      # Very large directory: include commented out so the operator decides.
      cat >> "$out" <<EOF

# -----------------------------
# App data: ${d} ($(large_note "$size") - review before enabling; consider having
# Borg read this path directly instead of duplicating it into the snapshot)
# -----------------------------
section_start "App data (${d})" "apps/${slug}"
section_skip "$(large_note "$size"), disabled in this script"
# copy_tree ${d}/ "\$TMP/apps/${slug}/" --exclude='*.db-wal' --exclude='*.db-shm'
section_end
EOF
    else
      cat >> "$out" <<EOF

# -----------------------------
# App data: ${d} (${size})
# -----------------------------
section_start "App data (${d})" "apps/${slug}"
if [ -d ${d} ]; then
  copy_tree ${d}/ "\$TMP/apps/${slug}/" --exclude='*.db-wal' --exclude='*.db-shm'
else
  section_skip "${d} not found"
fi
section_end
EOF
    fi
  done

  # --- Containerized DB dumps ---
  local e cname kind detail
  for e in "${DB_CONTAINERS[@]}"; do
    cname="$(echo "$e" | cut -d'|' -f1)"
    kind="$(echo "$e" | cut -d'|' -f2)"
    detail="$(echo "$e" | cut -d'|' -f3)"
    case "$kind" in
      checkmk)
        local site="${detail#site=}"
        # The site name is written into the generated script; omd site names are [A-Za-z0-9_].
        if ! [[ "$site" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
          cat >> "$out" <<EOF

# -----------------------------
# Checkmk site backup: container ${cname} - site name not usable, no backup generated
# -----------------------------
section_start "Checkmk backup (${cname})" ""
section_skip "site name from CMK_SITE_ID not recognised - add 'omd backup' by hand"
section_end
EOF
          continue
        fi
        cat >> "$out" <<EOF

# -----------------------------
# Checkmk site backup: container ${cname}, site ${site}
# The site's volume is also read by Borg, but live files (RRDs, journals) can be mid-write.
# 'omd backup' writes a consistent archive of a running site; restore it with 'omd restore'.
# Uncompressed, so Borg can deduplicate it between runs. Written to .partial and renamed on
# success, so a failed run never leaves something that looks like a good backup.
# The name carries the Checkmk version and the backup time, for example
# databases/${cname}-${site}-2.5.0p9.cce-20261020-031500.omd.tar ('unknown-version' if omd can't say).
# -----------------------------
CMK_FILE=""
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  cmk_ver="\$(docker exec '${cname}' omd version '${site}' 2>/dev/null | awk '{v=\$NF} END {print v}' | tr -cd 'A-Za-z0-9._-' || true)"
  CMK_FILE="databases/${cname}-${site}-\${cmk_ver:-unknown-version}-\$(date +%Y%m%d-%H%M%S).omd.tar"
fi
section_start "Checkmk backup (${cname}, site ${site})" "\$CMK_FILE"
if [ -z "\$CMK_FILE" ]; then
  section_skip "container ${cname} not running"
elif docker exec '${cname}' omd backup --no-compression '${site}' - > "\$TMP/\$CMK_FILE.partial"; then
  mv "\$TMP/\$CMK_FILE.partial" "\$TMP/\$CMK_FILE"
else
  rm -f "\$TMP/\$CMK_FILE.partial"
  warn "omd backup failed for ${cname} (site ${site})"
fi
section_end
EOF
        ;;
      postgres)
        local pguser="${detail#user=}"
        cat >> "$out" <<EOF

# -----------------------------
# PostgreSQL dump: container ${cname}
# -----------------------------
section_start "PostgreSQL dump (${cname})" "databases/${cname}-pg_dumpall.sql"
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' pg_dumpall -U '${pguser:-postgres}' \\
    > "\$TMP/databases/${cname}-pg_dumpall.sql" 2>/dev/null \\
    || warn "pg_dumpall failed for ${cname}"
else
  section_skip "container ${cname} not running"
fi
section_end
EOF
        ;;
      mysql|mariadb)
        cat >> "$out" <<EOF

# -----------------------------
# ${kind} dump: container ${cname} (${detail})
# -----------------------------
section_start "${kind} dump (${cname})" "databases/${cname}-all-databases.sql"
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' sh -c \\
    'exec mysqldump --all-databases --single-transaction -uroot -p"\${MYSQL_ROOT_PASSWORD:-\$MARIADB_ROOT_PASSWORD}"' \\
    > "\$TMP/databases/${cname}-all-databases.sql" 2>/dev/null \\
    || warn "mysqldump failed for ${cname} - check credentials"
else
  section_skip "container ${cname} not running"
fi
section_end
EOF
        ;;
      mongo)
        cat >> "$out" <<EOF

# -----------------------------
# MongoDB dump: container ${cname}
# -----------------------------
section_start "MongoDB dump (${cname})" "databases/${cname}-mongodump.archive"
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' mongodump --archive --quiet \\
    > "\$TMP/databases/${cname}-mongodump.archive" 2>/dev/null \\
    || warn "mongodump failed for ${cname} - add credentials if auth is enabled"
else
  section_skip "container ${cname} not running"
fi
section_end
EOF
        ;;
      redis)
        cat >> "$out" <<EOF

# -----------------------------
# Redis persistence flush: container ${cname}
# (dump.rdb itself is captured via the volume/bind backup)
# -----------------------------
section_start "Redis save (${cname})" ""
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' redis-cli BGSAVE >/dev/null 2>&1 || warn "redis-cli BGSAVE failed for ${cname}"
  sleep 2
else
  section_skip "container ${cname} not running"
fi
section_end
EOF
        ;;
      influxdb)
        cat >> "$out" <<EOF

# -----------------------------
# InfluxDB backup: container ${cname}
# -----------------------------
section_start "InfluxDB backup (${cname})" "databases/${cname}-influx-backup"
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' influx backup /tmp/influx-backup >/dev/null 2>&1 \\
    && docker cp '${cname}:/tmp/influx-backup' "\$TMP/databases/${cname}-influx-backup" 2>/dev/null \\
    && docker exec '${cname}' rm -rf /tmp/influx-backup \\
    || warn "influx backup failed for ${cname} (v1.x uses 'influxd backup' instead)"
else
  section_skip "container ${cname} not running"
fi
section_end
EOF
        ;;
      search|other)
        cat >> "$out" <<EOF

# -----------------------------
# ${cname}: ${detail}
# No automatic dump generated - handle per engine documentation.
# -----------------------------
section_start "Database (${cname})" ""
section_skip "no automatic dump - see the comment in this script"
section_end
EOF
        ;;
    esac
  done

  # --- SQLite-safe backups ---
  local f fslug
  for f in "${SQLITE_FILES[@]}"; do
    fslug="$(slugify "$f")"
    cat >> "$out" <<EOF

# -----------------------------
# SQLite-safe backup of ${f}
# -----------------------------
section_start "SQLite backup (${f})" "databases/${fslug}.sqlite-backup"
if [ ! -f '${f}' ]; then
  section_skip "${f} not found"
elif ! command -v sqlite3 >/dev/null 2>&1; then
  warn "sqlite3 not installed - ${f} not captured (apt install sqlite3)"
else
  sqlite3 '${f}' "PRAGMA wal_checkpoint(FULL);" >/dev/null 2>&1 || true
  sqlite3 '${f}' ".backup '\$TMP/databases/${fslug}.sqlite-backup'" \\
    || warn "sqlite3 backup of ${f} failed"
fi
section_end
EOF
  done

  # --- Native services ---
  local svc paths pth pslug secpaths
  for e in "${NATIVE_SERVICES[@]}"; do
    svc="$(echo "$e" | cut -d'|' -f1)"
    kind="$(echo "$e" | cut -d'|' -f2)"
    paths="$(echo "$e" | cut -d'|' -f3)"
    # Collect this service's snapshot paths first, so the summary row can count them.
    case "$kind" in
      postgres)      secpaths="native/postgresql-pg_dumpall.sql" ;;
      mysql|mariadb) secpaths="native/${kind}-all-databases.sql" ;;
      mongo)         secpaths="native/mongodump.archive" ;;
      *)             secpaths="" ;;
    esac
    local -a copy_paths=()
    for pth in $(echo "$paths" | tr ':' ' '); do
      [ -e "$pth" ] || continue
      case "$pth" in
        /var/lib/postgresql|/var/lib/mysql|/var/lib/mongodb) continue ;; # dump covers these; raw copy of live DB is unsafe
      esac
      copy_paths+=("$pth")
      secpaths="${secpaths:+$secpaths }native/$(slugify "$pth")"
    done

    cat >> "$out" <<EOF

# -----------------------------
# Native service: ${svc} (${kind})
# -----------------------------
section_start "Native service ${svc}" "${secpaths}"
EOF
    case "$kind" in
      postgres)
        cat >> "$out" <<EOF
if command -v pg_dumpall >/dev/null 2>&1; then
  su - postgres -c pg_dumpall > "\$TMP/native/postgresql-pg_dumpall.sql" 2>/dev/null \\
    || warn "native pg_dumpall failed"
else
  warn "pg_dumpall not found - PostgreSQL not dumped"
fi
EOF
        ;;
      mysql|mariadb)
        cat >> "$out" <<EOF
# Full dump; uses /root/.my.cnf, then debian-sys-maint auth.
if command -v mysqldump >/dev/null 2>&1; then
  mysqldump --all-databases --single-transaction > "\$TMP/native/${kind}-all-databases.sql" 2>/dev/null \\
    || mysqldump --defaults-file=/etc/mysql/debian.cnf --all-databases --single-transaction \\
         > "\$TMP/native/${kind}-all-databases.sql" 2>/dev/null \\
    || warn "native mysqldump failed - configure credentials in /root/.my.cnf"
else
  warn "mysqldump not found - ${kind} not dumped"
fi
EOF
        ;;
      mongo)
        cat >> "$out" <<EOF
if command -v mongodump >/dev/null 2>&1; then
  mongodump --archive --quiet > "\$TMP/native/mongodump.archive" 2>/dev/null \\
    || warn "native mongodump failed"
else
  warn "mongodump not found - MongoDB not dumped"
fi
EOF
        ;;
    esac
    # Config dirs only; big data dirs are covered by dumps or Borg direct paths.
    for pth in "${copy_paths[@]}"; do
      pslug="$(slugify "$pth")"
      cat >> "$out" <<EOF
if [ -e '${pth}' ]; then
  copy_tree '${pth}' "\$TMP/native/${pslug}/"
fi
EOF
    done
    echo "section_end" >> "$out"
  done

  # --- Tailscale ---
  if [ "$TAILSCALE_PRESENT" -eq 1 ]; then
    cat >> "$out" <<'EOF'

# -----------------------------
# Tailscale state (node identity/keys - SECRET; do not restore to a second machine)
# -----------------------------
section_start "Tailscale state" "tailscale"
tailscale status > "$TMP/tailscale/status.txt" 2>/dev/null || true
if [ -d /var/lib/tailscale ]; then
  copy_tree /var/lib/tailscale/ "$TMP/tailscale/state/"
else
  section_skip "/var/lib/tailscale not found"
fi
section_end
EOF
  fi

  # --- Kubernetes ---
  case "$K8S_KIND" in
    k3s)
      cat >> "$out" <<'EOF'

# -----------------------------
# Kubernetes (k3s): datastore snapshot + config
# -----------------------------
section_start "Kubernetes (k3s)" "kubernetes"
if command -v k3s >/dev/null 2>&1; then
  # etcd datastore: use the built-in snapshot; SQLite datastore: safe-copy the db.
  # On a worker node neither exists - cluster state lives on the k3s server.
  if [ -d /var/lib/rancher/k3s/server/db/etcd ]; then
    k3s etcd-snapshot save --dir "$TMP/kubernetes/etcd-snapshots" >/dev/null 2>&1 \
      || warn "k3s etcd-snapshot failed"
  elif [ -f /var/lib/rancher/k3s/server/db/state.db ]; then
    if command -v sqlite3 >/dev/null 2>&1; then
      sqlite3 /var/lib/rancher/k3s/server/db/state.db \
        ".backup '$TMP/kubernetes/k3s-state.db.sqlite-backup'" 2>/dev/null \
        || warn "sqlite3 backup of k3s state.db failed"
    else
      warn "sqlite3 not installed - k3s state.db not captured (apt install sqlite3)"
    fi
  fi
  kubectl get all -A > "$TMP/kubernetes/resources-all.txt" 2>/dev/null || true
else
  log "k3s command not found - copying k3s config files only"
fi
# Config, manifests and token are copied whenever they exist, k3s command or not.
if [ -d /etc/rancher/k3s ]; then
  copy_tree /etc/rancher/k3s/ "$TMP/kubernetes/etc-rancher-k3s/"
fi
if [ -d /var/lib/rancher/k3s/server/manifests ]; then
  copy_tree /var/lib/rancher/k3s/server/manifests/ "$TMP/kubernetes/manifests/"
fi
if [ -f /var/lib/rancher/k3s/server/token ]; then
  install -m 600 /var/lib/rancher/k3s/server/token "$TMP/kubernetes/server-token"
fi
section_end
EOF
      ;;
    microk8s)
      cat >> "$out" <<'EOF'

# -----------------------------
# Kubernetes (microk8s)
# -----------------------------
section_start "Kubernetes (microk8s)" "kubernetes"
if command -v microk8s >/dev/null 2>&1; then
  microk8s kubectl get all -A > "$TMP/kubernetes/resources-all.txt" 2>/dev/null || true
fi
# Note: for a consistent dqlite datastore backup, prefer 'microk8s.backup' tooling.
# Raw copy below captures configs/certs; the datastore may need microk8s stopped.
if [ -d /var/snap/microk8s/current/credentials ]; then
  copy_tree /var/snap/microk8s/current/credentials/ "$TMP/kubernetes/credentials/"
  if [ -d /var/snap/microk8s/current/certs ]; then
    copy_tree /var/snap/microk8s/current/certs/ "$TMP/kubernetes/certs/"
  fi
fi
section_end
EOF
      ;;
    kubeadm)
      cat >> "$out" <<'EOF'

# -----------------------------
# Kubernetes (kubeadm): /etc/kubernetes + etcd snapshot
# -----------------------------
section_start "Kubernetes (kubeadm)" "kubernetes"
if [ -d /etc/kubernetes ]; then
  copy_tree /etc/kubernetes/ "$TMP/kubernetes/etc-kubernetes/"
fi
if command -v etcdctl >/dev/null 2>&1; then
  ETCDCTL_API=3 etcdctl snapshot save "$TMP/kubernetes/etcd-snapshot.db" \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key 2>/dev/null \
    || warn "etcd snapshot failed"
fi
kubectl get all -A > "$TMP/kubernetes/resources-all.txt" 2>/dev/null || true
section_end
EOF
      ;;
  esac

  cat >> "$out" <<'EOF'

# -----------------------------
# This script and its rollback copies, so every archive holds the script that made it
# and its recent history. Kept off-host this way; no backup share is needed.
# -----------------------------
section_start "Prep script + rollback copies" "metadata/prep-script.sh metadata/script-backups"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  install -m 600 "$SELF" "$TMP/metadata/prep-script.sh" || warn "could not copy $SELF"
else
  warn "could not find this script's own file"
fi
if [ -d "$SCRIPT_BACKUPS" ]; then
  copy_tree "$SCRIPT_BACKUPS/" "$TMP/metadata/script-backups/"
fi
section_end

# -----------------------------
# Summary (saved into the snapshot, then printed)
# -----------------------------
print_summary > "$TMP/metadata/prep-summary.txt"

# -----------------------------
# Atomic publish of latest snapshot
# -----------------------------
rm -rf "${BASE}/previous"
if [ -d "$LATEST" ]; then
  mv "$LATEST" "${BASE}/previous"
fi

mv "$TMP" "$LATEST"
trap - EXIT
rm -rf "${BASE}/previous"

log "App-data snapshot ready at ${LATEST}"
echo
cat "${LATEST}/metadata/prep-summary.txt"
EOF

  chmod +x "$out"
}

# ---------------------------------------------------------------------------
# Generator: BORG_UI-<name>-prep-appdata.sh
# ---------------------------------------------------------------------------
generate_borgui_script() {
  local out="${OUT_DIR}/BORG_UI-${NAME}-prep-appdata.sh"
  echo "==> Generating ${out}"
  cat > "$out" <<EOF
# Script body below only used to create the script entity in the Borg UI that prepares app-consistent data for backup.
# The actual content of the script is in borg-prep-appdata-${NAME}.sh, which is the one that gets executed by the Borg backup process.
# This script is essentially a placeholder that can be used to trigger the preparation of app-consistent data before the Borg backup runs,
# ensuring that all necessary information and data from the applications are captured in a consistent state for backup.
# Generated by borg-backup-survey.sh ${SURVEY_VERSION} on $(date -Is)

# Name: ${NAME}-prep-appdata
# Description: Pre-backup app-data snapshot for ${NAME} services
# Run-on: Always - Regardless of result
# Time-out: 300 seconds (5 minutes)
# Script Content:

#!/bin/bash
set -Eeuo pipefail

echo "Starting ${NAME} pre-backup app-data prep..."

ssh \\
  -o BatchMode=yes \\
  -o StrictHostKeyChecking=accept-new \\
  root@${ADDRESS} \\
  /usr/local/sbin/borg-prep-appdata-${NAME}.sh

echo "${NAME} pre-backup app-data prep completed."
EOF
}

# ---------------------------------------------------------------------------
# Generator: deploy-borg-prep-<name>.sh
# ---------------------------------------------------------------------------
generate_deploy_script() {
  local out="${OUT_DIR}/deploy-borg-prep-${NAME}.sh"
  echo "==> Generating ${out}"
  cat > "$out" <<EOF
#!/usr/bin/env bash

# deploy-borg-prep-${NAME}.sh
# Generated by borg-backup-survey.sh ${SURVEY_VERSION} on $(date -Is)
#
# Installs a reviewed prep script to /usr/local/sbin on ${NAME}, keeping a backup of the
# version it replaces. Before installing it refuses files that are not a prep script (the
# BORG_UI SSH wrapper, CRLF line endings, syntax errors, wrong host) and shows a diff against
# what is installed now.
#
# Backups go to ${SCRIPT_BACKUP_BASE}/${NAME}/<YYYYmmdd-HHMMSS>/ on this host; the newest
# ${KEEP_SCRIPT_BACKUPS} are kept. No share is needed: the prep script copies that folder into every snapshot,
# so Borg carries it off the host.
#
# Usage (on ${NAME}):
#   sudo ./deploy-borg-prep-${NAME}.sh [--yes] [--test] [SOURCE]
#                       SOURCE defaults to borg-prep-appdata-${NAME}.sh next to this script
#   sudo ./deploy-borg-prep-${NAME}.sh --rollback [--yes] [--test]
#                       reinstall the newest backup that differs from the installed script
#                       (the current version is backed up first)
#   sudo ./deploy-borg-prep-${NAME}.sh --list
#   sudo ./deploy-borg-prep-${NAME}.sh --backup-only
#                       back up the installed script without installing anything
#
#   --yes    install without the y/N prompt (required when not on a terminal)
#   --test   run the installed prep script afterwards
#
# Exit status: 0 success, 3 declined at the y/N prompt (nothing changed), other non-zero on error.
#
# Licensed under the MIT License. Provided "as is" without warranty.

set -Eeuo pipefail

EOF
  printf 'NAME=%q\n' "$NAME" >> "$out"
  printf 'BACKUP_DIR=%q\n' "${SCRIPT_BACKUP_BASE}/${NAME}" >> "$out"
  printf 'KEEP_BACKUPS=%q\n' "$KEEP_SCRIPT_BACKUPS" >> "$out"
  cat >> "$out" <<'EOF'
TARGET="/usr/local/sbin/borg-prep-appdata-${NAME}.sh"
# Where 2.x deploy scripts kept backups (Synology share) and 1.x (local). --list shows them;
# --rollback uses only BACKUP_DIR.
LEGACY_DIRS=("/mnt/backups/borg-script-backups/${NAME}" "/var/backups/borg-prep-scripts")

ACTION="install" ASSUME_YES=0 RUN_TEST=0 SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rollback) ACTION="rollback"; shift ;;
    --list)     ACTION="list"; shift ;;
    --backup-only) ACTION="backup"; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    --test)     RUN_TEST=1; shift ;;
    -h|--help)  awk 'NR>2 {if (!/^#/) exit; sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          SRC="$1"; shift ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 ...)"

# Backup folders are named YYYYmmdd-HHMMSS, so a reverse name sort is newest first.
list_backups() { ls -1d "$BACKUP_DIR"/*/"borg-prep-appdata-${NAME}.sh" 2>/dev/null | sort -r || true; }

require_backup_dir() {
  install -d -m 700 "$BACKUP_DIR" || die "cannot create $BACKUP_DIR. Nothing was changed."
}

backup_current() {
  local dir old tries=0
  require_backup_dir
  # mkdir without -p is atomic: if another backup already took this second, wait for the next one.
  dir="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"
  until mkdir "$dir" 2>/dev/null; do
    [ -e "$dir" ] && [ "$tries" -lt 5 ] || die "cannot create $dir"
    tries=$((tries + 1))
    sleep 1
    dir="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"
  done
  chmod 700 "$dir"
  cp --preserve=timestamps "$TARGET" "$dir/borg-prep-appdata-${NAME}.sh"
  echo "Backed up current script to $dir/"
  list_backups | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
    [ "$old" = "$SRC" ] && continue   # never prune the backup a rollback is about to install
    rm -f "$old"
    rmdir "$(dirname "$old")" 2>/dev/null || true
  done
}

if [ "$ACTION" = "backup" ]; then
  [ -f "$TARGET" ] || die "nothing installed at $TARGET - nothing to back up"
  backup_current
  exit 0
fi

if [ "$ACTION" = "list" ]; then
  echo "Installed: $TARGET"
  [ -f "$TARGET" ] && ls -l "$TARGET"
  echo "Backups in $BACKUP_DIR (newest first):"
  list_backups | sed 's/^/  /'
  # timeout: a 2.x share entry in fstab may be an automount whose NAS is unreachable.
  for d in "${LEGACY_DIRS[@]}"; do
    if timeout 10 test -d "$d"; then
      echo "Older backups (not used by --rollback; copy one back by hand if needed): $d"
    fi
  done
  exit 0
fi

if [ "$ACTION" = "rollback" ]; then
  require_backup_dir
  # Newest backup that differs from what is installed (after --backup-only the newest is identical).
  SRC=""
  while read -r b; do
    if [ ! -f "$TARGET" ] || ! cmp -s "$b" "$TARGET"; then SRC="$b"; break; fi
  done < <(list_backups)
  [ -n "$SRC" ] || die "no backup in $BACKUP_DIR differs from the installed script"
  echo "Rolling back to: $SRC"
else
  [ -n "$SRC" ] || SRC="$(dirname "$0")/borg-prep-appdata-${NAME}.sh"
fi

# -----------------------------
# Safety checks on the new file
# -----------------------------
[ -f "$SRC" ] && [ -s "$SRC" ] || die "source not found or empty: $SRC"

host="$(hostname -s)"
[ "$host" = "$NAME" ] || die "this host is '$host' but the script is for '$NAME' - deploy it on $NAME"

if [ "$(tr -cd '\r' < "$SRC" | wc -c)" -gt 0 ]; then
  die "$SRC has Windows (CRLF) line endings - fix with: sed -i 's/\r\$//' '$SRC'"
fi

if grep -q '^# Script Content:' "$SRC" \
   || { grep -qE '^[[:space:]]*ssh([[:space:]]|$)' "$SRC" && grep -qE '^[[:space:]]*root@' "$SRC"; }; then
  die "$SRC is the BORG_UI SSH wrapper, not the prep script. The wrapper belongs in the Borg UI script entity; installing it here makes the host SSH to itself."
fi

head -n1 "$SRC" | grep -q '^#!' || die "$SRC does not start with a #! line - is this the right file?"

grep -q 'borg-apps' "$SRC" || die "$SRC does not stage into /var/backups/borg-apps - is this a prep script?"

bash -n "$SRC" || die "syntax errors in $SRC"

# -----------------------------
# Show what changes
# -----------------------------
if [ -f "$TARGET" ] && cmp -s "$SRC" "$TARGET"; then
  echo "Installed script is already identical to $SRC - nothing to install."
else
  if [ -f "$TARGET" ]; then
    echo "Changes ($TARGET -> $SRC):"
    diff -u "$TARGET" "$SRC" || true
  else
    echo "No script installed yet at $TARGET (first install)."
  fi
  echo

  # Create the backup folder before asking, so a confirmed install never fails at the backup step.
  require_backup_dir

  if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "not on a terminal - re-run with --yes to install without prompting"
    printf 'Install %s to %s? [y/N] ' "$SRC" "$TARGET"
    read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted, nothing changed."; exit 3 ;; esac
  fi

  # -----------------------------
  # Back up current, install new
  # -----------------------------
  [ -f "$TARGET" ] && backup_current

  install -o root -g root -m 750 "$SRC" "$TARGET"
  echo "Installed $TARGET"
fi

if [ "$RUN_TEST" -eq 1 ]; then
  echo
  echo "Test run of $TARGET:"
  "$TARGET"
fi
EOF
  chmod +x "$out"
}

# ---------------------------------------------------------------------------
# After generating: offer to back up and/or deploy via the generated deploy script
# ---------------------------------------------------------------------------
offer_deploy() {
  local deploy="${OUT_DIR}/deploy-borg-prep-${NAME}.sh"
  local target="/usr/local/sbin/borg-prep-appdata-${NAME}.sh"
  local host ans rc=0
  [ -t 0 ] || return 0
  host="$(hostname -s 2>/dev/null || true)"
  if [ "$host" != "$NAME" ]; then
    echo
    echo "Not offering deployment: this host is '${host}', the scripts are for '${NAME}'."
    return 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    echo
    echo "Not offering deployment: not running as root. Later: sudo ${deploy}"
    return 0
  fi

  echo
  if [ -f "$target" ]; then
    echo "Installed prep script: ${target} ($(stat -c '%s bytes, modified %y' "$target" 2>/dev/null | cut -d. -f1))"
  else
    echo "No prep script installed yet at ${target}."
  fi
  echo
  echo "  1) Back up the installed script only"
  echo "  2) Back up the installed script and deploy the new one (shows a diff and asks first)"
  echo "  N) Nothing"
  echo
  while true; do
    printf 'Choice [1/2/N]: '
    read -r ans
    case "$ans" in
      1) bash "$deploy" --backup-only || rc=$?; break ;;
      2) bash "$deploy" || rc=$?; break ;;
      ""|n|N) echo "Nothing deployed. Later: sudo ${deploy} [--test]"; break ;;
      *) echo "Please enter 1, 2, or N." ;;
    esac
  done

  # The deploy script exits 3 when its y/N prompt is declined: a choice, not a failure.
  case "$rc" in
    0) ;;
    3) echo "Deployment cancelled, nothing changed. Later: sudo ${deploy} [--test]" ;;
    *) echo "ERROR: ${deploy} failed (exit ${rc}) - see the messages above." >&2
       return "$rc" ;;
  esac
}

# ---------------------------------------------------------------------------
# Persist collected state so a later run can regenerate scripts without re-surveying
# ---------------------------------------------------------------------------
save_state() {
  {
    echo "# Survey state saved by borg-backup-survey.sh - consumed by --from / reuse runs."
    echo "# Collected: $(date -Is)"
    declare -p DOCKER_PRESENT COMPOSE_PROJECTS APP_DIRS DB_CONTAINERS SQLITE_FILES \
      NATIVE_SERVICES STANDALONE_CONTAINERS TAILSCALE_PRESENT TAILSCALE_STATE \
      K8S_KIND K8S_PATHS OTHER_PLATFORMS HOME_DIRS NAMED_VOLUMES DOCKER_VOLUMES_DIR
  } > "$RAW/survey-state.sh"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# If a previous survey for this host exists, offer to reuse its raw data
# instead of re-running the collection.
if [ -z "$FROM_DIR" ] && [ "$MODE" = "prompt" ] && [ -t 0 ]; then
  PREV="$(ls -1dt ./borg-survey-"${NAME}"-*/ 2>/dev/null | head -n1 || true)"
  if [ -n "${PREV:-}" ] && [ -f "${PREV}raw/survey-state.sh" ]; then
    echo "A previous survey was found: ${PREV} (collected $(sed -n 's/^# Collected: //p' "${PREV}raw/survey-state.sh"))"
    echo
    echo "  1) Re-run the survey (collect fresh data, then optionally generate scripts)"
    echo "  2) Use the existing raw data to generate the scripts (no re-survey)"
    echo "  X) Exit"
    echo
    while true; do
      printf 'Choice [1/2/X]: '
      read -r ans
      case "$ans" in
        1) break ;;
        2) FROM_DIR="${PREV%/}"; MODE="generate"; break ;;
        x|X) echo "Exiting without changes."; exit 0 ;;
        *) echo "Please enter 1, 2, or X." ;;
      esac
    done
  fi
fi

if [ -n "$FROM_DIR" ]; then
  STATE_FILE="${FROM_DIR}/raw/survey-state.sh"
  if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: no survey state at ${STATE_FILE} - run a fresh survey first (that run saves reusable state)." >&2
    exit 1
  fi
  OUT_DIR="$FROM_DIR"
  HAND_BACK=1   # a survey output dir (it has survey-state.sh), possibly root-owned from an older run
  chmod -R go-rwx "$OUT_DIR" 2>/dev/null || true   # older surveys wrote it world-readable
  RAW="${OUT_DIR}/raw"
  REPORT="${OUT_DIR}/REPORT.md"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  echo "==> Reusing survey data from ${FROM_DIR} (collected: $(sed -n 's/^# Collected: //p' "$STATE_FILE"))"
  echo "    Skipping collection; generated scripts will land in ${OUT_DIR}/"
  if ! grep -q 'HOME_DIRS' "$STATE_FILE"; then
    echo "    NOTE: this survey predates home directory detection, so no home directories will be"
    echo "    included. Re-run the survey to pick them up."
  fi
else
  mkdir -p "$RAW"
  collect_system
  collect_homes
  collect_docker
  collect_native
  collect_tailscale
  collect_kubernetes
  collect_other
  save_state
  write_report

  echo
  echo "Survey complete."
  echo "  Report: ${REPORT}"
  echo "  Raw data: ${RAW}/"
  echo
  warn_named_volumes
fi

DO_GENERATE=0
case "$MODE" in
  generate) DO_GENERATE=1 ;;
  report-only) DO_GENERATE=0 ;;
  prompt)
    if [ -t 0 ]; then
      printf 'Generate custom prep scripts for this server (borg-prep-appdata-%s.sh + BORG_UI wrapper)? [y/N] ' "$NAME"
      read -r ans
      case "$ans" in y|Y|yes|YES) DO_GENERATE=1 ;; esac
    else
      echo "Non-interactive session: skipping script generation (use --generate to force)."
    fi
    ;;
esac

if [ "$DO_GENERATE" -eq 1 ]; then
  generate_prep_script
  generate_borgui_script
  generate_deploy_script
  echo
  echo "Generated scripts (REVIEW BEFORE DEPLOYING):"
  echo "  ${OUT_DIR}/borg-prep-appdata-${NAME}.sh"
  echo "      -> deploy to /usr/local/sbin/borg-prep-appdata-${NAME}.sh on ${NAME} (chmod 750, owner root)"
  echo "  ${OUT_DIR}/deploy-borg-prep-${NAME}.sh"
  echo "      -> sudo ${OUT_DIR}/deploy-borg-prep-${NAME}.sh --test  (backs up the installed version, shows a diff, installs, test-runs)"
  echo "  ${OUT_DIR}/BORG_UI-${NAME}-prep-appdata.sh"
  echo "      -> paste the script content into a Borg UI script entity (see header metadata)"
  echo
  echo "Checklist before first use:"
  echo "  - Verify every rsync source path and re-enable any commented-out LARGE directories you want."
  echo "  - Confirm database dump credentials (MySQL/MariaDB may need /root/.my.cnf on the host)."
  echo "  - Add /var/backups/borg-apps/latest (plus paths listed in REPORT.md) to the Borg job's source paths."
  echo "  - Test: sudo ${OUT_DIR}/borg-prep-appdata-${NAME}.sh && ls -la /var/backups/borg-apps/latest"
  echo
  warn_named_volumes

  offer_deploy
fi
