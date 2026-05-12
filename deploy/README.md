# roko-explorer deployment scaffold

This directory holds the docker-compose stack that runs at `roko-explorer.ntfork.com`. It is the source of truth for the production deploy; mirror any changes here when modifying `docker-compose/proxy-roko/default.conf.template` (the dev variant).

## Stack

- `db` — postgres:17, persistent volume `postgres-data`
- `redis-db` — redis:alpine, persistent volume `redis-data`
- `backend` — `roko-blockscout-backend:local` (built on host via `docker compose build`)
- `frontend` — `roko-blockscout-frontend:local` (built on host)
- `proxy` — nginx with letsencrypt cert mount + faucet proxy to roko-admin
- `roko-indexer` — `ghcr.io/roko-network/roko-indexer:testnet-latest-amd64` (substrate-native indexer; writes the `roko.*` schema for `SubstrateController`)

## First-time setup

```bash
# 1. Run setup.sh on a fresh Ubuntu host to install Docker + certbot
./setup.sh

# 2. Provision secrets (NEVER commit the resulting .env files)
cp .env.example .env
cp envs/backend.env.example envs/backend.env
cp envs/frontend.env.example envs/frontend.env

# 3. Generate strong passwords for BOTH postgres roles and write into the env files:
POSTGRES_PASS=$(openssl rand -hex 24)
INDEXER_PASS=$(openssl rand -hex 24)
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASS|" .env
sed -i "s|^ROKO_INDEXER_DB_PASSWORD=.*|ROKO_INDEXER_DB_PASSWORD=$INDEXER_PASS|" .env
sed -i "s|replace-with-strong-secret|$POSTGRES_PASS|g" envs/backend.env

# 4. Obtain certs via certbot (one-time, requires DNS already pointing here)
sudo certbot certonly --webroot -w ./certbot-webroot -d roko-explorer.ntfork.com

# 5. Bring postgres + redis up first
docker compose up -d db redis-db

# 6. One-shot: create the `roko` schema + `roko_indexer` role, grant USAGE/SELECT
#    to blockscout. Replace CHANGEME with the value of $INDEXER_PASS.
sed "s|CHANGEME|$INDEXER_PASS|" sql/init-roko-schema.sql | docker compose exec -T db psql -U blockscout blockscout

# 7. Build local images
docker compose build

# 8. Bring up the full stack
docker compose up -d
```

## Updating

```bash
# Pull latest source on host, then:
docker compose build backend frontend
docker compose up -d
```

## Files

| File | Purpose | Committed? |
|------|---------|------------|
| `docker-compose.yml` | Stack definition | Yes |
| `setup.sh` | One-shot host bootstrap | Yes |
| `nginx/default.conf` | Reverse proxy (HTTPS, faucet proxy, backend+frontend routing) | Yes |
| `.env.example`, `envs/*.env.example` | Templates with placeholders | Yes |
| `.env`, `envs/backend.env`, `envs/frontend.env` | Actual secrets — local-only | **No** (gitignored) |
| `logs/`, `dets/`, `certbot-webroot/` | Runtime artifacts | **No** (gitignored) |

## Secret rotation

Rotate `POSTGRES_PASSWORD` and `ROKO_INDEXER_DB_PASSWORD` on every fresh deploy.

- `POSTGRES_PASSWORD` must match in `.env` and `envs/backend.env`'s `DATABASE_URL`. Mismatch → backend cannot connect to the DB.
- `ROKO_INDEXER_DB_PASSWORD` must match in `.env` AND the `roko_indexer` Postgres role (set during init via `init-roko-schema.sql`, or rotated via `ALTER ROLE roko_indexer WITH PASSWORD '...'`). Mismatch → sidecar can't connect; `/api/v2/substrate/*` returns empty results because no new rows are landing.

## Sidecar updates

```bash
# Pull the new image
docker compose pull roko-indexer
docker compose up -d roko-indexer

# Or pin to a specific version via .env:
#   ROKO_INDEXER_IMAGE=ghcr.io/roko-network/roko-indexer:testnet-v0.1.0-amd64

# Tail the indexer
docker compose logs -f roko-indexer

# Health
curl http://localhost:9100/healthz
curl http://localhost:9100/metrics
```

## Substrate API surface

The SubstrateController (introduced in TICKET-18) exposes rows from `roko.*`:

```
GET /api/v2/substrate/validators
GET /api/v2/substrate/validators/:stash
GET /api/v2/substrate/validators/:stash/violations
GET /api/v2/substrate/validators/:stash/pwroko-history
GET /api/v2/substrate/eras
GET /api/v2/substrate/slashing
GET /api/v2/substrate/pwroko/recent[?kind=Transfer]
```

If those endpoints return empty arrays, check the sidecar is healthy:
```bash
docker compose logs --tail=200 roko-indexer
```
