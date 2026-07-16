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
#   -h | --help       Show help
#
# Output:
#   <output>/REPORT.md                            Human-readable survey report
#   <output>/BORGUI-SETUP-<name>.md               Borg UI setup sheet: every value needed to
#                                                 configure this server in the Borg UI GUI
#                                                 (repository, script entity, backup plan
#                                                 source paths, excludes, schedule, retention)
#   <output>/raw/...                              Raw inventory data backing the report
#   <output>/borg-prep-appdata-<name>.sh          Generated prep script (review before deploying!)
#   <output>/BORG_UI-<name>-prep-appdata.sh       Generated Borg UI wrapper script
#
# The generated scripts are STARTING POINTS built from what was detected at survey
# time. Review them (especially rsync sources and database credentials handling)
# before deploying to /usr/local/sbin/ on the server.
#
# Licensed under the MIT License. Provided "as is" without warranty.

set -Eeuo pipefail

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
# Sudo-capable user for the deploy commands in the setup sheet - direct root SSH
# login is usually disabled, so deployment goes through this user + sudo.
DEPLOY_USER="${SUDO_USER:-}"
{ [ -n "$DEPLOY_USER" ] && [ "$DEPLOY_USER" != "root" ]; } || DEPLOY_USER="<admin-user>"
STAMP="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT_DIR" ] || OUT_DIR="./borg-survey-${NAME}-${STAMP}"
RAW="${OUT_DIR}/raw"
REPORT="${OUT_DIR}/REPORT.md"

if [ "$(id -u)" -ne 0 ]; then
  echo "WARNING: not running as root - some information (Docker, service data dirs," >&2
  echo "         directory sizes) may be incomplete. Recommended: sudo $0" >&2
fi

have() { command -v "$1" >/dev/null 2>&1; }
slugify() { echo "$1" | sed 's|^/||; s|/|-|g; s|[^A-Za-z0-9._-]|_|g'; }

