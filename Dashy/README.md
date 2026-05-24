# Dashy Dashboard

Self-hosted dashboard for quickly accessing your applications, infrastructure tools, and admin pages.

Official Dashy GitHub repository: <https://github.com/Lissy93/dashy/>

This folder contains:

- `docker-compose.yaml`: Runs Dashy in Docker.
- `dashy_conf.yaml`: Your exported dashboard configuration.

## Overview

Your Dashy instance is configured to:

- Run as container: `dashy`
- Use image: `lissy93/dashy:latest`
- Listen on host port: `4000`
- Persist app data in Docker volume: `dashy_user_data`
- Use a healthcheck and basic hardening (`no-new-privileges`, dropped capabilities)
- Set memory limits and reservations

## Included Dashboard Content

Your current config (`dashy_conf.yaml`) includes sections for:

- Applications
- Tools
- Network Admin
- Server Admin
- Storage
- Docker

## Prerequisites

- Docker installed
- Docker Compose plugin available (`docker compose`)

## Start Dashy

From this folder:

```bash
docker compose up -d
```

## Stop Dashy

```bash
docker compose down
```

## Access the Dashboard

Open:

- <http://localhost:4000/>

From another device, replace `localhost` with the Docker host IP.

## View Logs

```bash
docker compose logs -f dashy
```

## Health Status

```bash
docker ps --filter "name=dashy"
```

## Configuration Notes

Dashy stores live configuration in `/app/user-data/conf.yml` inside the container (persisted in `dashy_user_data`).

Your `dashy_conf.yaml` in this folder is a standalone/exported config file and is useful for:

- version control
- backup
- restoring or migrating your dashboard

### Optional: Restore your config into a running container

If you want to load this file directly into Dashy:

```bash
docker cp ./dashy_conf.yaml dashy:/app/user-data/conf.yml
docker restart dashy
```

## Backup and Restore

### Backup current live config

```bash
docker cp dashy:/app/user-data/conf.yml ./dashy_conf_backup.yaml
```

### Restore from backup

```bash
docker cp ./dashy_conf_backup.yaml dashy:/app/user-data/conf.yml
docker restart dashy
```

## Update Dashy

```bash
docker compose pull
docker compose up -d
```

## Troubleshooting

- Port already in use:
  - Change `4000:8080` in `docker-compose.yaml` to another host port.
- Dashboard not loading:
  - Check logs with `docker compose logs -f dashy`.
  - Verify container health status in `docker ps`.
- Config changes not appearing:
  - Ensure you updated `/app/user-data/conf.yml` (not just a local file).
  - Restart the container after restoring config.

## Security Notes

- This dashboard links to sensitive internal/admin endpoints.
- Prefer restricting access to trusted networks only.
- Consider placing Dashy behind your reverse proxy and authentication middleware.
