# ROKO Blockscout deployment on apps01

This directory holds the docker-compose stack for the ROKO Blockscout explorer.

> **Ingress model (apps01, two domains).** The stack runs on **apps01**
> (`10.0.42.108`) and serves **HTTP-only** on port 80, routing by
> `Host` to a per-domain frontend:
> - `explorer.roko.internal` → `frontend-internal` — TLS terminated on **npm01** (NPM, internal CA).
> - `explorer.roko.network` → `frontend-public` — TLS at the **Cloudflare edge** via a `cloudflared` tunnel on oberth/DMZ.
>
> The backend/DB/indexer are shared across both domains. There are **two frontend
> containers** because the Blockscout frontend bakes a single `NEXT_PUBLIC_*_HOST`.
> Edge (proxy + tunnel) config and requirements: see [`edge/README.md`](edge/README.md).
> The legacy `roko-explorer` VM and single-domain certbot/443 path are
> **superseded** — certbot is not used on apps01 (TLS terminates upstream).

## Active chain profile

The active deployment is the mainnet-configured test chain on boe:

- chain ID: `52370` (`0xcc92`);
- backend RPC: `boe.s9.internal:9945`;
- Docker host mapping: `ROKO_RPC_HOST_IP=10.0.42.97` (update from CMDB when
  boe's address changes);
- the native sidecar uses `ws://127.0.0.1:9945` through the colocated
  `roko-rpc-tunnel` container because subxt permits plaintext WebSockets only
  for loopback URLs;
- boe keeps its validator RPC on loopback; a hardened `socat` proxy accepts
  only apps01 (`10.0.42.108`) on the fleet network;
- public and internal frontends use their own `/api/eth-rpc` endpoints;
- chain cutovers use fresh named Postgres and Redis volumes. Prior volumes are
  retained unchanged for rollback and are never pruned during cutover.

## Repos & layout

The explorer is a Blockscout fork split across three repos. Production images
are built by CI and pulled from the internal Gitea registry:

| Component | Repo | Image |
|-----------|------|-------|
| Backend (Elixir/Phoenix) | `roko/roko-blockscout` (`master`) | `git.integrolabs.net/roko/roko-blockscout-backend:testnet` |
| Frontend (Next.js) | `roko/roko-blockscout-frontend` (`main`) | `git.integrolabs.net/roko/roko-blockscout-frontend:testnet` |
| Indexer sidecar (Rust) | `roko/roko_network` (`main`, `sidecar/`) | `git.integrolabs.net/roko/roko-indexer:testnet` |

This `deploy/` directory lives **inside the backend repo**, but in production it is copied to its own run directory (e.g. `/opt/roko-blockscout/`) separate from the source checkouts. The build commands below run from each repo's own root, independent of where the compose stack runs. A typical host layout:

    ~/roko-blockscout/            # backend repo (contains this deploy/ dir)
    ~/roko-blockscout-frontend/   # frontend repo
    /opt/roko-blockscout/         # apps01 runtime copy + gitignored secrets

## Stack

- `db` — postgres:17, persistent volume `postgres-data`
- `redis-db` — redis:alpine, persistent volume `redis-data`
- `backend` — `roko-blockscout-backend:local` (built from the `roko-blockscout` repo — see "Building the images")
- `frontend` — `roko-blockscout-frontend:local` (built from the `roko-blockscout-frontend` repo)
- `proxy` — nginx with letsencrypt cert mount + faucet proxy to roko-admin
- `roko-indexer` — `git.integrolabs.net/roko/roko-indexer:testnet` (substrate-native indexer; writes the `roko.*` schema for `SubstrateController`)
- `roko-rpc-tunnel` — loopback-only WebSocket relay from the indexer network namespace to boe's apps01-restricted proxy

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
cp envs/frontend.internal.env.example envs/frontend.internal.env
cp envs/frontend.public.env.example  envs/frontend.public.env

# 3. Generate strong passwords for BOTH postgres roles and write into the env files:
POSTGRES_PASS=$(openssl rand -hex 24)
INDEXER_PASS=$(openssl rand -hex 24)
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASS|" .env
sed -i "s|^ROKO_INDEXER_DB_PASSWORD=.*|ROKO_INDEXER_DB_PASSWORD=$INDEXER_PASS|" .env
sed -i "s|replace-with-strong-secret|$POSTGRES_PASS|g" envs/backend.env

# 4. Confirm TLS termination and Host preservation at npm01/Cloudflare.

# 5. Bring postgres + redis up first using the chain-specific named volumes.
docker compose up -d db redis-db

# If the RPC source is pruned rather than archival, set INDEXER_START_BLOCK in
# .env to the finalized head recorded at cutover. Do not use 0 for a pruned node.

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

### Updating token artwork without rebuilding the frontend

Token artwork and `token-list.json` are served from the persistent
`deploy/token-icons/` directory mounted read-only into the nginx proxy. They
are intentionally independent of the frontend image.

Prepare a directory containing the complete token list and every image it
references, validate it, then publish it:

```bash
deploy/publish-token-assets.sh \
  --source /path/to/token-icons

deploy/publish-token-assets.sh \
  --source /path/to/token-icons \
  --execute
```

The publisher accepts JPEG, PNG, SVG, and WebP artwork; requires all entries to
target ROKO chain ID `52370`; retains the previous files under
`token-icons/history/`; publishes the manifest last; requests an immediate
Blockscout metadata refresh; and verifies public checksums. It does not rebuild
or restart the frontend or backend.

Use a new, content-versioned filename when replacing an existing image, then
update its `logoURI` in the manifest. The explorer's Cloudflare policy may cache
an already-used public asset URL for up to four hours; a new filename becomes
visible immediately. The backend reads the manifest directly from the local
proxy at `http://proxy/assets/token-icons/token-list.json`, bypassing that edge
cache.

### Updating the nginx config (important — recreate, don't just reload)

`nginx/default.conf` is bind-mounted as a **single file**. Docker file-mounts pin
the file's *inode*, so replacing the file (`scp`, `mv`, an editor that writes a
temp then renames, or `git pull` writing a fresh file) leaves the container bound
to the **old inode** — `nginx -s reload` then silently re-reads the *stale* config
and reports success while none of your changes are live. After ANY change to
`nginx/default.conf`, recreate the proxy so it re-binds the current file:

```bash
docker compose up -d --force-recreate proxy
# verify the container sees the current file:
[ "$(stat -c %i nginx/default.conf)" = \
  "$(docker compose exec -T proxy stat -c %i /etc/nginx/conf.d/default.conf)" ] \
  && echo "inode matches — config live" || echo "STALE — recreate proxy"
```

In-place edits that keep the inode (`cp new nginx/default.conf`, `sed -i`) are
picked up by a plain `nginx -s reload`. The cleaner permanent fix is to bind-mount
the `nginx/` **directory** instead of the single file (then reload suffices).

## Files

| File | Purpose | Committed? |
|------|---------|------------|
| `docker-compose.yml` | Stack definition | Yes |
| `setup.sh` | One-shot host bootstrap | Yes |
| `nginx/default.conf` | Reverse proxy (HTTPS, faucet proxy, backend+frontend routing) | Yes |
| `.env.example`, `envs/*.env.example` | Templates with placeholders | Yes |
| `.env`, `envs/backend.env`, `envs/frontend.env` | Actual secrets — local-only | **No** (gitignored) |
| `logs/`, `dets/`, `certbot-webroot/` | Runtime artifacts | **No** (gitignored) |

## Chain cutover and rollback

Never point a database containing another genesis at a new chain. Set
`ROKO_POSTGRES_VOLUME` and `ROKO_REDIS_VOLUME` to new chain-specific names,
initialize the new database, and retain the previous named volumes. Rollback is
the inverse operation: restore the prior non-secret RPC/network settings and
volume names, then recreate the stack. Do not run `docker compose down -v` or
`docker volume prune` during a cutover or observation window.

## Secret rotation

Generate new `POSTGRES_PASSWORD` and `ROKO_INDEXER_DB_PASSWORD` for a genuinely
fresh deployment. A chain-only cutover does not authorize deleting or rotating
existing host credentials; preserve them until a separately verified retirement.

- `POSTGRES_PASSWORD` must match in `.env` and `envs/backend.env`'s `DATABASE_URL`. Mismatch → backend cannot connect to the DB.
- `ROKO_INDEXER_DB_PASSWORD` must match in `.env` AND the `roko_indexer` Postgres role (set during init via `init-roko-schema.sql`, or rotated via `ALTER ROLE roko_indexer WITH PASSWORD '...'`). Mismatch → sidecar can't connect; `/api/v2/substrate/*` returns empty results because no new rows are landing.

## Sidecar updates

```bash
# Pull the new image
docker compose pull roko-indexer

# The RPC tunnel shares roko-indexer's network namespace. Stop both, recreate
# the indexer first, then recreate the tunnel against the new container ID.
docker compose stop roko-rpc-tunnel roko-indexer
docker compose up -d --no-deps --force-recreate roko-indexer
docker compose up -d --no-deps --force-recreate roko-rpc-tunnel

# Or pin to a specific version via .env:
#   ROKO_INDEXER_IMAGE=git.integrolabs.net/roko/roko-indexer:sha-<commit>

# Verify the tunnel shares the current indexer namespace.
indexer_id="$(docker inspect roko-indexer --format '{{.Id}}')"
tunnel_network="$(docker inspect roko-rpc-tunnel --format '{{.HostConfig.NetworkMode}}')"
test "$tunnel_network" = "container:$indexer_id"

# An HTTP response (including 4xx) proves the loopback RPC socket is reachable.
docker exec roko-indexer wget -S -O /dev/null http://127.0.0.1:9945

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
