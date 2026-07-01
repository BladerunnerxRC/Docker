# Manyfold3D Docker Stack

This stack runs Manyfold with PostgreSQL and Redis using Docker Compose.

## Files

- `docker-compose.yml`: Application stack definition.

## Services

- `app`: Manyfold web application on port `3214`.
- `postgres-manyfoldsvr`: PostgreSQL database backend.
- `redis-manyfoldsvr`: Redis cache/queue backend.

## Prerequisites

- Docker Engine + Docker Compose plugin
- A host path for your 3D model library
- A `.env` file in this folder with required variables

## Required Environment Variables

Create a `.env` file in this directory.

```env
# Host user/group mapping
PUID=1000
PGID=1000

# Library path on host (bind-mounted read/write to /libraries)
MANYFOLD_LIB_PATH=/mnt/nas_3d

# Database settings
POSTGRES_DB=manyfold
POSTGRES_USER=manyfold
POSTGRES_PASSWORD=change_this_password

# App secret (generate a long random value)
SECRET_KEY_BASE=replace_with_long_random_secret
```

## Start

```bash
docker compose up -d
```

## Stop

```bash
docker compose down
```

## Verify

Check container status:

```bash
docker compose ps
```

Check health state:

```bash
docker inspect --format='{{.Name}} {{.State.Health.Status}}' \
  $(docker compose ps -q app postgres-manyfoldsvr redis-manyfoldsvr)
```

Open UI:

- `http://<host-ip>:3214`

## Data Persistence

- PostgreSQL data is stored in named volume `db_data`.
- Library files are mounted from `${MANYFOLD_LIB_PATH}` into `/libraries`.

## Logs

Each service uses log rotation:

- driver: `json-file`
- max-size: `10m`
- max-file: `3`

View logs:

```bash
docker compose logs -f app
```

## Backup and Restore

Database backup:

```bash
docker compose exec -T postgres-manyfoldsvr \
  pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > manyfold-db.sql
```

Database restore:

```bash
docker compose exec -T postgres-manyfoldsvr \
  psql -U "$POSTGRES_USER" "$POSTGRES_DB" < manyfold-db.sql
```

## Troubleshooting

If `app` healthcheck is `unhealthy`:

1. Check app logs:

```bash
docker compose logs --tail=200 app
```

2. Confirm DB and Redis are healthy first:

```bash
docker compose ps
```

3. Validate env values are present:

```bash
docker compose config
```

If startup fails with DB auth errors, verify `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` match the running DB volume data.

## Security Notes

- `SECRET_KEY_BASE` must be unique and private.
- Keep `.env` out of source control.
- This compose currently publishes `3214` on all interfaces; if fronted by Traefik, consider restricting host exposure.
