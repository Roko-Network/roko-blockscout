# roko-explorer deployment scaffold

This directory holds the docker-compose stack that runs at `roko-explorer.ntfork.com`. It is the source of truth for the production deploy; mirror any changes here when modifying `docker-compose/proxy-roko/default.conf.template` (the dev variant).

## Stack

- `db` — postgres:17, persistent volume `postgres-data`
- `redis-db` — redis:alpine, persistent volume `redis-data`
- `backend` — `roko-blockscout-backend:local` (built on host via `docker compose build`)
- `frontend` — `roko-blockscout-frontend:local` (built on host)
- `proxy` — nginx with letsencrypt cert mount + faucet proxy to roko-admin

## First-time setup

```bash
# 1. Run setup.sh on a fresh Ubuntu host to install Docker + certbot
./setup.sh

# 2. Provision secrets (NEVER commit the resulting .env files)
cp .env.example .env
cp envs/backend.env.example envs/backend.env
cp envs/frontend.env.example envs/frontend.env

# 3. Generate a strong postgres password and write it into BOTH:
PASS=$(openssl rand -hex 24)
sed -i "s|replace-with-strong-secret|$PASS|g" .env envs/backend.env

# 4. Obtain certs via certbot (one-time, requires DNS already pointing here)
sudo certbot certonly --webroot -w ./certbot-webroot -d roko-explorer.ntfork.com

# 5. Build images locally (no registry push)
docker compose build

# 6. Bring stack up
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

Rotate `POSTGRES_PASSWORD` on every fresh deploy. It must match in `.env` (used by docker-compose) and `envs/backend.env`'s `DATABASE_URL`. Mismatch → backend cannot connect to the DB.
