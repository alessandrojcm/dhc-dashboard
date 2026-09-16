# DHC Phoenix API

Phoenix JSON API for the Dublin HEMA Club dashboard. The production deploy target is Fly.io, with runtime application secrets loaded by `fnox` from 1Password.

## Local development

From the repo root:

```bash
mise run phx-setup
mise run phx-server
```

The local tasks connect to the local Supabase Postgres instance on `localhost:54322`.

### Docker development server

To run Phoenix, PostgreSQL, and Mailpit entirely in Docker with source
hot-reloading, start the opt-in `phoenix` Compose profile from the repository
root:

```bash
docker compose --profile phoenix up --build phoenix
```

Phoenix is available at `http://127.0.0.1:4000`. The service bind-mounts
`apps/phoenix`; Mix dependencies and build artifacts remain in the image so the
mount does not discard the cached dependency compilation. Stop it with
`docker compose --profile phoenix down`.

## Production deployment model

Production uses:

- `fly.toml` at the repo root for Fly app configuration.
- `apps/phoenix/Dockerfile` for the release image.
- `fnox.toml` at the repo root for runtime secret references.
- 1Password vault: `Production-phoenix-api`.

The container starts the app through:

```bash
fnox exec --profile production -- /app/bin/dhc start
```

The Fly release command runs migrations through the same fnox profile:

```bash
fnox exec --profile production -- /app/bin/dhc eval 'Dhc.Release.migrate()'
```

## What to configure where

### 1. Fly secrets

Only set the 1Password bootstrap token in Fly:

```bash
fly secrets set OP_SERVICE_ACCOUNT_TOKEN=ops_... --app dhc-dashboard
```

This token should be a 1Password service account token scoped to the `Production-phoenix-api` vault.

Do **not** put all application secrets in Fly. App secrets are resolved by `fnox` from 1Password when the container starts. If an app secret changes, update it in 1Password and restart the Fly machines to reload the environment.

### 2. Fly non-secret env vars

These are committed in `fly.toml` under `[env]`:

| Variable | Value | Purpose |
| --- | --- | --- |
| `APP_URL` | `https://dashboard.dublinhemaclub.com` | Public dashboard URL used in generated links and redirects |
| `AUTH_SESSION_DOMAIN` | `.dublinhemaclub.com` | Shared parent domain for the Phoenix session cookie |
| `DNS_CLUSTER_QUERY` | `dhc-dashboard.internal` | Fly private DNS query for clustering |
| `ECTO_IPV6` | `true` | Use Fly private IPv6 networking for Postgres |
| `FNOX_IF_MISSING` | `error` | Fail startup if any fnox secret is missing |
| `FNOX_PROFILE` | `production` | Select fnox production profile |
| `PHX_HOST` | `dhc-dashboard.fly.dev` | Phoenix endpoint host |
| `PHX_SERVER` | `true` | Enable Phoenix HTTP server in release |
| `POOL_SIZE` | `10` | Ecto connection pool size |
| `PORT` | `8080` | Internal HTTP port matching Fly service config |
| `STRIPE_API_URL` | `https://api.stripe.com` | Stripe API base URL |

If the Fly app name or primary hostname changes, update `PHX_HOST` and `DNS_CLUSTER_QUERY`.