dir_size() {
  # Human-readable size of a directory, bounded so a huge tree can't stall the survey.
  if [ -d "$1" ]; then
    timeout 20 du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "?"
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
declare -a DB_CONTAINERS=()      # "container|kind|detail" (kind: postgres/mysql/mariadb/mongo/redis/influxdb/other)
declare -a STANDALONE_CONTAINERS=() # "container|image|status|ports" for containers with no Compose project label
declare -a SQLITE_FILES=()       # host paths of SQLite DB files found in bind mounts
declare -a NATIVE_SERVICES=()    # "service|kind|paths" for non-Docker apps
TAILSCALE_PRESENT=0
TAILSCALE_STATE=""
K8S_KIND=""                      # k3s | microk8s | kubeadm | ""
declare -a K8S_PATHS=()
declare -a OTHER_PLATFORMS=()    # freeform notes: LXD, libvirt, ZFS, ...
declare -A DIR_SEEN=()           # dedup for APP_DIRS

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
    docker inspect -f '{{$n:=.Name}}{{range .Mounts}}{{$n}}|{{.Type}}|{{.Source}}|{{.Destination}}{{println}}{{end}}' "$c" 2>/dev/null
  done | sed 's/^\///' | grep . > "$RAW/docker-mounts.psv" || true

  while IFS='|' read -r _c mtype src _dst; do
    [ "$mtype" = "bind" ] || continue
    if [ -d "$src" ]; then
      add_app_dir "$src"
    fi
  done < "$RAW/docker-mounts.psv"

  # Database containers (by image name)
  local cname image kind detail env
  while IFS='|' read -r cname image; do
    kind="" detail=""
    case "$image" in
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
      echo "- Named volumes: $(docker volume ls -q | wc -l) (backed up by including \`/var/lib/docker/volumes\` in Borg paths)"
      echo
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
        echo "\`/var/lib/docker/volumes\`."
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
    if [ "$DOCKER_PRESENT" -eq 1 ]; then
      echo "3. \`/var/lib/docker/volumes\` - named Docker volumes (DB volumes are made consistent by the dumps in item 1)."
      local p d n=4
      for p in "${!COMPOSE_PROJECTS[@]}"; do echo "${n}. \`${COMPOSE_PROJECTS[$p]}\` - compose project '${p}'"; n=$((n+1)); done
      for d in "${APP_DIRS[@]}"; do echo "${n}. \`${d}\`"; n=$((n+1)); done
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

  cat > "$out" <<EOF
#!/usr/bin/env bash

# This script prepares an app-consistent snapshot of relevant data for backup by Borg.
# Generated by borg-backup-survey.sh on $(date -Is) for host: ${NAME}
# REVIEW BEFORE DEPLOYING - it reflects what was detected at survey time.
#
# It collects system information, Docker metadata, application data, database dumps,
# and platform state (Tailscale/Kubernetes where present). The resulting snapshot is
# staged in a temporary directory and atomically moved to the "latest" location for
# Borg to pick up. Run as root; backup data is protected with strict permissions (umask 077).
#
# Usage:
#   sudo ./borg-prep-appdata-${NAME}.sh
# Deploy to /usr/local/sbin/borg-prep-appdata-${NAME}.sh on ${NAME} and ensure Borg
# includes "\${BASE}/latest" in its backup paths. Run before each Borg backup.
#
# Licensed under the MIT License. Provided "as is" without warranty.

set -Eeuo pipefail
umask 077

BASE="/var/backups/borg-apps"
LATEST="\${BASE}/latest"

mkdir -p "\$BASE"
TMP="\$(mktemp -d "\${BASE}/.tmp.XXXXXX")"
trap 'rm -rf "\$TMP"' EXIT

mkdir -p "\$TMP"/{metadata,docker,apps,databases,native,tailscale,kubernetes}

echo "Preparing app-consistent backup data for ${NAME}..."

# -----------------------------
# System and Docker inventory
# -----------------------------
{
  date -Is
  hostnamectl || true
  uname -a || true
  cat /etc/os-release || true
} > "\$TMP/metadata/system-info.txt"

dpkg-query -W -f='\${binary:Package}\t\${Version}\n' > "\$TMP/metadata/dpkg-packages.tsv" 2>/dev/null || true
EOF

  # --- Docker inventory + compose configs ---
  if [ "$DOCKER_PRESENT" -eq 1 ]; then
    cat >> "$out" <<'EOF'

docker ps -a --no-trunc > "$TMP/docker/docker-ps-a.txt" 2>/dev/null || true
docker images --digests > "$TMP/docker/docker-images.txt" 2>/dev/null || true
docker volume ls > "$TMP/docker/docker-volumes.txt" 2>/dev/null || true
docker network ls > "$TMP/docker/docker-networks.txt" 2>/dev/null || true

docker inspect $(docker ps -aq) > "$TMP/docker/docker-inspect-all.json" 2>/dev/null || true
EOF
    local p wdir slug
    for p in "${!COMPOSE_PROJECTS[@]}"; do
      wdir="${COMPOSE_PROJECTS[$p]}"
      slug="$(slugify "$wdir")"
      cat >> "$out" <<EOF

# -----------------------------
# Compose project: ${p}
# -----------------------------
if [ -d ${wdir} ]; then
  rsync -a --delete \\
    --exclude='*.db-wal' \\
    --exclude='*.db-shm' \\
    ${wdir}/ "\$TMP/apps/${slug}/"
fi
EOF
    done
  fi

  # --- Bind-mounted app dirs ---
  local d slug size
  for d in "${APP_DIRS[@]}"; do
    slug="$(slugify "$d")"
    size="$(dir_size "$d")"
    case "$size" in
      *T|[0-9][0-9]G|[0-9][0-9][0-9]G)
        # Very large directory: include commented out so the operator decides.
        cat >> "$out" <<EOF

# -----------------------------
# App data: ${d} (LARGE: ${size} - review before enabling; consider having Borg
# read this path directly instead of duplicating it into the snapshot)
# -----------------------------
# if [ -d ${d} ]; then
#   rsync -a --delete --exclude='*.db-wal' --exclude='*.db-shm' ${d}/ "\$TMP/apps/${slug}/"
# fi
EOF
        ;;
      *)
        cat >> "$out" <<EOF

