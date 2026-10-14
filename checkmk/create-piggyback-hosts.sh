#!/usr/bin/env bash
# checkmk/create-piggyback-hosts.sh — create Checkmk hosts for Docker containers that send
# piggyback data (mk_docker.py, container_id: combined → "<dockerhost>_<container>").
#
# Run on optiplex-two (the Docker host running the checkmk container).
# Default is a dry run; pass --apply to create hosts, run discovery and activate changes.
#
# Usage:  ./create-piggyback-hosts.sh [--apply]
set -euo pipefail

CONTAINER="${CONTAINER:-checkmk}"                       # container_name in docker_compose.yml
SITE="${SITE:-cmk}"                                     # CMK_SITE_ID
API="${API:-http://localhost:8081/${SITE}/check_mk/api/1.0}"
FOLDER="${FOLDER:-docker}"                              # created under Main if missing
APPLY=false; [[ "${1:-}" == "--apply" ]] && APPLY=true

site() { docker exec "$CONTAINER" su - "$SITE" -c "$1"; }

# --- Credentials: automation user secret from the site, else prompt ---------------
CMK_USER="${CMK_USER:-automation}"
CMK_SECRET="${CMK_SECRET:-$(site 'cat ~/var/check_mk/web/automation/automation.secret 2>/dev/null' || true)}"
if [[ -z "$CMK_SECRET" ]]; then
  read -rp  "Checkmk user [cmkadmin]: " u; CMK_USER="${u:-cmkadmin}"
  read -rsp "Password/secret for $CMK_USER: " CMK_SECRET; echo
fi
AUTH="Authorization: Bearer $CMK_USER $CMK_SECRET"

api() {   # api <METHOD> <path> [json-body] [extra curl args...]
  local m=$1 p=$2 body=${3:-}; shift 3 2>/dev/null || shift $#
  curl -sS -f -X "$m" "$API$p" -H "$AUTH" -H 'Accept: application/json' \
       ${body:+-H 'Content-Type: application/json' --data "$body"} "$@"
}

# --- Gather state --------------------------------------------------------------------
mapfile -t PIGGY < <(site 'ls ~/tmp/check_mk/piggyback/' | sort)
EXISTING=$(api GET '/domain-types/host_config/collections/all' '' \
  | python3 -c 'import sys,json; print("\n".join(h["id"] for h in json.load(sys.stdin)["value"]))')

NEW=(); STALE=()
for h in "${PIGGY[@]}"; do
  [[ "$h" == *_* ]] || { STALE+=("$h"); continue; }        # old short-ID data, no "<host>_" prefix
  grep -qxF "$h" <<<"$EXISTING" || NEW+=("$h")
done

echo "Piggyback sources : ${#PIGGY[@]}"
echo "Already hosts     : $(( ${#PIGGY[@]} - ${#NEW[@]} - ${#STALE[@]} ))"
echo "Stale (ignored)   : ${STALE[*]:-none}"
echo "To create         : ${#NEW[@]}"
[[ ${#NEW[@]} -eq 0 ]] && exit 0
printf '  + %s\n' "${NEW[@]}"
$APPLY || { echo; echo "Dry run. Re-run with --apply to create."; exit 0; }

# --- Folder ----------------------------------------------------------------------------
api GET "/objects/folder_config/~$FOLDER" '' -o /dev/null 2>/dev/null \
  || api POST '/domain-types/folder_config/collections/all' \
       "{\"name\":\"$FOLDER\",\"title\":\"Docker containers\",\"parent\":\"/\"}" -o /dev/null

# --- Bulk create: no IP, no agent, no SNMP, piggyback only, parent = Docker host -------
BODY=$(printf '%s\n' "${NEW[@]}" | EXISTING="$EXISTING" FOLDER="$FOLDER" python3 -c '
import sys, json, os
existing = set(os.environ["EXISTING"].split())
entries = []
for name in sys.stdin.read().split():
    parent = name.split("_", 1)[0]
    attrs = {"tag_address_family": "no-ip", "tag_agent": "no-agent",
             "tag_snmp_ds": "no-snmp", "tag_piggyback": "piggyback"}
    if parent in existing:                       # only reference parents that exist
        attrs["parents"] = [parent]
    entries.append({"host_name": name, "folder": "~" + os.environ["FOLDER"], "attributes": attrs})
print(json.dumps({"entries": entries}))')
api POST '/domain-types/host_config/actions/bulk-create/invoke' "$BODY" -o /dev/null
echo "Created ${#NEW[@]} hosts in folder /$FOLDER"

# --- Discovery (tabula rasa on the new hosts only), then activate ----------------------
site "cmk -II $(printf '%q ' "${NEW[@]}")"
ETAG=$(api GET '/domain-types/activation_run/collections/pending_changes' '' -D - -o /dev/null \
  | awk 'tolower($1)=="etag:"{print $2}' | tr -d '\r')
api POST '/domain-types/activation_run/actions/activate-changes/invoke' \
  '{"redirect":false,"sites":[],"force_foreign_changes":false}' -H "If-Match: ${ETAG:-*}" -o /dev/null
echo "Activation started — check Setup → Changes."
