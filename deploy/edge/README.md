# Edge ingress — ROKO explorer (two domains)

`roko-explorer` (VMID 123, `10.0.42.123`, internal `s9.internal` VM on oberth, no
public IP) serves the explorer **HTTP-only** on port 80 and routes by `Host` to
the matching frontend. All TLS terminates **upstream**:

- **internal** `explorer.roko.internal` → **npm01** (Nginx Proxy Manager, `10.0.42.103`) with an internal-CA cert.
- **public** `explorer.roko.network` → **Cloudflare edge** via a `cloudflared` tunnel on oberth/DMZ.

```
                        ┌─────────── Cloudflare edge (public TLS) ───────────┐
  public  ────────────▶ │  explorer.roko.network                             │
                        └───────────────────────┬────────────────────────────┘
                                     cloudflared │  (outbound tunnel — no inbound)
                                                 ▼   on oberth / DMZ edge
  internal ──▶ npm01 (NPM, internal-CA TLS) ─────┐
               explorer.roko.internal            │  both over 10.0.42.0/24, HTTP
                                                  ▼
                       roko-explorer:80  nginx  ─┬─ Host: explorer.roko.internal → frontend-internal:3000
                                                 ├─ Host: explorer.roko.network  → frontend-public:3000
                                                 └─ /api,/socket (either Host)    → backend:4000  (shared)
```

## What the edge MUST do

Both paths forward to `http://roko-explorer.s9.internal:80` (`10.0.42.123:80`) and must:

1. **Preserve the original `Host`** (`explorer.roko.internal` / `explorer.roko.network`)
   — roko-explorer routes by it. The cloudflared example sets `httpHostHeader`; an
   NPM proxy host preserves Host by default (don't rewrite it to the origin address).
2. **Send `X-Forwarded-Proto: https`** — TLS is terminated at the edge; the app needs
   the public scheme to be https (nginx defaults it to https if absent).

## Public — Cloudflare Zero Trust tunnel

See `cloudflared-config.example.yml`. Connector runs on oberth/DMZ (internal),
dials out to Cloudflare; roko-explorer stays inbound-portless. DNS
`explorer.roko.network` → `<tunnel>.cfargotunnel.com` (proxied) is created by
`cloudflared tunnel route dns`.

## Internal — npm01 (Nginx Proxy Manager)

npm01 is the fleet's internal TLS terminator and is **already half-wired for this
host**: it has proxy hosts `roko-explorer.rokonetwork.internal` and
`blockexplorer.rokonetwork.internal` → `10.0.42.123:80` with the Roko-Network
tenant-issued G2 cert (they return 502 until this compose stack is up). Add one
more proxy host for the operator-chosen name:

**NPM proxy host — `explorer.roko.internal`:**

| Field | Value |
|---|---|
| Domain Names | `explorer.roko.internal` |
| Scheme | `http` |
| Forward Hostname / IP | `10.0.42.123` (roko-explorer) |
| Forward Port | `80` |
| Websockets Support | **on** (needed for `/socket`) |
| Preserve Host header | **on** (roko-explorer routes by Host) |
| SSL | internal-CA cert (reuse/extend the Roko-Network tenant G2 cert) |

NPM generates the equivalent nginx under the hood:

```nginx
server {
    listen 443 ssl;
    server_name explorer.roko.internal;
    ssl_certificate     /data/custom_ssl/.../fullchain.pem;   # internal CA
    ssl_certificate_key /data/custom_ssl/.../privkey.pem;
    location / {
        proxy_pass http://10.0.42.123:80;
        proxy_set_header Host $host;                 # roko-explorer routes by this
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;      # websockets (/socket)
        proxy_set_header Connection "upgrade";
    }
}
```

## DNS (PowerDNS on ns1 @ 10.0.42.53 — `scripts/dns-record.sh` in itops)

- `explorer.roko.internal` → **npm01** (`10.0.42.103`), matching the existing
  `*.rokonetwork.internal` TLS-terminated pattern:
  `dns-record.sh add explorer.roko.internal A 10.0.42.103`.
- `explorer.roko.network` → Cloudflare tunnel CNAME (created by the route-dns step).