# -----------------------------
# App data: ${d} (${size})
# -----------------------------
if [ -d ${d} ]; then
  rsync -a --delete \\
    --exclude='*.db-wal' \\
    --exclude='*.db-shm' \\
    ${d}/ "\$TMP/apps/${slug}/"
fi
EOF
        ;;
    esac
  done

  # --- Containerized DB dumps ---
  local e cname kind detail
  for e in "${DB_CONTAINERS[@]}"; do
    cname="$(echo "$e" | cut -d'|' -f1)"
    kind="$(echo "$e" | cut -d'|' -f2)"
    detail="$(echo "$e" | cut -d'|' -f3)"
    case "$kind" in
      postgres)
        local pguser="${detail#user=}"
        cat >> "$out" <<EOF

# -----------------------------
# PostgreSQL dump: container ${cname}
# -----------------------------
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' pg_dumpall -U '${pguser:-postgres}' \\
    > "\$TMP/databases/${cname}-pg_dumpall.sql" 2>/dev/null \\
    || echo "WARN: pg_dumpall failed for ${cname}"
fi
EOF
        ;;
      mysql|mariadb)
        cat >> "$out" <<EOF

# -----------------------------
# ${kind} dump: container ${cname} (${detail})
# -----------------------------
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' sh -c \\
    'exec mysqldump --all-databases --single-transaction -uroot -p"\${MYSQL_ROOT_PASSWORD:-\$MARIADB_ROOT_PASSWORD}"' \\
    > "\$TMP/databases/${cname}-all-databases.sql" 2>/dev/null \\
    || echo "WARN: mysqldump failed for ${cname} - check credentials"
fi
EOF
        ;;
      mongo)
        cat >> "$out" <<EOF

# -----------------------------
# MongoDB dump: container ${cname}
# -----------------------------
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' mongodump --archive --quiet \\
    > "\$TMP/databases/${cname}-mongodump.archive" 2>/dev/null \\
    || echo "WARN: mongodump failed for ${cname} - add credentials if auth is enabled"
fi
EOF
        ;;
      redis)
        cat >> "$out" <<EOF

# -----------------------------
# Redis persistence flush: container ${cname}
# (dump.rdb itself is captured via the volume/bind backup)
# -----------------------------
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' redis-cli BGSAVE >/dev/null 2>&1 || true
  sleep 2
fi
EOF
        ;;
      influxdb)
        cat >> "$out" <<EOF

# -----------------------------
# InfluxDB backup: container ${cname}
# -----------------------------
if docker ps --format '{{.Names}}' | grep -qx '${cname}'; then
  docker exec '${cname}' influx backup /tmp/influx-backup >/dev/null 2>&1 \\
    && docker cp '${cname}:/tmp/influx-backup' "\$TMP/databases/${cname}-influx-backup" 2>/dev/null \\
    && docker exec '${cname}' rm -rf /tmp/influx-backup \\
    || echo "WARN: influx backup failed for ${cname} (v1.x uses 'influxd backup' instead)"
fi
EOF
        ;;
      search|other)
        cat >> "$out" <<EOF

# -----------------------------
# ${cname}: ${detail}
# No automatic dump generated - handle per engine documentation.
# -----------------------------
EOF
        ;;
    esac
  done

  # --- SQLite-safe backups ---
  local f fslug
  for f in "${SQLITE_FILES[@]}"; do
    fslug="$(slugify "$f")"
    cat >> "$out" <<EOF

# SQLite-safe backup of ${f}
if [ -f '${f}' ]; then
  sqlite3 '${f}' "PRAGMA wal_checkpoint(FULL);" >/dev/null 2>&1 || true
  sqlite3 '${f}' ".backup '\$TMP/databases/${fslug}.sqlite-backup'" || true
fi
EOF
  done

  # --- Native services ---
  local svc kind paths pth pslug
  for e in "${NATIVE_SERVICES[@]}"; do
    svc="$(echo "$e" | cut -d'|' -f1)"
    kind="$(echo "$e" | cut -d'|' -f2)"
    paths="$(echo "$e" | cut -d'|' -f3)"
    case "$kind" in
      postgres)
        cat >> "$out" <<EOF

