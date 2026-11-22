# create-piggyback-hosts.sh

Creates Checkmk hosts for Docker containers and files them into the
[host layout](HANDOFF-POC.md#checkmk-host-layout).

## Why it's needed
The `mk_docker.py` agent plugin reports every container as **piggyback data** under the name
`<node>_<container>` (e.g. `optiplex-docker_komga`). Checkmk only shows that data once a host
with **exactly that name** exists. Community edition can't create those hosts automatically
(that's an Enterprise feature), and creating them by hand is slow and error-prone. This
script does it in one pass, the same way every time.

## What it does
1. Lists every container Checkmk has piggyback data for, and every existing host.
2. Picks out the containers that **don't have a host yet**.
3. Reads each container's **Compose / Portainer stack name** from that same piggyback data.
   It doesn't need SSH access to the Docker nodes.
4. Decides where each new host goes:
   | Situation | Destination |
   |---|---|
   | A stack folder for that project already exists (title or name matches) | That folder |
   | No folder, but the project has ≥ 2 containers | New folder `Docker Stacks/<stack>`, plus dummy host `stack-<stack>` |
   | Single-container app | `Docker Stacks` itself, with Parents = its Docker node |
5. Prints the plan. **It stops there unless you pass `--apply`.**
6. With `--apply`, it creates the folders and hosts, runs service discovery on the new hosts
   only, and activates changes.

Container hosts are created with **no settings of their own**, so they inherit IP, agent,
SNMP, piggyback, parents and labels from their folder.

## What it does NOT do
- **Doesn't change, move or delete existing hosts.** Containers you've already added stay
  where they are, with whatever settings they have.
- **Doesn't delete stale data.** Old short-ID piggyback entries (e.g. `5e2e8268c605`) are
  listed and skipped.
- **Doesn't touch rules.** The `role:stack` rules (always up, no notifications) must already
  exist. See the handoff.
- **Doesn't install anything on the Docker nodes.** `mk_docker.py` + `python3-docker` +
  `/etc/check_mk/docker.cfg` (`container_id: combined`) must already be in place.
- **Doesn't know about K3s pods.** Those run in containerd, not Docker.
- **Doesn't fuzzy-match names.** A project called `borg` won't match a folder called
  `Borg-backup`. Check the dry run.

## Requirements
- Run on **optiplex-two** (the host running the `checkmk` container) as a user who can run
  `docker`.
- `python3` on the host (standard on Ubuntu).
- REST API access. The script uses the site's `automation` user automatically, or prompts for a
  user and password if it can't find that.

## How to use
```bash
cd ~/docker-repo && git pull                     # get the latest script

./checkmk/create-piggyback-hosts.sh              # 1. dry run: read the plan
./checkmk/create-piggyback-hosts.sh --apply      # 2. apply it once the plan looks right
```
Then check **Monitor → Parent / Child topology**: new containers should sit under their stack
host or Docker node.

### Reading the dry run
```
Root folder       : /docker (exists)
New stack folder  : /docker/manyfold  + stack host stack-manyfold (parent optiplex-docker)
To create         : 3
  + optiplex-docker_manyfold-app-1   → /docker/manyfold  [project: manyfold]
  + optiplex-two_it-tools            → /docker  parents=optiplex-two  [project: it-tools]
```
- `Root folder … (will be created)` means the script didn't find your Docker Stacks folder. It
  lists the real top-level folders; re-run with `ROOT_FOLDER=<name>`. The folder **name** is in
  the URL and can differ from its title.
- A `New stack folder` you didn't expect usually means the project name doesn't match your
  existing folder. Rename the folder (or its title) to match, then re-run.

## Settings (environment variables)
| Variable | Default | Purpose |
|---|---|---|
| `ROOT_FOLDER` | `docker` | Folder name of *Docker Stacks* under Main |
| `STACK_MIN` | `2` | Containers a project needs before a stack folder is auto-created |
| `STACK_HOST_PREFIX` | `stack-` | Dummy stack host name = prefix + stack name |
| `CONTAINER` / `SITE` | `checkmk` / `cmk` | Checkmk container name and site ID |
| `API` | `http://localhost:8081/cmk/check_mk/api/1.0` | REST API base URL |
| `CMK_USER` / `CMK_SECRET` | automation user | Override API credentials |

Example: `ROOT_FOLDER=docker_stacks STACK_MIN=1 ./checkmk/create-piggyback-hosts.sh`

## Troubleshooting
| Symptom | Cause / fix |
|---|---|
| `HTTP 401` | Wrong credentials. Set `CMK_USER`/`CMK_SECRET` or answer the prompt. |
| `HTTP 400 … parents` | A parent host doesn't exist. Add the Docker node to Checkmk first. |
| A container never appears in the list | Its node isn't sending piggyback data. Run `sudo check_mk_agent \| grep -c '^<<<<'` on that node. |
| Activation fails afterwards | Run `docker exec -it checkmk su - cmk -c 'cmk -U 2>&1 \| grep -i error'`. Most likely a host is its own parent. |
