#!/usr/bin/env bash
# checkmk/create-piggyback-hosts.sh — create Checkmk hosts for Docker containers that send
# piggyback data (mk_docker.py, container_id: combined → "<dockerhost>_<container>").
#
# Layout it follows (see HANDOFF-POC.md → "Checkmk host layout"):
#   Main/<ROOT_FOLDER>            "Docker Stacks": No IP, no agent, no SNMP, piggyback always
#   Main/<ROOT_FOLDER>/<stack>/   one per Compose project: parents = stack host, label stack:<name>
#     <PREFIX><stack>             dummy stack host: role:stack, never piggyback, parent = Docker node
#     <node>_<container>          containers: NO host attributes, everything inherited
#
# Placement of each NEW container (existing hosts are never touched):
#   1. its Compose project already has a subfolder (matched on title or folder name) → there
#   2. project has >= STACK_MIN containers → new subfolder + stack host are created → there
#   3. otherwise → ROOT_FOLDER, with parents = its Docker node (only explicit attribute used)
# The Compose project comes from the com.docker.compose.project label that mk_docker.py ships
# in the docker_container_labels piggyback section — no SSH to the Docker nodes needed.
#
# Run on optiplex-two (the Docker host running the checkmk container).
# Default is a dry run; pass --apply to create folders/hosts, run discovery and activate.
#
# Usage:  ./create-piggyback-hosts.sh [--apply]
# Env:    ROOT_FOLDER=docker  STACK_MIN=2  STACK_HOST_PREFIX=stack-  CONTAINER=checkmk  SITE=cmk
#         API=http://localhost:8081/cmk/check_mk/api/1.0  CMK_USER/CMK_SECRET (else automation user)
set -euo pipefail
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
exec python3 - "$@" <<'PY'
import getpass, json, os, re, shlex, subprocess, sys, urllib.error, urllib.request

CONTAINER = os.environ.get("CONTAINER", "checkmk")     # container_name in docker_compose.yml
SITE      = os.environ.get("SITE", "cmk")              # CMK_SITE_ID
API       = os.environ.get("API", f"http://localhost:8081/{SITE}/check_mk/api/1.0")
ROOT      = os.environ.get("ROOT_FOLDER", "docker")    # folder *name* under Main (title may differ)
STACK_MIN = int(os.environ.get("STACK_MIN", "2"))      # containers needed to auto-create a stack folder
PREFIX    = os.environ.get("STACK_HOST_PREFIX", "stack-")
APPLY     = "--apply" in sys.argv[1:]

def site(cmd, stdin=None):
    """Run a shell command as the site user inside the Checkmk container."""
    return subprocess.run(["docker", "exec", "-i", CONTAINER, "su", "-", SITE, "-c", cmd],
                          input=stdin, capture_output=True, text=True, check=True).stdout

# --- Credentials: automation user secret from the site, else prompt ------------------------
user   = os.environ.get("CMK_USER", "automation")
secret = os.environ.get("CMK_SECRET") or site(
    "cat ~/var/check_mk/web/automation/automation.secret 2>/dev/null || true").strip()
if not secret:
    with open("/dev/tty") as tty:                       # stdin is this script, so read the terminal
        print("Checkmk user [cmkadmin]: ", end="", flush=True)
        user = tty.readline().strip() or "cmkadmin"
    secret = getpass.getpass(f"Password/secret for {user}: ")