# -----------------------------
# Native PostgreSQL (${svc}) - full cluster dump
# -----------------------------
if command -v pg_dumpall >/dev/null 2>&1; then
  su - postgres -c pg_dumpall > "\$TMP/native/postgresql-pg_dumpall.sql" 2>/dev/null \\
    || echo "WARN: native pg_dumpall failed"
fi
EOF
        ;;
      mysql|mariadb)
        cat >> "$out" <<EOF

# -----------------------------
# Native ${kind} (${svc}) - full dump (uses /root/.my.cnf or debian-sys-maint auth)
# -----------------------------
if command -v mysqldump >/dev/null 2>&1; then
  mysqldump --all-databases --single-transaction > "\$TMP/native/${kind}-all-databases.sql" 2>/dev/null \\
    || mysqldump --defaults-file=/etc/mysql/debian.cnf --all-databases --single-transaction \\
         > "\$TMP/native/${kind}-all-databases.sql" 2>/dev/null \\
    || echo "WARN: native mysqldump failed - configure credentials in /root/.my.cnf"
fi
EOF
        ;;
      mongo)
        cat >> "$out" <<EOF

# -----------------------------
# Native MongoDB (${svc}) - dump
# -----------------------------
if command -v mongodump >/dev/null 2>&1; then
  mongodump --archive --quiet > "\$TMP/native/mongodump.archive" 2>/dev/null \\
    || echo "WARN: native mongodump failed"
fi
EOF
        ;;
    esac
    # config/data path copies (config dirs only; big data dirs are covered by dumps or Borg direct paths)
    for pth in $(echo "$paths" | tr ':' ' '); do
      [ -e "$pth" ] || continue
      case "$pth" in
        /var/lib/postgresql|/var/lib/mysql|/var/lib/mongodb) continue ;; # dump covers these; raw copy of live DB is unsafe
      esac
      pslug="$(slugify "$pth")"
      cat >> "$out" <<EOF

# Config/data for ${svc}: ${pth}
if [ -e '${pth}' ]; then
  rsync -a --delete '${pth}' "\$TMP/native/${pslug}/" 2>/dev/null || true
fi
EOF
    done
  done

  # --- Tailscale ---
  if [ "$TAILSCALE_PRESENT" -eq 1 ]; then
    cat >> "$out" <<'EOF'

# -----------------------------
# Tailscale state (node identity/keys - SECRET; do not restore to a second machine)
# -----------------------------
tailscale status > "$TMP/tailscale/status.txt" 2>/dev/null || true
if [ -d /var/lib/tailscale ]; then
  rsync -a --delete /var/lib/tailscale/ "$TMP/tailscale/state/"
fi
EOF
  fi

  # --- Kubernetes ---
  case "$K8S_KIND" in
    k3s)
      cat >> "$out" <<'EOF'

# -----------------------------
# Kubernetes (k3s): datastore snapshot + config
# -----------------------------
if command -v k3s >/dev/null 2>&1; then
  # etcd datastore: use the built-in snapshot; SQLite datastore: safe-copy the db.
  if [ -d /var/lib/rancher/k3s/server/db/etcd ]; then
    k3s etcd-snapshot save --dir "$TMP/kubernetes/etcd-snapshots" >/dev/null 2>&1 \
      || echo "WARN: k3s etcd-snapshot failed"
  elif [ -f /var/lib/rancher/k3s/server/db/state.db ]; then
    sqlite3 /var/lib/rancher/k3s/server/db/state.db \
      ".backup '$TMP/kubernetes/k3s-state.db.sqlite-backup'" 2>/dev/null || true
  fi
  kubectl get all -A > "$TMP/kubernetes/resources-all.txt" 2>/dev/null || true
fi
[ -d /etc/rancher/k3s ] && rsync -a --delete /etc/rancher/k3s/ "$TMP/kubernetes/etc-rancher-k3s/"
[ -d /var/lib/rancher/k3s/server/manifests ] && rsync -a --delete /var/lib/rancher/k3s/server/manifests/ "$TMP/kubernetes/manifests/"
[ -f /var/lib/rancher/k3s/server/token ] && install -m 600 /var/lib/rancher/k3s/server/token "$TMP/kubernetes/server-token"
EOF
      ;;
    microk8s)
      cat >> "$out" <<'EOF'

