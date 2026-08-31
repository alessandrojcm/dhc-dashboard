# Handoff — DHC-dashboard Local-first PWA: Phase 1 (Phoenix optimistic concurrency + idempotency)

## Context

DHC-dashboard is a monorepo: SvelteKit 2 / Svelte 5 frontend in `apps/web`, Phoenix + Ecto + Oban backend in `apps/phoenix`, generated typed API client in `packages/api-client` (Hey API from `apps/phoenix/priv/api/openapi.yaml`). We are building offline/local-first PWA support using the architecture agreed in conversation (summarised below; no separate spec file exists yet):

**Agreed architecture:** local store for immediate state + durable IndexedDB outbox for writes + existing REST API for reconciliation + server `lock_version` for conflict detection. No sync engine (no ElectricSQL/Replicache/PowerSync/CRDTs). Store choice: TanStack DB + QueryCollection, but with the persistence/outbox layer written store-agnostic behind a repository interface (fallback: TinyBase + IndexedDB persister).

This phase is **step 0**: server-side support that every conflict policy depends on. Must land before any frontend work.

## Scope of this phase

1. Add `lock_version :integer, default: 1` to mutable Ecto schemas, bumped on every update (Ecto optimistic lock, `Ecto.Changeset.optimistic_lock/3`), and include it in the JSON representations.
2. Conditional updates: mutation endpoints accept the client's `lock_version`; mismatch → `409 Conflict` with the current server representation in the body. Same for deletes (409 if the record changed since read).
3. Idempotency for creates: an `idempotency_keys` table (key, request_hash, stored response, inserted_at) + plug that short-circuits a replayed `Idempotency-Key` header to the stored response. Solves duplicate offline creates.
4. Regenerate `@dhc/api-client` so new fields / 409 responses flow into the typed client (run the workspace generation command — see `packages/api-client/openapi-ts.config.ts`).

## What has been done so far

Nothing implemented. Investigation only:
- Auth is a Phoenix session cookie `_dhc_session` (`apps/web/src/lib/server/auth.ts`, `trusted-cookie-forwarding.ts`); browser sends it with `credentials: 'include'`. **No token machinery needed for offline replay** — a 401 simply redirects to `/auth` and the outbox waits.
- Single Phoenix API, single OpenAPI spec (`apps/phoenix/priv/api/openapi.yaml`) — ignore the old deep-research-report's claim of two Swagger services on :5000/:5001; that is stale.
- JSON encoders live in `apps/phoenix/lib/dhc_web/controllers/*_json.ex`.
- Migration status fields already exist in some schemas (`updated_at` etc.) — check which mutable schemas need the column before writing one migration.

## Constraints / conventions

- `mix precommit` in `apps/phoenix` runs `hex.audit` first; running Credo or Reach after can unload the archived Hex task from the current process — prefer running precommit directly.
- Phoenix tests: conventional ExSpec/ExUnit under `apps/phoenix/test`.
- Follow `docs/agents/` (structure, critical patterns, commands) and `CONTEXT.md` / `docs/adr/` for domain conventions. Consider writing an ADR for the optimistic-locking + idempotency contract.
- Stripe-adjacent / payment / refund flows are out of scope for conditional-write changes in this phase unless trivial.

## Suggested skills

- `implement` — for executing this phase
- `tdd` — Ecto changeset + plug behaviour is well suited to test-first
- `domain-modeling` — if recording the versioning/idempotency contract as an ADR
- `grill-me` — if the 409 response shape needs debate

## Open questions

- Exact 409 body shape (full current entity vs error envelope) — must be decided and reflected in the OpenAPI spec so the client generator types it.
- Whether `Idempotency-Key` applies to all creates or only the ones the offline client will queue.