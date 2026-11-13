# DHC Phoenix API

Phoenix JSON API for the Dublin HEMA Club dashboard. The production deploy target is Fly.io, with runtime application secrets loaded by `fnox` from Doppler.

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
- Doppler project: `dhc-dashboard`, config: `prd`.

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

Only set the fnox-specific Doppler service token in Fly:

```bash
fly secrets set FNOX_DOPPLER_TOKEN=dp.st.prd_... --app dhc-dashboard
```

This token must be a Doppler service token scoped to the `dhc-dashboard` project's `prd` config.

Do **not** put application secrets in Fly. `fnox` resolves them from Doppler when the container starts. If an app secret changes, update Doppler and restart the Fly machines to reload the environment.

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

Web Push and Intake Reply values are fnox/Doppler mappings, not Fly `[env]` entries. Phoenix treats a partial Web Push configuration and an unset Intake Reply domain as inactive, but their mappings have no fnox `default`; with `FNOX_IF_MISSING=error`, they still need values in Doppler. "Optional" for those features describes runtime behavior, not production-secret provisioning.

### 3. Doppler secrets referenced by fnox

Create every variable referenced by `fnox.toml` in the `dhc-dashboard` project's `prd` config. At runtime fnox uses the image's Doppler CLI and Fly's `FNOX_DOPPLER_TOKEN`. The config is the authoritative variable list.

`FNOX_IF_MISSING=error` means every mapping without a `default` must exist, including values for features not yet enabled. The five `TRAINING_CALENDAR_*` mappings have inactive defaults and may be absent. In particular, the Web Push, Intake Reply, and Resend webhook mappings are not optional while they remain in `fnox.toml`.

### 4. GitHub Actions secrets and variables

GitHub Actions deploys the image; the running container loads app secrets from Doppler.

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
2. Create all three `WEB_PUSH_VAPID_*` values in Doppler's `dhc-dashboard` / `prd` config.
3. Deploy. `GET /api/notifications/push/config` should answer `{"enabled": true, "vapidPublicKey": "..."}`; the toggle in the notification centre then offers to enable push.

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