# -----------------------------
# Kubernetes (microk8s)
# -----------------------------
if command -v microk8s >/dev/null 2>&1; then
  microk8s kubectl get all -A > "$TMP/kubernetes/resources-all.txt" 2>/dev/null || true
fi
# Note: for a consistent dqlite datastore backup, prefer 'microk8s.backup' tooling.
# Raw copy below captures configs/certs; the datastore may need microk8s stopped.
if [ -d /var/snap/microk8s/current/credentials ]; then
  rsync -a --delete /var/snap/microk8s/current/credentials/ "$TMP/kubernetes/credentials/"
  rsync -a --delete /var/snap/microk8s/current/certs/ "$TMP/kubernetes/certs/" 2>/dev/null || true
fi
EOF
      ;;
    kubeadm)
      cat >> "$out" <<'EOF'

# -----------------------------
# Kubernetes (kubeadm): /etc/kubernetes + etcd snapshot
# -----------------------------
[ -d /etc/kubernetes ] && rsync -a --delete /etc/kubernetes/ "$TMP/kubernetes/etc-kubernetes/"
if command -v etcdctl >/dev/null 2>&1; then
  ETCDCTL_API=3 etcdctl snapshot save "$TMP/kubernetes/etcd-snapshot.db" \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key 2>/dev/null \
    || echo "WARN: etcd snapshot failed"
fi
kubectl get all -A > "$TMP/kubernetes/resources-all.txt" 2>/dev/null || true
EOF
      ;;
  esac

  # --- Docker volume metadata + atomic publish (same pattern as smiddleware) ---
  if [ "$DOCKER_PRESENT" -eq 1 ]; then
    cat >> "$out" <<'EOF'

# -----------------------------
# Docker volume metadata only
# The actual /var/lib/docker/volumes path is backed up by Borg directly.
# -----------------------------
if [ -d /var/lib/docker/volumes ]; then
  find /var/lib/docker/volumes -maxdepth 3 -mindepth 1 -print > "$TMP/docker/docker-volume-tree.txt" 2>/dev/null || true
fi
EOF
  fi

  cat >> "$out" <<'EOF'

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

EOF
  cat >> "$out" <<EOF