Optional, once Web Push is enabled (see [Enabling Web Push](#5-enabling-web-push-ale-299)):

| Variable | Value | Purpose |
| --- | --- | --- |
| `WEB_PUSH_VAPID_PUBLIC_KEY` | base64url key from `mix web_push_ex.vapid` | VAPID public key browsers use as `applicationServerKey` |
| `WEB_PUSH_VAPID_SUBJECT` | `mailto:contact@dublinhemaclub.com` | VAPID contact the push services may use to reach us |

### 3. 1Password items referenced by fnox

Create one item per variable in the `Production-phoenix-api` vault. For simple references like `DATABASE_URL`, fnox reads the item's `password` field.

Required production items:

| 1Password item | Secret? | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | Yes | Production Postgres connection URL |
| `SECRET_KEY_BASE` | Yes | Phoenix signing/encryption secret |
| `DISCORD_WEBHOOK_URL` | Yes | Discord webhook target |
| `RESEND_API_KEY` | Yes | Resend send-only transactional email API key |
| `STRIPE_SECRET_KEY` | Yes | Stripe API key |
| `STRIPE_WEBHOOK_SIGNING_SECRET` | Yes | Stripe webhook signature secret |
| `SUPABASE_URL` | No/low sensitivity | Supabase project URL used for auth/service clients |
| `SUPABASE_ANON_KEY` | No/low sensitivity | Supabase anon key used for JWT/auth integration |
| `SUPABASE_SERVICE_ROLE_KEY` | Yes | Supabase admin/service-role key |
| `SENTRY_DSN` | No/low sensitivity | Sentry DSN for production error reporting |

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SENTRY_DSN` are not high-sensitivity secrets, but they are currently loaded via fnox for one consistent production config path.

Optional, once Web Push is enabled:

| 1Password item | Secret? | Purpose |
| --- | --- | --- |
| `WEB_PUSH_VAPID_PRIVATE_KEY` | Yes | VAPID private key that signs every push request (ALE-299) |

### 4. GitHub Actions secrets and variables

GitHub Actions deploys the image; the running container loads app secrets from 1Password.

Required GitHub Actions secret:

| Name | Purpose |
| --- | --- |
| `FLY_API_TOKEN` | Allows CI to run `fly deploy` |

Optional GitHub Actions variable:

| Name | Default | Purpose |
| --- | --- | --- |
| `FLY_PHOENIX_APP` | `dhc-dashboard` in workflow fallback | Overrides the Fly app name used by CI |

Note: `fly.toml` currently has `app = "dhc-dashboard"`. If the final Fly app name changes, update `fly.toml`, `PHX_HOST`, `DNS_CLUSTER_QUERY`, and the `FLY_PHOENIX_APP` workflow variable/fallback together.

### 5. Enabling Web Push (ALE-299)

Web Push is off until all three `WEB_PUSH_VAPID_*` values are present; a partial set is treated as unset, the notification centre reports push as unavailable, and no delivery jobs are enqueued. The VAPID pair identifies the application server to the push services, so generate it **once** and keep it stable — rotating it invalidates every browser subscription (the dashboard detects a key mismatch and asks members to opt in again).

Rollout order matters because `FNOX_IF_MISSING=error` fails startup on a missing fnox item:

1. Generate a pair locally: `cd apps/phoenix && mix web_push_ex.vapid`.
2. Create the `WEB_PUSH_VAPID_PRIVATE_KEY` item in the `Production-phoenix-api` vault (password field = private key).
3. Uncomment `WEB_PUSH_VAPID_PRIVATE_KEY` in `fnox.toml` and `WEB_PUSH_VAPID_PUBLIC_KEY` / `WEB_PUSH_VAPID_SUBJECT` under `[env]` in `fly.toml`, filling in the public key.
4. Deploy. `GET /api/notifications/push/config` should answer `{"enabled": true, "vapidPublicKey": "..."}`; the toggle in the notification centre then offers to enable push.

Nothing is needed on the Cloudflare/SvelteKit side: the browser fetches the public key from the API.

Locally, copy the same three variables into `.env` (see `.env.example`); `mise` loads it for `mise run phx-server`. The dev SvelteKit origin is HTTPS, which the Push API requires.

## Deploy

From a machine with `flyctl` and `FLY_API_TOKEN`:

```bash
mise run phx-fly-deploy
```

Or manually:

```bash
fly deploy --app dhc-dashboard --remote-only
```

## Verify config before deploy

```bash
mise exec -- fnox check --profile production
docker build -f apps/phoenix/Dockerfile .
```

## Useful production commands

```bash
fly logs --app dhc-dashboard
fly status --app dhc-dashboard
fly machines restart --app dhc-dashboard
```
