#!/usr/bin/env bash
# checkmk/snmp-preflight.sh — test SNMP from inside the Checkmk container before adding a host.
#
# Run on optiplex-two (the Docker host). Prompts for credentials so they never land in
# shell history or `ps` output; the test runs as the site user inside the container,
# so it uses the same network path and net-snmp tools Checkmk itself will use.
#
# Usage:  ./snmp-preflight.sh <switch-ip> [v2c|v3]
set -euo pipefail

CONTAINER="${CONTAINER:-checkmk}"   # container_name in docker_compose.yml
SITE="${SITE:-cmk}"                 # CMK_SITE_ID in docker_compose.yml
TIMEOUT=2                           # seconds per request (-t)
RETRIES=1                           # retries per request (-r)

HOST="${1:?usage: $0 <switch-ip> [v2c|v3]}"
VER="${2:-v2c}"

# --- Collect credentials (silent input) --------------------------------------
case "$VER" in
  v2c)
    read -rsp "Community: " COMMUNITY; echo
    AUTH=(-v2c -c "$COMMUNITY")
    ;;
  v3)
    read -rp  "v3 user: " V3USER
    read -rp  "Auth protocol [SHA]: " AUTHPROTO; AUTHPROTO="${AUTHPROTO:-SHA}"
    read -rsp "Auth password: " AUTHPASS; echo
    read -rp  "Priv protocol [AES]: " PRIVPROTO; PRIVPROTO="${PRIVPROTO:-AES}"
    read -rsp "Priv password: " PRIVPASS; echo
    AUTH=(-v3 -l authPriv -u "$V3USER" -a "$AUTHPROTO" -A "$AUTHPASS" -x "$PRIVPROTO" -X "$PRIVPASS")
    ;;
  *) echo "version must be v2c or v3" >&2; exit 2 ;;
esac

# Quote the auth args safely for the remote shell; they travel over stdin, not argv.
AUTH_Q=$(printf '%q ' "${AUTH[@]}")

docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
  || { echo "Container '$CONTAINER' is not running" >&2; exit 1; }

# --- Remote test script (runs as the site user inside the container) ----------
docker exec -i "$CONTAINER" su - "$SITE" -c 'bash -s' <<EOF
set -u
H=$(printf '%q' "$HOST")
A=($AUTH_Q)
O=(-t $TIMEOUT -r $RETRIES -On)
pass=0; fail=0

check() {   # check <label> <snmpget|snmpbulkwalk> <oid> [max lines] [opt]
  local label=\$1 cmd=\$2 oid=\$3 max=\${4:-1} opt=\${5:-} out rc
  out=\$(\$cmd "\${A[@]}" "\${O[@]}" "\$H" "\$oid" 2>&1); rc=\$?
  if [[ \$rc -eq 0 && -n \$out && \$out != *"No Such"* && \$out != *"No more variables"* ]]; then
    printf '[PASS] %-22s %s\n' "\$label" "\$(head -n1 <<<"\$out")"
    [[ \$max -gt 1 ]] && printf '       %s rows; first %s:\n' "\$(wc -l <<<"\$out")" "\$max" \
      && head -n "\$max" <<<"\$out" | sed 's/^/         /'
    pass=\$((pass+1))
  elif [[ -n \$opt ]]; then
    printf '[SKIP] %-22s not supported by device (optional)\n' "\$label"
  else
    printf '[FAIL] %-22s %s\n' "\$label" "\$(head -n1 <<<"\$out")"
    fail=\$((fail+1))
  fi
}

echo "== SNMP preflight: \$H ($VER) from \$(hostname) as \$(whoami) =="
command -v snmpget >/dev/null || { echo "net-snmp tools not found in container"; exit 1; }

# System group — if sysDescr fails, nothing else will work
check sysDescr     snmpget      1.3.6.1.2.1.1.1.0
check sysObjectID  snmpget      1.3.6.1.2.1.1.2.0     # Checkmk uses this to pick check plugins
check sysUpTime    snmpget      1.3.6.1.2.1.1.3.0
check sysName      snmpget      1.3.6.1.2.1.1.5.0
check sysLocation  snmpget      1.3.6.1.2.1.1.6.0
# Interfaces — what the switch-port services are built from
check ifNumber     snmpget      1.3.6.1.2.1.2.1.0
check ifDescr      snmpbulkwalk 1.3.6.1.2.1.2.2.1.2     5
check ifAlias      snmpbulkwalk 1.3.6.1.2.1.31.1.1.1.18 5   # port descriptions
check ifHCInOctets snmpbulkwalk 1.3.6.1.2.1.31.1.1.1.6  3   # 64-bit counters; needed on 1G+ ports
# Hardware — optional; many small switches don't implement these
check entPhysical  snmpbulkwalk 1.3.6.1.2.1.47.1.1.1.1.2 3 opt
check hrProcessor  snmpbulkwalk 1.3.6.1.2.1.25.3.3.1.2   3 opt

echo "== \$pass passed, \$fail failed =="
[[ \$fail -eq 0 ]]
EOF
