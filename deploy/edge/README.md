# Edge ingress — app01 explorer (two domains)

app01 (internal `s9.internal` VM, no public IP) serves the explorer **HTTP-only**
on port 80 and routes by `Host` to the matching frontend. All TLS terminates
**upstream on the oberth edge**, which fronts app01 over the internal network:

```
                        ┌─────────── Cloudflare edge (public TLS) ───────────┐
  public  ────────────▶ │  explorer.roko.network                             │
                        └───────────────────────┬────────────────────────────┘
                                     cloudflared │  (outbound tunnel — no inbound)
                                                 ▼   on oberth / DMZ edge
  internal ──▶ oberth reverse proxy (internal CA TLS) ─┐
               explorer.roko.internal                  │  both over 10.0.42.0/24, HTTP
                                                        ▼
                                    app01:80  nginx  ─┬─ Host: explorer.roko.internal → frontend-internal:3000
                                                      ├─ Host: explorer.roko.network  → frontend-public:3000
                                                      └─ /api,/socket (either Host)    → backend:4000  (shared)
```

## What the edge MUST do

Both paths forward to `http://app01.s9.internal:80` and must:

1. **Preserve the original `Host`** (`explorer.roko.internal` / `explorer.roko.network`)
   — app01 routes by it. The cloudflared example sets `httpHostHeader`; a reverse
   proxy must pass `Host` through (don't rewrite it to the origin address).
2. **Send `X-Forwarded-Proto: https`** — TLS is terminated at the edge; app01 and
   the app need to know the public scheme is https (nginx defaults it to https if absent).

## Public — Cloudflare Zero Trust tunnel

See `cloudflared-config.example.yml`. Connector runs on oberth/DMZ (internal),
dials out to Cloudflare; app01 stays inbound-portless. DNS `explorer.roko.network`
→ `<tunnel>.cfargotunnel.com` (proxied) is created by `cloudflared tunnel route dns`.

## Internal — oberth reverse proxy (multi-cert)

Terminate `explorer.roko.internal` with an internal-CA cert and forward to app01.
Example (Caddy — automatic multi-domain TLS; adapt to whatever oberth runs):

```caddy
explorer.roko.internal {
    tls /etc/ssl/roko-internal/explorer.roko.internal.crt /etc/ssl/roko-internal/explorer.roko.internal.key
    reverse_proxy http://app01.s9.internal:80 {
        header_up Host {host}                  # preserve Host (Caddy default, explicit here)
        header_up X-Forwarded-Proto https
    }
}
```

nginx equivalent:

```nginx
server {
    listen 443 ssl;
    server_name explorer.roko.internal;
    ssl_certificate     /etc/ssl/roko-internal/explorer.roko.internal.crt;   # internal CA
    ssl_certificate_key /etc/ssl/roko-internal/explorer.roko.internal.key;
    location / {
        proxy_pass http://app01.s9.internal:80;
        proxy_set_header Host $host;                 # app01 routes by this
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;      # websockets (/socket)
        proxy_set_header Connection "upgrade";
    }
}
```

## DNS

- `explorer.roko.internal` → app01's internal IP (via `ns1` @ 10.0.42.53), **or**
  point it at the oberth proxy if the proxy is a separate host from app01.
- `explorer.roko.network` → Cloudflare tunnel CNAME (created by the route-dns step).