def api(method, path, body=None, etag=None, missing_ok=False):
    """Call the REST API; returns (json, etag). missing_ok → (None, None) on 404."""
    req = urllib.request.Request(API + path, method=method,
                                 data=None if body is None else json.dumps(body).encode())
    req.add_header("Authorization", f"Bearer {user} {secret}")
    req.add_header("Accept", "application/json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if etag:
        req.add_header("If-Match", etag)
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return (json.loads(raw) if raw else None), r.headers.get("ETag")
    except urllib.error.HTTPError as e:
        if missing_ok and e.code == 404:
            return None, None
        sys.exit(f"API {method} {path} → HTTP {e.code}: {e.read().decode(errors='replace')[:500]}")

def ref(path):                                           # "/docker/komga" → "~docker~komga"
    return "~" + path.strip("/").replace("/", "~")

def slug(name):                                          # valid folder/host-name characters only
    return re.sub(r"[^A-Za-z0-9_-]+", "-", name).strip("-").lower()

# --- Piggyback sources + Compose project, read from the site's piggyback files -------------
LABELS_PY = r'''
import glob, json, os
base = os.path.expanduser("~/tmp/check_mk/piggyback")
out = {}
for d in sorted(os.listdir(base)):
    proj = ""
    for f in glob.glob(os.path.join(base, d, "*")):
        try:
            lines = open(f, errors="replace").read().splitlines()
        except OSError:
            continue
        in_labels = False
        for line in lines:
            if line.startswith("<<<"):
                in_labels = line.startswith("<<<docker_container_labels")
            elif in_labels and line.startswith("{"):
                try:
                    proj = json.loads(line).get("com.docker.compose.project", "") or proj
                except ValueError:
                    pass
    out[d] = proj
print(json.dumps(out))
'''
piggy = json.loads(site("python3 -", stdin=LABELS_PY))

hosts, _ = api("GET", "/domain-types/host_config/collections/all")
existing = {h["id"] for h in hosts["value"]}

stale = sorted(h for h in piggy if "_" not in h)        # old short-ID data, no "<node>_" prefix
new   = sorted(h for h in piggy if "_" in h and h not in existing)

# Container count per project (all piggyback hosts, not just new) decides auto-folder creation
count = {}
for h, p in piggy.items():
    if "_" in h and p:
        count[p] = count.get(p, 0) + 1

# --- Existing stack subfolders under ROOT, matched on title or folder name -----------------
root_obj, _ = api("GET", f"/objects/folder_config/~{ROOT}", missing_ok=True)
folders = {}
if root_obj:
    sub, _ = api("GET", f"/domain-types/folder_config/collections/all?parent=~{ROOT}&recursive=false")
    for f in sub["value"]:
        path = f.get("extensions", {}).get("path") or f.get("id", "").replace("~", "/")
        for key in (slug(f.get("title", "")), slug(path.rstrip("/").rsplit("/", 1)[-1])):
            if key:
                folders.setdefault(key, path)

# --- Plan ---------------------------------------------------------------------------------
plan, new_stacks = [], {}       # plan: (host, folder_path, attributes); new_stacks: slug → info
for h in new:
    node, proj = h.split("_", 1)[0], piggy[h]
    key = slug(proj)
    if key and key in folders:
        plan.append((h, folders[key], {}))
    elif key and count.get(proj, 0) >= STACK_MIN:
        path = f"/{ROOT}/{key}"
        new_stacks.setdefault(key, {"title": proj, "path": path, "node": node,
                                    "host": PREFIX + key})
        plan.append((h, path, {}))
    else:
        plan.append((h, f"/{ROOT}", {"parents": [node]} if node in existing else {}))

print(f"Piggyback sources : {len(piggy)}")
print(f"Already hosts     : {len(piggy) - len(new) - len(stale)}")
print(f"Stale (ignored)   : {' '.join(stale) or 'none'}")
print(f"Root folder       : /{ROOT} {'(exists)' if root_obj else '(will be created)'}")
if not root_obj:                                         # likely a wrong ROOT_FOLDER: show the real ones
    top, _ = api("GET", "/domain-types/folder_config/collections/all?parent=~&recursive=false")
    names = [f"{f.get('extensions', {}).get('path', '?')} ({f.get('title', '')})" for f in top["value"]]
    print(f"  Existing top-level folders: {', '.join(names) or 'none'} — set ROOT_FOLDER=<name> if one is meant")
for s in new_stacks.values():
    print(f"New stack folder  : {s['path']}  + stack host {s['host']} (parent {s['node']})")
print(f"To create         : {len(plan)}")
for h, path, attrs in plan:
    note = f"  parents={attrs['parents'][0]}" if attrs.get("parents") else ""
    print(f"  + {h:<55} → {path}{note}  [project: {piggy[h] or '-'}]")
if not plan:
    sys.exit(0)
if not APPLY:
    print("\nDry run. Re-run with --apply to create.")
    sys.exit(0)

# --- Apply: root folder (only if missing) --------------------------------------------------
if not root_obj:
    api("POST", "/domain-types/folder_config/collections/all", {
        "name": ROOT, "title": "Docker Stacks", "parent": "~",
        "attributes": {"tag_address_family": "no-ip", "tag_agent": "no-agent",
                       "tag_snmp_ds": "no-snmp", "tag_piggyback": "piggyback",
                       "labels": {"type": "container"}}})
    print(f"Created folder /{ROOT}")

# --- Apply: new stack folders + their dummy stack hosts ------------------------------------
for key, s in new_stacks.items():
    api("POST", "/domain-types/folder_config/collections/all", {
        "name": key, "title": s["title"], "parent": f"~{ROOT}",
        "attributes": {"labels": {"stack": key}}})
    if s["host"] not in existing:
        attrs = {"tag_piggyback": "no-piggyback", "labels": {"role": "stack", "stack": key}}
        if s["node"] in existing:
            attrs["parents"] = [s["node"]]               # explicit: overrides the folder's parent
        api("POST", "/domain-types/host_config/collections/all",
            {"host_name": s["host"], "folder": ref(s["path"]), "attributes": attrs})
        existing.add(s["host"])
    _, etag = api("GET", f"/objects/folder_config/{ref(s['path'])}")
    api("PUT", f"/objects/folder_config/{ref(s['path'])}",
        {"update_attributes": {"parents": [s["host"]]}}, etag=etag)
    print(f"Created stack folder {s['path']} with stack host {s['host']}")

# --- Apply: containers (no host attributes except parents for root-level ones) -------------
api("POST", "/domain-types/host_config/actions/bulk-create/invoke", {"entries": [
    {"host_name": h, "folder": ref(path), "attributes": attrs} for h, path, attrs in plan]})
print(f"Created {len(plan)} container hosts")

# --- Discovery on the new containers only, then activate -----------------------------------
site("cmk -II " + " ".join(shlex.quote(h) for h, _, _ in plan))
_, etag = api("GET", "/domain-types/activation_run/collections/pending_changes")
api("POST", "/domain-types/activation_run/actions/activate-changes/invoke",
    {"redirect": False, "sites": [], "force_foreign_changes": False}, etag=etag or "*")
print("Activation started — check Setup → Changes.")
PY
