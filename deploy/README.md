# roko-explorer deployment scaffold

This directory holds the docker-compose stack that runs at `roko-explorer.ntfork.com`. It is the source of truth for the production deploy; mirror any changes here when modifying `docker-compose/proxy-roko/default.conf.template` (the dev variant).

## Repos & layout

The explorer is a Blockscout fork split across three repos (all under the `Roko-Network` GitHub org). The two `:local` images are built from source on the host; the sidecar is pulled from GHCR:

| Component | Repo | Image |
|-----------|------|-------|
| Backend (Elixir/Phoenix) | `Roko-Network/roko-blockscout` (`master`) | `roko-blockscout-backend:local` (build from source) |
| Frontend (Next.js) | `Roko-Network/roko-blockscout-frontend` (`main`) | `roko-blockscout-frontend:local` (build from source) |
| Indexer sidecar (Rust) | `roko_network/sidecar/` | `ghcr.io/roko-network/roko-indexer:testnet-latest-amd64` (pulled) |

This `deploy/` directory lives **inside the backend repo**, but in production it is copied to its own run directory (e.g. `/opt/roko-explorer/`) separate from the source checkouts. The build commands below run from each repo's own root, independent of where the compose stack runs. A typical host layout:

    ~/roko-blockscout/            # backend repo (contains this deploy/ dir)
    ~/roko-blockscout-frontend/   # frontend repo
    /opt/roko-explorer/           # copy of deploy/ + the (gitignored) .env secrets; run `docker compose` here

## Stack

- `db` — postgres:17, persistent volume `postgres-data`
- `redis-db` — redis:alpine, persistent volume `redis-data`
- `backend` — `roko-blockscout-backend:local` (built from the `roko-blockscout` repo — see "Building the images")
- `frontend` — `roko-blockscout-frontend:local` (built from the `roko-blockscout-frontend` repo)
- `proxy` — nginx with letsencrypt cert mount + faucet proxy to roko-admin
- `roko-indexer` — `ghcr.io/roko-network/roko-indexer:testnet-latest-amd64` (substrate-native indexer; writes the `roko.*` schema for `SubstrateController`)

## Building the images

The two `:local` images are built with plain `docker build` from each repo's root. The compose file references them by tag and does **not** build them itself — `docker compose build` is a no-op here, so build them explicitly first:

```bash
# Backend — from the roko-blockscout repo root.
# Leave CHAIN_TYPE at its default: Roko's temporal/substrate controllers are
# compiled unconditionally, and changing CHAIN_TYPE would diverge the DB schema
# from the running database. Do not pass --build-arg CHAIN_TYPE unless you know why.
cd ~/roko-blockscout
docker build -f docker/Dockerfile -t roko-blockscout-backend:local .

# Frontend — from the roko-blockscout-frontend repo root.
# No build args needed: NEXT_PUBLIC_* are injected at container start by
# entrypoint.sh from envs/frontend.env, not baked in at build time.
cd ~/roko-blockscout-frontend
docker build -t roko-blockscout-frontend:local .
```

**Frontend must stay on a glibc base.** Its Dockerfile uses `node:22.14.0-bookworm-slim` (Debian), not Alpine: a transitive native addon (`@ipshipyard/node-datachannel`, via libp2p) ships a glibc-only binary that throws `ERR_DLOPEN_FAILED` on musl and 500s every `/address/*` page. This is baked into the Dockerfile — don't switch it back to Alpine.

**Build resources.** The frontend build is memory-hungry (`NODE_OPTIONS=--max-old-space-size=8192`); on a small instance (e.g. t3.small, ~3.7 GB) add temporary swap or it OOM-kills, and budget ~90 min on 2 vCPUs. The backend (Elixir release) is also heavy. Example swap:

```bash
sudo fallocate -l 6G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
# (not added to /etc/fstab → gone on reboot; `sudo swapoff /swapfile && sudo rm /swapfile` to remove)
```

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

# 7. Build the two :local images from source (see "Building the images").
#    `docker compose build` does NOT build them — run docker build per repo:
( cd ~/roko-blockscout            && docker build -f docker/Dockerfile -t roko-blockscout-backend:local . )
( cd ~/roko-blockscout-frontend   && docker build -t roko-blockscout-frontend:local . )

# 8. Bring up the full stack (pulls postgres/redis/nginx/roko-indexer too)
docker compose up -d
```

## Updating

```bash
# 1. Pull latest source in each repo on the host:
( cd ~/roko-blockscout && git pull )
( cd ~/roko-blockscout-frontend && git pull )

# 2. Rebuild the images that changed (see "Building the images"):
( cd ~/roko-blockscout            && docker build -f docker/Dockerfile -t roko-blockscout-backend:local . )
( cd ~/roko-blockscout-frontend   && docker build -t roko-blockscout-frontend:local . )

# 3. Recreate the containers from the new images:
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