echo "App-data snapshot ready at \${LATEST}"
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
# Generated by borg-backup-survey.sh on $(date -Is)

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
# Generator: BORGUI-SETUP-<name>.md - one-stop sheet with every value needed to
# configure this server in the Borg UI GUI: repository, script entity, backup
# plan (source paths, excludes, schedule), and retention/prune policy.
# ---------------------------------------------------------------------------
generate_borgui_setup() {
  local out="${OUT_DIR}/BORGUI-SETUP-${NAME}.md"
  echo "==> Writing Borg UI setup sheet to ${out}"

  # Source paths mirror the "What Borg should back up" list in REPORT.md.
  local -a src_paths=("/var/backups/borg-apps/latest" "/etc")
  local p d
  if [ "$DOCKER_PRESENT" -eq 1 ]; then
    src_paths+=("/var/lib/docker/volumes")
    for p in "${!COMPOSE_PROJECTS[@]}"; do src_paths+=("${COMPOSE_PROJECTS[$p]}"); done
    for d in "${APP_DIRS[@]}"; do src_paths+=("$d"); done
  fi

  # Exclude patterns in borg --exclude syntax: "pattern|reason".
  local -a excludes=(
    "sh:/var/backups/borg-apps/.tmp.*|in-progress prep staging dirs - only \`latest\` should be captured"
    "sh:**/*.db-wal|SQLite write-ahead logs - the prep script stages consistent copies instead"
    "sh:**/*.db-shm|SQLite shared-memory files (companions of .db-wal)"
    "sh:**/.cache|hidden application caches (recreatable)"
    "sh:**/lost+found|filesystem repair artifacts"
  )
  if [ "$DOCKER_PRESENT" -eq 1 ]; then
    excludes+=(
      "/var/lib/docker/overlay2|container image/layer store - recreatable with \`docker pull\`"
      "/var/lib/docker/buildkit|Docker build cache - recreatable"
      "/var/lib/docker/tmp|Docker scratch space"
      "sh:/var/lib/docker/containers/*/*-json.log|container stdout logs - skip unless you audit them"
    )
  fi

  {
    echo "# Borg UI Setup Sheet - ${NAME}"
    echo
    echo "- Generated: $(date -Is)"
    echo "- Server: ${NAME} (\`${ADDRESS}\`)"
    echo "- Companion files: \`REPORT.md\` (full survey), \`borg-prep-appdata-${NAME}.sh\`,"
    echo "  \`BORG_UI-${NAME}-prep-appdata.sh\` (generated with \`--generate\`)"
    echo
    echo "Work through the sections top to bottom; each maps to a screen in the Borg UI GUI."
    echo

    echo "## 1. Prerequisites (before touching the GUI)"
    echo
    echo "1. Deploy the prep script on ${NAME}. Direct root SSH login is usually disabled, so copy"
    echo "   it up as a sudo-capable user and install it with sudo:"
    echo
    echo '   ```bash'
    echo "   scp borg-prep-appdata-${NAME}.sh ${DEPLOY_USER}@${ADDRESS}:/tmp/borg-prep-appdata-${NAME}.sh"
    echo "   ssh -t ${DEPLOY_USER}@${ADDRESS} 'sudo install -o root -g root -m 700 /tmp/borg-prep-appdata-${NAME}.sh /usr/local/sbin/borg-prep-appdata-${NAME}.sh && rm /tmp/borg-prep-appdata-${NAME}.sh'"
    echo '   ```'
    echo
    echo "2. Give the Borg UI container SSH access to \`root@${ADDRESS}\`. The wrapper script logs in as"
    echo "   root with a KEY, which works even when root password login is disabled - but if sshd refuses"
    echo "   root entirely, set \`PermitRootLogin prohibit-password\` in \`/etc/ssh/sshd_config\` on ${NAME}"
    echo "   and restart \`ssh\`. Install the container's public key (Borg UI -> Settings -> SSH keys)"
    echo "   into root's authorized_keys via the sudo user:"
    echo
    echo '   ```bash'
    echo "   ssh -t ${DEPLOY_USER}@${ADDRESS} 'sudo install -d -m 700 -o root -g root /root/.ssh && echo \"<paste public key from Borg UI>\" | sudo tee -a /root/.ssh/authorized_keys >/dev/null'"
    echo '   ```'
    echo
    echo "   Then verify non-interactive login from inside the container:"
    echo
    echo '   ```bash'
    echo "   docker exec -it borg-backup ssh -o BatchMode=yes root@${ADDRESS} true && echo OK"
    echo '   ```'
    echo
    echo "3. Test the prep script once by hand (from inside the container, using the key installed above):"
    echo
    echo '   ```bash'
    echo "   docker exec -it borg-backup ssh root@${ADDRESS} /usr/local/sbin/borg-prep-appdata-${NAME}.sh"
    echo "   docker exec -it borg-backup ssh root@${ADDRESS} ls -la /var/backups/borg-apps/latest"
    echo '   ```'
    echo

    echo "## 2. Repository (Borg UI -> Repositories -> Add)"
    echo
    echo "| GUI field | Value |"
    echo "| --- | --- |"
    echo "| Name | \`${NAME}\` |"
    echo "| Location (in-container path) | \`/local/${NAME}\` |"
    echo "| Encryption | \`repokey-blake2\` |"
    echo "| Passphrase | generate with \`openssl rand -base64 32\`; store in your password manager |"
    echo
    echo "The in-container path needs a host directory behind it - add this line to the"
    echo "\`borg-ui\` service volumes in \`docker_compose.yml\` and recreate the container:"
    echo
    echo '```yaml'
    echo "      - /mnt/borg_${NAME}:/local/${NAME}:rw"
    echo '```'
    echo
    echo "(Alternative: a remote repo over SSH, e.g. \`ssh://borg@backup-host:22/./repos/${NAME}\` - then no volume line is needed.)"
    echo
    echo "After the repo is initialized, export the key and store it OUTSIDE the repo -"
    echo "with \`repokey\` the key lives in the repo config, so a lost/corrupt repo also loses the key:"
    echo
    echo '```bash'
    echo "docker exec -it borg-backup borg key export /local/${NAME} /local/borgui-config-export/${NAME}-borg-key.txt"
    echo '```'
    echo

    echo "## 3. Script entity (Borg UI -> Scripts -> Add)"
    echo
    echo "| GUI field | Value |"
    echo "| --- | --- |"
    echo "| Name | \`${NAME}-prep-appdata\` |"
    echo "| Description | Pre-backup app-data snapshot for ${NAME} services |"
    echo "| Run-on | Always - Regardless of result |"
    echo "| Time-out | 300 seconds (5 minutes) |"
    echo "| Script content | paste from \`BORG_UI-${NAME}-prep-appdata.sh\` (the \`#!/bin/bash\` block) |"
    echo

    echo "## 4. Backup plan (Borg UI -> Backups -> Add)"
    echo
    echo "| GUI field | Value |"
    echo "| --- | --- |"
    echo "| Plan name | \`${NAME}-daily\` |"
    echo "| Repository | \`${NAME}\` |"
    echo "| Archive name template | \`${NAME}-{now:%Y-%m-%d_%H%M%S}\` |"
    echo "| Compression | \`zstd,3\` |"
    echo "| Schedule | daily at 02:00 (cron \`0 2 * * *\`) - stagger if multiple servers share the Borg host |"
    echo "| Pre-backup script | \`${NAME}-prep-appdata\` (section 3) - **must run before every backup** |"
    echo
    echo "### Source paths"
    echo
    echo "| Path | Size at survey time | Why |"
    echo "| --- | --- | --- |"
    local why
    for d in "${src_paths[@]}"; do
      case "$d" in
        /var/backups/borg-apps/latest) why="app-consistent snapshot staged by the prep script (DB dumps, metadata, configs)" ;;
        /etc)                          why="system configuration" ;;
        /var/lib/docker/volumes)       why="named Docker volumes (DB volumes made consistent by the dumps above)" ;;
        *)
          why="bind-mounted app data"
          for p in "${!COMPOSE_PROJECTS[@]}"; do
            [ "$d" = "${COMPOSE_PROJECTS[$p]}" ] && why="compose project '${p}'"
          done
          ;;
      esac
      echo "| \`${d}\` | $(dir_size "$d") | ${why} |"
    done
    echo
    echo "### Exclude patterns"
    echo
    echo "Paste one per line into the plan's exclude list (borg \`--exclude\` syntax; \`sh:\` = shell-style glob):"
    echo
    echo "| Pattern | Reason |"
    echo "| --- | --- |"
    local e
    for e in "${excludes[@]}"; do
      echo "| \`$(echo "$e" | cut -d'|' -f1)\` | $(echo "$e" | cut -d'|' -f2) |"
    done
    echo
    echo "Also review for: large re-downloadable media, transcode/thumbnail directories"
    echo "(Plex/Jellyfin), and per-app \`cache/\` directories inside the paths above."
    echo

    echo "## 5. Retention / prune (on the same backup plan)"
    echo
    echo "| GUI field | Value |"
    echo "| --- | --- |"
    echo "| Keep daily | 7 |"
    echo "| Keep weekly | 4 |"
    echo "| Keep monthly | 6 |"
    echo "| Keep yearly | 1 |"
    echo "| Compact after prune | yes (reclaims repo space) |"
    echo

    echo "## 6. Consistency notes for this server"
    echo
    if [ "${#DB_CONTAINERS[@]}" -gt 0 ]; then
      echo "### Databases dumped by the prep script"
      echo
      echo "Raw copies of live DB files are not crash-consistent; restores must use these dumps"
      echo "from \`/var/backups/borg-apps/latest/databases/\`:"
      echo
      echo "| Container | Engine | Notes |"
      echo "| --- | --- | --- |"
      for e in "${DB_CONTAINERS[@]}"; do
        echo "| $(echo "$e" | cut -d'|' -f1) | $(echo "$e" | cut -d'|' -f2) | $(echo "$e" | cut -d'|' -f3) |"
      done
      echo
    fi
    if [ "${#SQLITE_FILES[@]}" -gt 0 ]; then
      echo "### SQLite databases (safe-copied by the prep script)"
      echo
      local f
      for f in "${SQLITE_FILES[@]}"; do echo "- \`${f}\`"; done
      echo
    fi
    if [ "${#NATIVE_SERVICES[@]}" -gt 0 ]; then
      echo "### Non-Docker services covered via the prep snapshot"
      echo
      for e in "${NATIVE_SERVICES[@]}"; do
        echo "- $(echo "$e" | cut -d'|' -f1) ($(echo "$e" | cut -d'|' -f2))"
      done
      echo
    fi
    if [ "${#STANDALONE_CONTAINERS[@]}" -gt 0 ]; then
      echo "### Standalone (non-Compose) containers"
      echo
      echo "${#STANDALONE_CONTAINERS[@]} container(s) have no compose file; their recreation record is"
      echo "\`docker/docker-inspect-all.json\` inside the prep snapshot (image, env, mounts, ports)."
      echo
    fi
    if [ "$TAILSCALE_PRESENT" -eq 1 ]; then
      echo "### Tailscale"
      echo
      echo "- Node state (\`${TAILSCALE_STATE:-/var/lib/tailscale}\`) is captured in the prep snapshot - treat the"
      echo "  archive as SECRET and never restore it to a second machine (duplicate node identity)."
      echo
    fi
    if [ -n "$K8S_KIND" ]; then
      echo "### Kubernetes (${K8S_KIND})"
      echo
      echo "- Datastore snapshot and configs are captured by the prep script; hostPath/local PVs"
      echo "  on this node should be added to the source paths above (see \`raw/k8s-pv-pvc.txt\`)."
      echo
    fi

    echo "## 7. First-run verification"
    echo
    echo "- [ ] Prep script runs clean: \`docker exec -it borg-backup ssh root@${ADDRESS} /usr/local/sbin/borg-prep-appdata-${NAME}.sh\`"
    echo "- [ ] First backup completes in Borg UI without warnings"
    echo "- [ ] Archive list shows the new archive and its size looks plausible"
    echo "- [ ] Repo key exported and stored off-repo (section 2)"
    echo "- [ ] Test restore of one file (Borg UI mount/extract into \`/restore\`)"
    echo "- [ ] For each database above: dump file exists and is non-empty in the archive under"
    echo "      \`var/backups/borg-apps/latest/databases/\`"
  } > "$out"
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
      K8S_KIND K8S_PATHS OTHER_PLATFORMS
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
  RAW="${OUT_DIR}/raw"
  REPORT="${OUT_DIR}/REPORT.md"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  echo "==> Reusing survey data from ${FROM_DIR} (collected: $(sed -n 's/^# Collected: //p' "$STATE_FILE"))"
  echo "    Skipping collection; generated scripts will land in ${OUT_DIR}/"
