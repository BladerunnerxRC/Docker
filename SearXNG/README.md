# SearXNG

LAN metasearch for browsers and a future Claude/ChatGPT MCP search bridge.
[docker-compose.yml](docker-compose.yml) deploys SearXNG and Valkey;
[settings.yml](settings.yml) enables HTML/JSON and defines the engine selection;
[limiter.toml](limiter.toml) permits trusted LAN/API clients.

| Service | Image | Purpose |
| --- | --- | --- |
| `searxng` | Tag and digest pinned in Compose | Web UI and JSON search at `192.168.200.14:8888`. |
| `valkey` | `valkey/valkey:8-alpine` | Limiter counters and cache; no published port. |

SearXNG waits for Valkey's healthcheck. Both services have memory limits,
bounded logs, `no-new-privileges`, and reduced capabilities. The SearXNG image
remains pinned to `2026.9.3-a1144dda3`; revalidate engine names and behavior when
upgrading. These settings do not upgrade the image.

## Engine selection

Settings inherit upstream defaults but keep only the following engines. This
intentionally replaces the upstream selection with a **text-search** setup:
image, video, music, map, and other engines are not included. Review this list
before replacing existing custom settings.

| Category | Engines | Purpose |
| --- | --- | --- |
| `general` | Brave, DuckDuckGo, Mojeek, Mwmbl, searchmysite, Wiby, Wikipedia | Broad coverage plus independent/small-web sources. |
| `discovery` | Mojeek, Mwmbl, searchmysite, Wiby | Query alternatives separately so broad-engine results do not crowd them out. |
| `it` | GitHub, Stack Overflow, Arch Linux Wiki, Hacker News | Code, documentation, and discussion. |
| `science` | arXiv, Semantic Scholar, PubMed, OpenAlex, Crossref | Publications and research metadata. |

Marginalia remains **inactive** until a personal API key is configured. Once
enabled, it joins `general` and `discovery`. Enablement does not establish
reliability: test upstream blocks, CAPTCHAs, quotas, and coverage from the host.
Wikipedia includes ordinary results as well as infoboxes for JSON consumers.

The default engine timeout is five seconds; research engines get eight seconds
(including Crossref, whose upstream timeout is longer). The maximum request
timeout is ten seconds. Upstream error suspension/backoff is retained.
Autocomplete is off. Existing `safe_search: 0` behavior is retained; clients can
request `safesearch=1` or `2` where supported. English is the default search
language and can be overridden per request.

## Deploy as a Portainer stack

1. Create a stack named `searxng` using [docker-compose.yml](docker-compose.yml),
   or use this repository and Compose path `SearXNG/docker-compose.yml`.
2. Set the stack environment variables:

   | Variable | Required | Meaning |
   | --- | --- | --- |
   | `SEARXNG_SECRET` | yes | Generate with `openssl rand -hex 32`; keep outside Git. Compose refuses deployment without it. |
   | `SEARXNG_BASE_URL` | no | Defaults to `http://192.168.200.14:8888/`. Set the external URL behind a reverse proxy. |

3. Deploy, then follow **Apply settings** on the Docker host. First startup
   generates default settings in the volume; it does not install the tracked
   files or automatically enable JSON.

The network uses `172.30.0.0/24` to avoid the existing `172.28.0.0/16`
`mariadb-kodi-bak_default` network. Check for LAN/VPN/Docker route overlaps on
other hosts. This subnet also appears in the limiter passlist.

## Storage

| Named volume | Container path | Contents |
| --- | --- | --- |
| `searxng_config` | `/etc/searxng` | Deployed settings, limiter, and private local changes. |
| `searxng_cache` | `/var/cache/searxng` | Reconstructible application cache. |
| `searxng_valkey_data` | `/data` | Reserved for Valkey; RDB and AOF persistence are disabled. |

Valkey uses a 192 MB eviction limit inside a 256 MB container and does not fork
for snapshots. SearXNG's entrypoint fixes volume ownership; its config volume is
writable and the service retains `CHOWN`/`DAC_OVERRIDE`.

## Apply settings

**A Git pull or Portainer redeploy does not update `searxng_config`.** Run the
following explicitly on the Docker host, from this repository's `SearXNG`
directory. These commands restart SearXNG; they are not an automatic deploy hook.

First inspect the deployed configuration privately and preserve desired local
changes. The tracked file replaces the previous engine selection and settings.
The required stack environment still supplies the instance secret and Valkey URL.
Never paste deployed settings or API credentials into Git or logs.

Back up before changing anything. This temporary directory is outside the
checkout and private because the original configuration may contain credentials:

```sh
set -eu
umask 077
backup_dir=$(mktemp -d /tmp/searxng-config.XXXXXXXX)
docker cp searxng:/etc/searxng/. "$backup_dir/"
printf 'Keep this backup path for rollback: %s\n' "$backup_dir"
```

After the backup succeeds, copy both reviewed files and restart in the same shell:

```sh
docker cp settings.yml searxng:/etc/searxng/settings.yml
docker cp limiter.toml searxng:/etc/searxng/limiter.toml
docker restart searxng
```

`set -e` stops the shell if a copy fails. Keep the backup until verification
succeeds. Applying the tracked file again overwrites private edits, including
optional engine credentials. Merge those into a private copy first if needed,
and copy that file instead of the tracked `settings.yml`.

### Rollback

In the same shell, or after setting `backup_dir` to the saved path, check the
backup is the expected one. Restore the original settings and limiter. If the
backup had no limiter file, move the newly installed one aside so built-in
limiter defaults apply again:

```sh
test -s "$backup_dir/settings.yml"
docker cp "$backup_dir/settings.yml" searxng:/etc/searxng/settings.yml
if test -f "$backup_dir/limiter.toml"; then
  docker cp "$backup_dir/limiter.toml" searxng:/etc/searxng/limiter.toml
else
  docker exec searxng sh -c 'mv /etc/searxng/limiter.toml /etc/searxng/limiter.toml.failed'
fi
docker restart searxng
```

Backups under `/tmp` may be cleared by reboot or cleanup. For longer retention,
use a private backup location outside the repository.

## Verify from the actual MCP client

An HTTP 200 healthcheck does not establish JSON access or upstream engine health.
Run these from the intended MCP host/container because its source address affects
the limiter:

```sh
curl --fail --show-error --max-time 5 'http://192.168.200.14:8888/healthz'
curl --fail --show-error --max-time 20 --get \
  'http://192.168.200.14:8888/search' \
  --data-urlencode 'q=home server backup' \
  --data-urlencode 'format=json' \
  --data-urlencode 'categories=discovery'
```

Require JSON with a `results` array, rather than accepting any HTTP 200 page.
Check `unresponsive_engines`, engine provenance, and response times. Test each
discovery engine individually by replacing `categories=discovery` with
`engines=mojeek`, then repeat for `wiby`, `mwmbl`, and `searchmysite`. Use short
queries suited to smaller indexes; zero results alone do not mean an engine is
broken. Test Marginalia only after configuring its key.

The public `/config` endpoint shows engine enablement and effective timeouts.
Do not dump private settings to diagnose those public values.

- **403 for JSON:** check `search.formats` in the deployed file and restart.
- **429 or an HTML redirect/page:** inspect the actual source address seen by
  SearXNG and its deployed limiter configuration.
- **JSON with engine errors:** inspect upstream failures and allow backoff;
  do not disable suspension or repeatedly retry blocked engines.

## Limiter and reverse proxy

Compose forces the limiter on. The passlist covers the trusted LAN
`192.168.200.0/24` and SearXNG bridge `172.30.0.0/24`. These clients bypass bot
checks. Everyone else faces bot detection, API limits, and CSS link tokens.
A non-browser API client needs a deliberately permitted path.

Another Docker bridge, NAT route, or proxy can present a different address.
Verify the actual MCP request path; prefer a narrow host or dedicated client
subnet entry instead of trusting every Docker network. A passlist does not
authenticate clients or bypass upstream engine limits. `pass_searxng_org`
remains off for this private instance.

For Traefik, attach SearXNG to the dedicated proxy network, remove the published
port if unnecessary, and set `SEARXNG_BASE_URL`. Add only the actual proxy IP or
dedicated proxy subnet to `trusted_proxies`, ensuring the proxy overwrites
client-supplied forwarding headers. Do not trust all of `172.16.0.0/12`.
Retest effective client IP and passlist matching after this change.

## Optional Marginalia

Obtain a personal key using the [Marginalia API instructions](https://about.marginalia-search.com/article/api/).
In the **private deployed copy** of `settings.yml`, find the existing `marginalia`
entry, set `inactive: false` and `disabled: false`, and add `api_key` with that key.
Restart and verify individually. Never commit the key, and preserve API license
and attribution information. Do not use the shared `public` development key for
routine LLM searches. Reapplying tracked settings disables Marginalia again.

## MCP boundary

```text
Claude / ChatGPT -> MCP search bridge -> SearXNG JSON API -> selected engines
```

This stack supplies the backend. `/search?format=json` is an HTTP API, not an MCP
endpoint; this configuration does not deploy or configure an MCP bridge.
A future bridge should accept category/engine, language, time range, and page;
preserve source URLs, snippets, engine names, and partial failures; deduplicate
URLs; and use a response timeout above the engine budget (start at 20 seconds).
Keep concurrency low and bound result counts. Full-page fetching is a separate
capability from search snippets.

Use `categories=discovery`, `general`, `it`, or `science` for the selections above.
Client connectivity, authentication, and any cloud-to-LAN connection require
separate setup before Claude or ChatGPT can use the backend.

References: [settings inheritance](https://docs.searxng.org/admin/settings/settings.html),
[engine configuration](https://docs.searxng.org/admin/settings/settings_engines.html),
[search API](https://docs.searxng.org/dev/search_api.html),
[outgoing timeouts](https://docs.searxng.org/admin/settings/settings_outgoing.html).
