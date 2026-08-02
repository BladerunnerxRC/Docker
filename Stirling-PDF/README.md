# Stirling-PDF

![Docker Compose](https://img.shields.io/badge/deploy-docker%20compose-2496ED?logo=docker&logoColor=white)
![Stirling-PDF](https://img.shields.io/badge/app-stirling--pdf-DC2626)
![Java](https://img.shields.io/badge/runtime-jvm-E76F00?logo=openjdk&logoColor=white)
![License](https://img.shields.io/badge/upstream-MIT-green)

Local, self-hosted PDF toolkit — merge, split, rotate, convert, compress, OCR, redact, and
sign PDFs without anything leaving the host. Single-service stack:
[docker-compose.yml](docker-compose.yml).

| Service | Image | Purpose |
| --- | --- | --- |
| `stirling-pdf` | `stirlingtools/stirling-pdf:latest` | Web UI + REST API on host port **8080**, on its own `stirling-net` bridge network. |

Upstream: [Stirling-Tools/Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF) ·
[docs.stirlingpdf.com](https://docs.stirlingpdf.com)

## Deploy

No `.env` file and no host paths to pre-create — every bit of state lives in named volumes.

```bash
docker compose up -d
```

Then browse to `http://<host>:8080/`.

> [!NOTE]
> First boot is slow. The JVM warms up, LibreOffice initialises, and `init.sh` copies OCR
> data into place before the app answers. Give it a minute or two before assuming
> something is wrong — see [Health](#health).

### Image variants

| Tag | Contents | When to use |
| --- | --- | --- |
| `latest` (this stack) | All PDF features, Alpine-based | Default choice |
| `latest-fat` | Everything plus extra fonts and conversion tools | Highest-fidelity Office → PDF conversion |
| `latest-ultra-lite` | Core features only, no external binaries (no OCR, no LibreOffice) | Low-memory hosts |

## Configuration

Stirling-PDF is configured through `/configs/settings.yml`, and every key in that file can
be overridden by an environment variable using the `SECTION_KEY` upper-case form
(`security.enableLogin` → `SECURITY_ENABLELOGIN`). Environment variables win over the file.

### What this stack sets

| Variable | Value | Effect |
| --- | --- | --- |
| `SECURITY_ENABLELOGIN` | `false` | Disables authentication entirely. Upstream default is `true` — see [Authentication](#authentication). |
| `SYSTEM_ENABLEANALYTICS` | `false` | Master analytics kill switch. Upstream default is `null`, which prompts an admin to choose on first launch; pinning it to `false` disables telemetry (PostHog, Scarf) and skips the prompt. |
| `SYSTEM_DEFAULTLOCALE` | `en-US` | Forces the UI language. Empty would auto-detect from the browser. |
| `UI_APPNAMENAVBAR` | `Stirling-PDF` | Browser tab title and TOTP/2FA issuer label. Despite the name it is **not** shown in the navbar any more — the navbar renders the logo. |
| `JAVA_TOOL_OPTIONS` | `-Xmx1536m` | Caps JVM heap below `mem_limit`, leaving headroom for native OCR/LibreOffice child processes. See [Resource limits](#resource-limits). |

### Variables in the compose file that no longer do anything

These are carried over from Stirling-PDF 0.x. They are harmless — the container ignores
them — but don't expect them to have an effect on current images:

| Variable | Why it is inert |
| --- | --- |
| `DISABLE_ADDITIONAL_FEATURES` | Build-time Gradle flag, not a runtime setting. The startup script only echoes it into the log. The standard `latest` image is already built with the additional features compiled in. |
| `SYSTEM_MAXFILESIZE` | No `system.maxFileSize` key exists in the current settings schema. Cap upload size at the reverse proxy instead (e.g. Traefik/nginx body-size limits). |
| `UI_APPNAME` | No `ui.appName` key exists; only `ui.appNameNavbar` (set above). |
| `LANGS` / `TESSERACT_LANGS` | Neither appears in the current Dockerfiles or init scripts. OCR language packs ship in the image and extra ones are added by file — see [OCR languages](#ocr-languages). |

> [!TIP]
> Leaving them in place costs nothing, but if you want the compose file to reflect what the
> container actually reads, these five lines can be deleted without changing behaviour.

### Other variables worth knowing

| Variable | Default | Notes |
| --- | --- | --- |
| `PUID` / `PGID` | `1000` / `1000` | Remaps the `stirlingpdfuser` runtime user. Only matters if you swap named volumes for bind mounts. |
| `UMASK` | `022` | Permissions mask for files the app creates. |
| `STIRLING_JVM_PROFILE` | `balanced` | `balanced` (G1GC) or `performance` (generational Shenandoah, pre-touched heap). |
| `SYSTEM_ROOTURIPATH` | *(empty)* | Serve under a subpath, e.g. `/pdf`. The image's built-in healthcheck honours this. |
| `SYSTEM_CORSALLOWEDORIGINS` | *(empty)* | **Empty means allow all origins with credentials — it does not disable CORS.** Set explicit origins if the API is reachable beyond your LAN. |
| `SYSTEM_GOOGLEVISIBILITY` | `false` | `false` serves a disallow-all `/robots.txt`. |
| `ENDPOINTS_TOREMOVE` | *(empty)* | Disable individual tools, e.g. `remove-pages,img-to-pdf`. |
| `METRICS_ENABLED` | `true` | Gates the `/api/*` info endpoints. **Turning this off breaks the healthcheck** — see [Troubleshooting](#troubleshooting). |

To edit the full settings file directly instead:

```bash
docker exec -it stirling-pdf vi /configs/settings.yml
docker restart stirling-pdf
```

## Storage

All state is in named volumes, so there is nothing to chown on the host:

| Volume | Mounted at | Holds |
| --- | --- | --- |
| `stirling-config` | `/configs` | `settings.yml`, the app database, and JVM heap dumps (`/configs/heap_dumps`). **The one to back up.** |
| `stirling-data` | `/usr/share/tessdata` | Drop-in directory for extra OCR language packs. |
| `stirling-logs` | `/logs` | Application logs. |
| `stirling-custom` | `/customFiles` | Custom fonts, static assets, and (with `SYSTEM_CUSTOMHTMLFILES=true`) template overrides under `/customFiles/templates`. |
| `stirling-pipeline` | `/pipeline` | Saved pipeline / automation definitions. |

Scratch space for conversions is **not** a volume — it lives at `/tmp/stirling-pdf` in the
container's writable layer and is discarded on recreate. For heavy conversion workloads,
mounting a tmpfs there keeps churn off the disk:

```yaml
    tmpfs:
      - /tmp/stirling-pdf:size=1g
```

### Backup

```bash
docker run --rm -v stirling-config:/data -v "$PWD":/backup alpine \
  tar czf /backup/stirling-config.tar.gz -C /data .
```

Restore into a stopped stack:

```bash
docker run --rm -v stirling-config:/data -v "$PWD":/backup alpine \
  tar xzf /backup/stirling-config.tar.gz -C /data
```

## OCR languages

English (`eng`) is included. To add more, drop the `.traineddata` file into the
`stirling-data` volume and restart — `init.sh` copies anything found in
`/usr/share/tessdata` to the location Tesseract actually reads
(`/usr/share/tesseract-ocr/5/tessdata`) on every start.

```bash
curl -LO https://github.com/tesseract-ocr/tessdata/raw/main/deu.traineddata
docker cp deu.traineddata stirling-pdf:/usr/share/tessdata/
docker restart stirling-pdf
```

Verify the language is registered:

```bash
docker exec stirling-pdf tesseract --list-langs
```

## Resource limits

| Setting | Value | Reasoning |
| --- | --- | --- |
| `mem_limit` | `2g` | Hard cap. The JVM ships with `-XX:+ExitOnOutOfMemoryError`, so heap exhaustion exits the container and `restart: unless-stopped` brings it back. |
| `mem_reservation` | `512m` | Soft floor Docker tries to keep available. |
| `cpus` | `2.0` | Stops an OCR or LibreOffice job from pegging the whole box. |
| `JAVA_TOOL_OPTIONS` | `-Xmx1536m` | ~512 MB left over for metaspace, thread stacks, and the native `soffice`/`tesseract`/Ghostscript processes, which allocate **outside** the heap. |

Bump both numbers together for OCR-heavy or large-document use — e.g. `mem_limit: 3g` with
`-Xmx2g`. Raising `-Xmx` alone just moves the OOM from the JVM to the kernel.

> [!NOTE]
> `mem_limit`, `mem_reservation`, and `cpus` are Compose v2 service-level keys. They apply
> with `docker compose` and with Portainer's compose deployments, but are ignored by
> `docker stack deploy` (Swarm), which needs a `deploy.resources` block instead.

## Health

The compose file overrides the image's built-in healthcheck:

```yaml
test: ["CMD-SHELL", "curl -f http://localhost:8080/api/v1/info/status | grep -q 'UP'"]
```

The `grep -q 'UP'` is stricter than the image default (`curl -f` alone), which catches the
case where the endpoint answers 200 while a component is still coming up. The `start_period`
here is **60s** versus the image's 120s — failures during the start period don't count
against `retries`, so a slow first boot has 60s of grace plus 5 × 30s of retries before the
container is marked unhealthy.

```bash
docker ps --filter name=stirling-pdf
docker inspect --format='{{json .State.Health}}' stirling-pdf | jq
```

## Reverse proxy

To put this behind the [traefik](../traefik/) edge stack:

1. Attach `stirling-pdf` to the proxy network and drop the published `8080` port.
2. If serving under a subpath, set `SYSTEM_ROOTURIPATH` (e.g. `/pdf`) — the healthcheck URL
   in the compose file needs the same prefix.
3. Raise the proxy's request body limit; the default in most proxies is well below a large
   scanned PDF.
4. Set `SYSTEM_CORSALLOWEDORIGINS` explicitly if anything other than the UI calls the API.

## Maintenance

```bash
docker compose pull && docker compose up -d   # update
docker compose logs -f stirling-pdf           # follow logs
docker compose down                           # stop (volumes are kept)
```

## Authentication

This stack runs with `SECURITY_ENABLELOGIN=false`, so **anyone who can reach port 8080 has
full access** to the UI and the REST API, including file upload. That is a deliberate
trade-off for a LAN/Tailscale-only deployment.

> [!WARNING]
> Do not expose this to the internet as configured. Before it becomes reachable beyond a
> trusted network, either set `SECURITY_ENABLELOGIN=true` (default credentials are
> `admin` / `stirling` — change them on first login) or front it with authentication
> middleware on the reverse proxy.

## Troubleshooting

**Container reports `unhealthy` but the UI loads.** Check `METRICS_ENABLED` — it gates the
`/api/*` info endpoints the healthcheck probes. If it's `false`, the healthcheck can never
pass. Either re-enable it or point the healthcheck at a different URL.

**Container keeps restarting.** Look for `ExitOnOutOfMemoryError` in the logs; a heap dump
in `/configs/heap_dumps` confirms it. Raise `mem_limit` and `-Xmx` together.

**OCR or conversion tools greyed out in the UI.** The `ultra-lite` image strips those
binaries. Confirm which image is running and check what the startup script found:

```bash
docker inspect --format='{{.Config.Image}}' stirling-pdf
docker compose logs stirling-pdf | grep -iE "tesseract|libreoffice|ghostscript"
```

**Office conversions fail or hang.** LibreOffice needs both memory outside the JVM heap and
writable temp space. Raise `mem_limit` and check `/tmp/stirling-pdf` isn't full.

**Port 8080 already in use.** Change the left-hand side of the port mapping only
(`"8081:8080"`); the container side is fixed by the image.

**Settings changes not taking effect.** Environment variables override `settings.yml`. If a
value in the file is being ignored, look for a matching `SECTION_KEY` variable in the
compose file first.