else
  mkdir -p "$RAW"
  collect_system
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
fi

# The Borg UI setup sheet is purely informational (nothing executes on this host),
# so it is refreshed on every run - including --report-only and --from runs.
generate_borgui_setup
echo "  Borg UI setup sheet: ${OUT_DIR}/BORGUI-SETUP-${NAME}.md"
echo

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
  echo
  echo "Generated scripts (REVIEW BEFORE DEPLOYING):"
  echo "  ${OUT_DIR}/borg-prep-appdata-${NAME}.sh"
  echo "      -> deploy to /usr/local/sbin/borg-prep-appdata-${NAME}.sh on ${NAME} (chmod 700, owner root)"
  echo "  ${OUT_DIR}/BORG_UI-${NAME}-prep-appdata.sh"
  echo "      -> paste the script content into a Borg UI script entity (see header metadata)"
  echo
  echo "Checklist before first use:"
  echo "  - Verify every rsync source path and re-enable any commented-out LARGE directories you want."
  echo "  - Confirm database dump credentials (MySQL/MariaDB may need /root/.my.cnf on the host)."
  echo "  - Configure the repo, script entity, and backup plan in Borg UI using BORGUI-SETUP-${NAME}.md"
  echo "    (source paths, exclude patterns, schedule, and retention are all listed there)."
  echo "  - Test: sudo ${OUT_DIR}/borg-prep-appdata-${NAME}.sh && ls -la /var/backups/borg-apps/latest"
fi
