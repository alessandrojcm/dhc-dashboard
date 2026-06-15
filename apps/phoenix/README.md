# DHC Phoenix API

Phoenix JSON API for the Dublin HEMA Club dashboard. The production deploy target is Fly.io, with runtime application secrets loaded by `fnox` from 1Password.

## Local development

From the repo root:

```bash
mise run phx-setup
mise run phx-server
```

The local tasks connect to the local Supabase Postgres instance on `localhost:54322`.

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
| `APP_URL` | `https://dublinhemaclub.com` | Public frontend URL used in generated links/emails |
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

### 3. 1Password items referenced by fnox

Create one item per variable in the `Production-phoenix-api` vault. For simple references like `DATABASE_URL`, fnox reads the item's `password` field.

Required production items:

| 1Password item | Secret? | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | Yes | Production Postgres connection URL |
| `SECRET_KEY_BASE` | Yes | Phoenix signing/encryption secret |
| `DISCORD_WEBHOOK_URL` | Yes | Discord webhook target |
| `LOOPS_API_KEY` | Yes | Loops transactional email API key |
| `STRIPE_SECRET_KEY` | Yes | Stripe API key |
| `STRIPE_WEBHOOK_SIGNING_SECRET` | Yes | Stripe webhook signature secret |
| `SUPABASE_URL` | No/low sensitivity | Supabase project URL used for auth/service clients |
| `SUPABASE_ANON_KEY` | No/low sensitivity | Supabase anon key used for JWT/auth integration |
| `SUPABASE_SERVICE_ROLE_KEY` | Yes | Supabase admin/service-role key |
| `SENTRY_DSN` | No/low sensitivity | Sentry DSN for production error reporting |

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SENTRY_DSN` are not high-sensitivity secrets, but they are currently loaded via fnox for one consistent production config path.

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
